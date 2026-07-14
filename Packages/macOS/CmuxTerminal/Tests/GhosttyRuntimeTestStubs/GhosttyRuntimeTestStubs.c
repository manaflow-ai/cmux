#include "include/GhosttyRuntimeTestStubs.h"
#include <string.h>

static bool cmux_test_needs_confirm_quit = false;
static uint64_t cmux_test_foreground_pid = 0;
static const char* cmux_test_tty_name = NULL;
static uint64_t cmux_test_occlusion_call_count = 0;
static bool cmux_test_last_occlusion_visible = false;
static uintptr_t cmux_test_last_scrollback_limit_bytes = 0;

void cmux_test_ghostty_runtime_stubs_reset(void) {
    cmux_test_needs_confirm_quit = false;
    cmux_test_foreground_pid = 0;
    cmux_test_tty_name = NULL;
    cmux_test_occlusion_call_count = 0;
    cmux_test_last_occlusion_visible = false;
    cmux_test_last_scrollback_limit_bytes = 0;
}

void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name) {
    cmux_test_needs_confirm_quit = needs_confirm;
    cmux_test_foreground_pid = foreground_pid;
    cmux_test_tty_name = tty_name;
}

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

void ghostty_config_diagnostics_count(void) {}
void ghostty_config_get_diagnostic(void) {}
bool ghostty_config_get(void *config, void *out, const char *key, uintptr_t len) {
    (void)config;
    (void)out;
    (void)key;
    (void)len;
    return false;
}
void ghostty_string_free(ghostty_string_s string) {
    (void)string;
}
void ghostty_surface_binding_action(void) {}
void ghostty_surface_config_new(void) {}
void ghostty_surface_free(void) {}
void ghostty_surface_free_text(void) {}
uint64_t ghostty_surface_foreground_pid(void *surface) {
    (void)surface;
    return cmux_test_foreground_pid;
}
void ghostty_surface_has_selection(void) {}
void ghostty_surface_key(void) {}
void ghostty_surface_mouse_button(void) {}
void ghostty_surface_mouse_pos(void) {}
void ghostty_surface_mouse_scroll(void) {}
bool ghostty_surface_needs_confirm_quit(void *surface) {
    (void)surface;
    return cmux_test_needs_confirm_quit;
}
void ghostty_surface_new(void) {}
void* ghostty_surface_new_with_scrollback_limit(void* app, const void* config, uintptr_t scrollback_limit_bytes) {
    (void)app;
    (void)config;
    cmux_test_last_scrollback_limit_bytes = scrollback_limit_bytes;
    return NULL;
}
bool ghostty_surface_process_exited(void *surface) {
    (void)surface;
    return false;
}
void ghostty_surface_process_output(void) {}
void ghostty_surface_quicklook_font(void) {}
void ghostty_surface_read_screen_tail_vt(void) {}
void ghostty_surface_read_text(void) {}
void ghostty_surface_refresh(void) {}
float ghostty_surface_font_size(void *surface) { (void)surface; return 12; }
bool ghostty_surface_font_size_adjusted(void *surface) { (void)surface; return false; }
void ghostty_surface_render_grid_json(void) {}
void ghostty_surface_set_content_scale(void) {}
void ghostty_surface_set_display_id(void) {}
void ghostty_surface_set_focus(void) {}
void ghostty_surface_set_occlusion(void *surface, bool visible) {
    (void)surface;
    cmux_test_occlusion_call_count += 1;
    cmux_test_last_occlusion_visible = visible;
}
void ghostty_surface_set_renderer_realized(void) {}
void ghostty_surface_set_size(void) {}
void ghostty_surface_size(void) {}
void ghostty_surface_text(void) {}
void ghostty_surface_text_input(void) {}
ghostty_string_s ghostty_surface_tty_name(void *surface) {
    (void)surface;
    if (cmux_test_tty_name == NULL) {
        return (ghostty_string_s){0};
    }
    return (ghostty_string_s){.ptr = cmux_test_tty_name, .len = strlen(cmux_test_tty_name), .sentinel = false};
}

uint64_t cmux_test_ghostty_surface_set_occlusion_call_count(void) {
    return cmux_test_occlusion_call_count;
}

bool cmux_test_ghostty_surface_last_occlusion_visible(void) {
    return cmux_test_last_occlusion_visible;
}

uintptr_t cmux_test_ghostty_surface_last_scrollback_limit_bytes(void) {
    return cmux_test_last_scrollback_limit_bytes;
}
