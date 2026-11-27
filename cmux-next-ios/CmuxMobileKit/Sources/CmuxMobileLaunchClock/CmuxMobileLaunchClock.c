#include "CmuxMobileLaunchClock.h"

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <unistd.h>

static CmuxLaunchClock clock_at_init;

static double abs_to_ms(uint64_t t) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e6;
}

// Runs once, before main: dyld has loaded and bound every image and run their initializers.
__attribute__((constructor)) static void cmux_launch_clock_read(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return;
    uint64_t now = mach_absolute_time();
    if (ri.ri_proc_start_abstime == 0 || now < ri.ri_proc_start_abstime) return;
    clock_at_init.wall_ms = abs_to_ms(now - ri.ri_proc_start_abstime);
    // ri_user_time and ri_system_time are mach absolute time units.
    clock_at_init.cpu_ms = abs_to_ms(ri.ri_user_time + ri.ri_system_time);
    clock_at_init.pageins = ri.ri_pageins;
    clock_at_init.valid = 1;
}

CmuxLaunchClock cmux_launch_clock(void) { return clock_at_init; }
#else
CmuxLaunchClock cmux_launch_clock(void) { CmuxLaunchClock c = {0}; return c; }
#endif
