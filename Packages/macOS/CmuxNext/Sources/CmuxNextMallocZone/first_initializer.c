#include "CmuxNextMallocZone.h"

#include <sys/time.h>

// When the app's own code first ran: this image's initializers (dyld runs them after it mapped and bound every
// image the executable links and ran the system libraries' initializers). On the launch marks' clock, the wall
// clock `sysctl` KERN_PROC `p_starttime` is on, so process start to this is exec plus dyld, and this to `main` is
// our static initializers (startup-tti). One gettimeofday, no allocation; read once from `main`.
static double g_first_initializer_epoch;

__attribute__((constructor)) static void cmux_next_note_first_initializer(void) {
    struct timeval now;
    if (gettimeofday(&now, 0) == 0) g_first_initializer_epoch = (double)now.tv_sec + (double)now.tv_usec / 1e6;
}

double cmux_next_first_initializer_epoch(void) { return g_first_initializer_epoch; }
