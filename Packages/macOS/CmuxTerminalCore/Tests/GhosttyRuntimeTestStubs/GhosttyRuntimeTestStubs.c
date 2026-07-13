#include "include/GhosttyRuntimeTestStubs.h"

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}

void ghostty_surface_inherited_config(void) {}
