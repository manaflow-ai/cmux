#ifndef CMUX_TERMINATION_WATCHDOG_ATOMIC_H
#define CMUX_TERMINATION_WATCHDOG_ATOMIC_H

#include <stdbool.h>
#include <stdatomic.h>

typedef struct {
    atomic_bool isArmed;
} CMUXTerminationWatchdogLatch;

CMUXTerminationWatchdogLatch CMUXTerminationWatchdogLatchMake(void);
bool CMUXTerminationWatchdogLatchClaim(CMUXTerminationWatchdogLatch *latch);

#endif
