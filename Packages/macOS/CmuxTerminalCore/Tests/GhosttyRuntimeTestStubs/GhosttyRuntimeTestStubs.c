#include "include/GhosttyRuntimeTestStubs.h"

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

bool ghostty_surface_select_screen_rows(void *surface,
                                        unsigned int top_y,
                                        unsigned int bottom_y) {
    (void)surface;
    (void)top_y;
    (void)bottom_y;
    return false;
}

bool ghostty_surface_selection_screen_rows(void *surface,
                                           unsigned int *top_y,
                                           unsigned int *bottom_y) {
    (void)surface;
    (void)top_y;
    (void)bottom_y;
    return false;
}

void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}
