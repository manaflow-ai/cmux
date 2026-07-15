#include "include/GhosttyRuntimeTestStubs.h"

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}

void *ghostty_surface_new_with_scrollback_limit(
    void *app,
    const void *config,
    uintptr_t scrollback_limit_bytes
) {
    (void)app;
    (void)config;
    (void)scrollback_limit_bytes;
    return 0;
}
