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
static uint64_t cmux_test_occlusion_call_count = 0;
static uintptr_t cmux_test_last_occlusion_surface = 0;
static bool cmux_test_last_occlusion_visible = true;
static uint64_t cmux_test_call_sequence = 0;
static uint64_t cmux_test_last_occlusion_sequence = 0;
static uint64_t cmux_test_last_refresh_sequence = 0;
static ghostty_surface_t cmux_test_created_surface = NULL;

void cmux_test_ghostty_runtime_stubs_reset(void) {
    cmux_test_needs_confirm_quit = false;
    cmux_test_foreground_pid = 0;
    cmux_test_tty_name = NULL;
}

void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name) {
    cmux_test_needs_confirm_quit = needs_confirm;
    cmux_test_foreground_pid = foreground_pid;
    cmux_test_tty_name = tty_name;
}

uint64_t cmux_test_ghostty_runtime_stubs_occlusion_call_count(void) {
    return cmux_test_occlusion_call_count;
}

uintptr_t cmux_test_ghostty_runtime_stubs_last_occlusion_surface(void) {
    return cmux_test_last_occlusion_surface;
}

bool cmux_test_ghostty_runtime_stubs_last_occlusion_visible(void) {
    return cmux_test_last_occlusion_visible;
}

uint64_t cmux_test_ghostty_runtime_stubs_last_occlusion_sequence(void) {
    return cmux_test_last_occlusion_sequence;
}

uint64_t cmux_test_ghostty_runtime_stubs_last_refresh_sequence(void) {
    return cmux_test_last_refresh_sequence;
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
void ghostty_surface_binding_action(void) {}
ghostty_surface_config_s ghostty_surface_config_new(void) {
    return (ghostty_surface_config_s){0};
}
void ghostty_surface_free(ghostty_surface_t surface) {
    if (surface == cmux_test_created_surface) {
        free(surface);
        cmux_test_created_surface = NULL;
    }
}
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
ghostty_surface_t ghostty_surface_new(ghostty_app_t app, const ghostty_surface_config_s* config) {
    (void)app;
    (void)config;
    cmux_test_created_surface = malloc(1);
    return cmux_test_created_surface;
}
bool ghostty_surface_process_exited(void *surface) {
    (void)surface;
    return false;
}
void ghostty_surface_process_output(void) {}
void* ghostty_surface_quicklook_font(ghostty_surface_t surface) {
    (void)surface;
    return NULL;
}
void ghostty_surface_read_screen_tail_vt(void) {}
void ghostty_surface_read_text(void) {}
void ghostty_surface_refresh(ghostty_surface_t surface) {
    if (surface == cmux_test_created_surface) {
        cmux_test_last_refresh_sequence = ++cmux_test_call_sequence;
    }
}
void ghostty_surface_render_grid_json(void) {}
void ghostty_surface_render_grid_json_with_theme(void) {}
void ghostty_surface_set_content_scale(void) {}
void ghostty_surface_set_display_id(void) {}
void ghostty_surface_set_focus(void) {}
void ghostty_surface_set_occlusion(void *surface, bool visible) {
    if (surface != cmux_test_created_surface) {
        return;
    }
    cmux_test_occlusion_call_count += 1;
    cmux_test_last_occlusion_surface = (uintptr_t)surface;
    cmux_test_last_occlusion_visible = visible;
    cmux_test_last_occlusion_sequence = ++cmux_test_call_sequence;
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
void cmux_test_ghostty_runtime_stubs_reset_occlusion(void) {
    cmux_test_occlusion_call_count = 0;
    cmux_test_last_occlusion_surface = 0;
    cmux_test_last_occlusion_visible = true;
    cmux_test_call_sequence = 0;
    cmux_test_last_occlusion_sequence = 0;
    cmux_test_last_refresh_sequence = 0;
}
