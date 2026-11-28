#ifndef CMUX_MOBILE_LAUNCH_CLOCK_H
#define CMUX_MOBILE_LAUNCH_CLOCK_H

/// What the process had done when the main executable's first static initializer ran
/// (after dyld loaded and bound every image and ran their initializers), read once by
/// that initializer: the split of "process start to main" that LaunchMarks cannot see.
typedef struct {
    /// 1 when the initializer ran and the kernel answered; 0 otherwise (the rest are 0).
    int valid;
    /// Wall time since the kernel started the process, ms.
    double wall_ms;
    /// CPU time the process had used (user + system, all threads), ms. Far below
    /// wall_ms: the process waited (spawned suspended, disk, page faults), not computed.
    double cpu_ms;
    /// Page-ins so far (a cold binary or shared cache reads from disk).
    unsigned long long pageins;
} CmuxLaunchClock;

CmuxLaunchClock cmux_launch_clock(void);

#endif
