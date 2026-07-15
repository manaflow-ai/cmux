#include "include/GhosttyRuntimeTestStubs.h"

__attribute__((weak)) bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

__attribute__((weak)) void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}
