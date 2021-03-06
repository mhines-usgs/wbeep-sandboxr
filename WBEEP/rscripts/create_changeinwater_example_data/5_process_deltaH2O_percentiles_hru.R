# Take example data values (1 week) and calculate their percentiles
#   using the 5 year quantiles.

library(dplyr)
library(tidyr)
library(data.table)

# Load necessary data files
quantile_df <- readRDS("WBEEP/cache/nhru_deltaH2O_percentiles_hru_yrs.rds")
value_dt <- readRDS("WBEEP/cache/deltaH2O_days.rds")

# Remove duplicate breaks/quantiles
#   Needed for handling multiple quantiles with the same value for breaks
#   E.g. HRU 878 for runoff
quantile_nodups <- quantile_df %>% 
  group_by(HRU) %>%
  # Keep row if it is not equal to the following one
  # `default` returns NA to use to keep the last row
  mutate(next_va = lead(stat_value, default=NA)) %>% 
  filter(is.na(next_va) | next_va != stat_value) %>% 
  ungroup()

# Format quantiles to be used in `cut`
#   Don't know how to do this using data.table, so used dplyr
# Added -Inf to account for values that are the minimum so that 
#   during "cut" the "stat_to_use" would become 0
quantile_summary_df <- quantile_nodups %>% 
  group_by(HRU) %>% 
  summarize(stat_type_list = list(c(-Inf,stat_type)), 
            stat_value_list = list(c(-Inf,stat_value))) %>% 
  ungroup()
quantile_summary_dt <- as.data.table(quantile_summary_df) # needs to be a dt to merge

# Add values for linear interp as column for the each stat_type
# Get rows for each stat_type that have the right x0,x1,y0,y1 to use for linear interpolation
# Do this with the fixed quantiles (no duplicates, Q00s as 0)

quantile_dt_interp_info <- data.table(quantile_nodups)[, 
                                                       c("stat_type0", "stat_type1", 
                                                         "stat_value0", "stat_value1") := 
                                                         list(shift(stat_type, 1, "lag"), 
                                                              stat_type, 
                                                              shift(stat_value, 1, "lag"), 
                                                              stat_value),
                                                       by=list(HRU)]
# need chr in order to merge with stat_to_use col below
quantile_dt_interp_info[, stat_type := as.character(stat_type)]


# Figure out which stat category to use for linear interpolation from quantile_summary_dt
#   Since open on left, and closed on right, resulting values are the top of the category, so use 
#   preceding stat_type to interpolate
find_quantile_group <- function(value, breaks, labels) {
  cut(value, unlist(unique(breaks)), unlist(unique(labels))[-1])
}

# Now merge values with quantiles in order to figure out %iles
value_dt_stat <- merge(value_dt, quantile_summary_dt, all.x = TRUE, by="HRU")

# Determine which is the highest percentile that would be appropriate to use for interpolation
value_dt_stat <- value_dt_stat %>% 
  group_by(HRU) %>%
  mutate(stat_to_use = find_quantile_group(deltaH2O, stat_value_list, stat_type_list)) %>%
  ungroup() %>% 
  as.data.table()

value_dt_stat[,c("stat_type_list", "stat_value_list") := NULL] # Clean up and delete unneeded columns

# Now merge interp info with values and actually do linear interpolation to figure out the
# percentile that belongs to the value
per_dt <- merge(value_dt_stat, quantile_dt_interp_info, by.x = c("HRU", "stat_to_use"), 
                by.y = c("HRU", "stat_type"), all.x = TRUE)
per_dt[, deltaH2O_per := 
         # is.na(stat_type0) means that the stat_type being used is the lowest one
         ifelse(is.na(stat_type0), yes = as.numeric(stat_to_use), 
                no = (((stat_type1 - stat_type0) / (stat_value1 - stat_value0)) * (deltaH2O - stat_value0)) + stat_type0)]

# Both of these should be zero
stopifnot(length(which(is.na(per_dt$deltaH2O_per))) == 0)
stopifnot(length(which(per_dt$deltaH2O_per > 1)) == 0)

# Clean up to just be left with HRU, Date, Runoff_va, and Runoff_per
per_dt[, c("stat_to_use", "stat_name", "stat_value", "stat_type0", "stat_type1", "stat_value0", "stat_value1") := NULL]

saveRDS(per_dt, "WBEEP/cache/deltaH2O_percentiles_hru_days.rds")

