#include "include/GhosttyRuntimeTestStubs.h"

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

bool ghostty_surface_set_renderer_realized(void *surface, bool realized) {
    (void)surface;
    (void)realized;
    return false;
}

void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}
