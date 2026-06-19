#include "include/GhosttyRuntimeTestStubs.h"

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}

bool ghostty_config_get(void *config, void *out, const char *key, uintptr_t len) {
    (void)config;
    (void)out;
    (void)key;
    (void)len;
    return false;
}
