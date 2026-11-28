#include "CmuxMobileLaunchClock.h"

#if defined(__APPLE__)
// Public in the iOS SDK (libproc.h is not): the start time from sysctl, CPU from getrusage,
// page-ins from the task's event counters.
#include <mach/mach.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

static CmuxLaunchClock clock_at_init;

static double tv_ms(struct timeval t) { return (double)t.tv_sec * 1000.0 + (double)t.tv_usec / 1000.0; }

// Runs once, before main: dyld has loaded and bound every image and run their initializers.
__attribute__((constructor)) static void cmux_launch_clock_read(void) {
    struct timeval now;
    gettimeofday(&now, NULL);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc kp;
    size_t n = sizeof kp;
    if (sysctl(mib, 4, &kp, &n, NULL, 0) != 0 || n == 0) return;
    // p_starttime is wall clock, as LaunchMarks.processStart reads it.
    double wall = tv_ms(now) - tv_ms(kp.kp_proc.p_starttime);
    if (wall < 0) return;
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return;
    clock_at_init.wall_ms = wall;
    clock_at_init.cpu_ms = tv_ms(ru.ru_utime) + tv_ms(ru.ru_stime);
    task_events_info_data_t ev;
    mach_msg_type_number_t count = TASK_EVENTS_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&ev, &count) == KERN_SUCCESS) {
        clock_at_init.pageins = (unsigned long long)ev.pageins;
    }
    clock_at_init.valid = 1;
}

CmuxLaunchClock cmux_launch_clock(void) { return clock_at_init; }
#else
CmuxLaunchClock cmux_launch_clock(void) { CmuxLaunchClock c = {0}; return c; }
#endif
