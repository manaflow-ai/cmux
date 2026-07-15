#include "include/GhosttyRuntimeTestStubs.h"

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_new_with_scrollback_limit(
    void *app,
    const void *config,
    size_t scrollback_limit_bytes
) {
    (void)app;
    (void)config;
    (void)scrollback_limit_bytes;
    return 0;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}
