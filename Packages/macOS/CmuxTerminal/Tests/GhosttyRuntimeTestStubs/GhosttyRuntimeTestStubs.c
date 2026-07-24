#include "include/GhosttyRuntimeTestStubs.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} GhosttyRuntimeTestColor;

typedef struct {
    GhosttyRuntimeTestColor foreground;
    bool has_foreground;
    uint32_t diagnostics_count;
} GhosttyRuntimeTestConfig;

static bool cmux_test_needs_confirm_quit = false;
static uint64_t cmux_test_foreground_pid = 0;
static const char* cmux_test_tty_name = NULL;
static void* cmux_test_renderer_realized_target = NULL;
static bool cmux_test_renderer_realized_calls[16];
static uint32_t cmux_test_renderer_realized_call_count = 0;
static bool cmux_test_renderer_realized_result = true;
static bool cmux_test_renderer_occlusion_visible = true;
static bool cmux_test_renderer_release_was_occluded = false;
static void* cmux_test_last_updated_surface = NULL;

void cmux_test_ghostty_runtime_stubs_reset(void) {
    cmux_test_needs_confirm_quit = false;
    cmux_test_foreground_pid = 0;
    cmux_test_tty_name = NULL;
}

void cmux_test_ghostty_renderer_realized_begin(void* surface) {
    cmux_test_renderer_realized_target = surface;
    cmux_test_renderer_realized_call_count = 0;
    cmux_test_renderer_realized_result = true;
    cmux_test_renderer_occlusion_visible = true;
    cmux_test_renderer_release_was_occluded = false;
}

void cmux_test_ghostty_renderer_realized_reset(void) {
    cmux_test_renderer_realized_target = NULL;
    cmux_test_renderer_realized_call_count = 0;
    cmux_test_renderer_realized_result = true;
    cmux_test_renderer_occlusion_visible = true;
    cmux_test_renderer_release_was_occluded = false;
}

void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name) {
    cmux_test_needs_confirm_quit = needs_confirm;
    cmux_test_foreground_pid = foreground_pid;
    cmux_test_tty_name = tty_name;
}

uint32_t cmux_test_ghostty_renderer_realized_call_count(void) {
    return cmux_test_renderer_realized_call_count;
}

bool cmux_test_ghostty_renderer_realized_call_value(uint32_t index) {
    if (index >= cmux_test_renderer_realized_call_count) return false;
    return cmux_test_renderer_realized_calls[index];
}

void cmux_test_ghostty_renderer_realized_set_result(bool result) {
    cmux_test_renderer_realized_result = result;
}

bool cmux_test_ghostty_renderer_release_was_occluded(void) {
    return cmux_test_renderer_release_was_occluded;
}

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

void *ghostty_config_new(void) {
    return calloc(1, sizeof(GhosttyRuntimeTestConfig));
}

void ghostty_config_free(void *config) {
    free(config);
}

void ghostty_config_load_string(
    void *raw_config,
    const char *contents,
    uintptr_t contents_len,
    const char *path
) {
    (void)contents_len;
    (void)path;
    GhosttyRuntimeTestConfig *config = raw_config;
    const char *value = strchr(contents, '=');
    if (config == NULL || value == NULL) return;
    do { value++; } while (*value == ' ' || *value == '\t');

    if (strcasecmp(value, "black") == 0) {
        config->foreground = (GhosttyRuntimeTestColor){0, 0, 0};
        config->has_foreground = true;
        return;
    }

    config->diagnostics_count = 1;
}

bool ghostty_config_get(
    void *raw_config,
    void *raw_value,
    const char *key,
    uintptr_t key_len
) {
    GhosttyRuntimeTestConfig *config = raw_config;
    if (config == NULL || raw_value == NULL || !config->has_foreground ||
        key_len != strlen("foreground") || strncmp(key, "foreground", key_len) != 0) {
        return false;
    }
    *(GhosttyRuntimeTestColor *)raw_value = config->foreground;
    return true;
}

uint32_t ghostty_config_diagnostics_count(void *raw_config) {
    GhosttyRuntimeTestConfig *config = raw_config;
    return config == NULL ? 0 : config->diagnostics_count;
}

void ghostty_config_get_diagnostic(void) {}
void ghostty_string_free(ghostty_string_s string) {
    (void)string;
}
bool ghostty_surface_binding_action(
    void *surface,
    const char *action,
    uintptr_t action_len
) {
    (void)surface;
    (void)action;
    (void)action_len;
    return true;
}
void ghostty_surface_config_new(void) {}
void ghostty_surface_free(void) {}
void ghostty_surface_free_text(void) {}
float ghostty_surface_font_size(void *surface) {
    (void)surface;
    return 0;
}
bool ghostty_surface_font_size_adjusted(void *surface) {
    (void)surface;
    return false;
}
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
bool ghostty_surface_process_exited(void *surface) {
    (void)surface;
    return false;
}
void ghostty_surface_process_output(void) {}
void ghostty_surface_quicklook_font(void) {}
void ghostty_surface_read_screen_tail_vt(void) {}
void ghostty_surface_read_text(void) {}
void ghostty_surface_refresh(void) {}
void ghostty_surface_render_grid_json(void) {}
void ghostty_surface_render_grid_json_with_theme(void) {}
void ghostty_surface_set_content_scale(void) {}
void ghostty_surface_set_display_id(void) {}
void ghostty_surface_set_focus(void) {}
void ghostty_surface_set_occlusion(void *surface, bool visible) {
    if (surface != cmux_test_renderer_realized_target) return;
    cmux_test_renderer_occlusion_visible = visible;
}
bool ghostty_surface_set_renderer_realized(void *surface, bool realized) {
    if (surface != cmux_test_renderer_realized_target) return true;
    if (!realized) {
        cmux_test_renderer_release_was_occluded = !cmux_test_renderer_occlusion_visible;
    }
    if (cmux_test_renderer_realized_call_count < 16) {
        cmux_test_renderer_realized_calls[cmux_test_renderer_realized_call_count] = realized;
        cmux_test_renderer_realized_call_count++;
    }
    return cmux_test_renderer_realized_result;
}
void ghostty_surface_set_size(void) {}
void ghostty_surface_size(void) {}
void ghostty_surface_text(void) {}
void ghostty_surface_text_input(void) {}
void ghostty_surface_update_config(void *surface, void *raw_config) {
    (void)raw_config;
    cmux_test_last_updated_surface = surface;
}
ghostty_string_s ghostty_surface_tty_name(void *surface) {
    (void)surface;
    if (cmux_test_tty_name == NULL) {
        return (ghostty_string_s){0};
    }
    return (ghostty_string_s){.ptr = cmux_test_tty_name, .len = strlen(cmux_test_tty_name), .sentinel = false};
}

bool cmux_test_ghostty_surface_was_updated(void *surface) {
    return surface == cmux_test_last_updated_surface;
}
