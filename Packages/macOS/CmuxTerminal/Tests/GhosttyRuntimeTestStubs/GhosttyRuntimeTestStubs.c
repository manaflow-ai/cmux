#include "include/GhosttyRuntimeTestStubs.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

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
static uint32_t cmux_test_tty_name_call_count = 0;
static void* cmux_test_renderer_realized_target = NULL;
static bool cmux_test_renderer_realized_calls[16];
static uint32_t cmux_test_renderer_realized_call_count = 0;
static uint32_t cmux_test_renderer_rebuild_call_count = 0;
static bool cmux_test_renderer_realized_result = true;
static bool cmux_test_renderer_occlusion_visible = true;
static bool cmux_test_renderer_release_was_occluded = false;
static void* cmux_test_last_updated_surface = NULL;
static void* cmux_test_font_surface = NULL;
static float cmux_test_font_runtime_points = 0;
static float cmux_test_font_configured_runtime_points = 0;
static bool cmux_test_font_adjusted = false;
static bool cmux_test_font_binding_succeeds = true;
static void* cmux_test_font_callback_surface = NULL;
static ghostty_font_size_action_cb cmux_test_font_callback = NULL;
static void* cmux_test_font_callback_userdata = NULL;
static pthread_mutex_t cmux_test_surface_free_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cmux_test_surface_free_condition = PTHREAD_COND_INITIALIZER;
static bool cmux_test_surface_free_should_block = false;
static bool cmux_test_surface_free_started = false;
static bool cmux_test_surface_free_released = false;
static void* cmux_test_surface_free_target = NULL;
static pthread_mutex_t cmux_test_process_output_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cmux_test_process_output_condition = PTHREAD_COND_INITIALIZER;
static bool cmux_test_process_output_should_block = false;
static bool cmux_test_process_output_started = false;
static bool cmux_test_process_output_released = false;
static bool cmux_test_process_output_called_on_main = false;
static void* cmux_test_process_output_target = NULL;

static struct timespec cmux_test_surface_free_timeout(void) {
    return (struct timespec) {
        .tv_sec = 5,
        .tv_nsec = 0,
    };
}

void cmux_test_ghostty_runtime_stubs_reset(void) {
    cmux_test_needs_confirm_quit = false;
    cmux_test_foreground_pid = 0;
    cmux_test_tty_name = NULL;
    cmux_test_tty_name_call_count = 0;
}

void cmux_test_ghostty_surface_free_blocking_begin(void *surface) {
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    cmux_test_surface_free_should_block = true;
    cmux_test_surface_free_started = false;
    cmux_test_surface_free_released = false;
    cmux_test_surface_free_target = surface;
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
}

bool cmux_test_ghostty_surface_free_wait_until_started(void) {
    const struct timespec timeout = cmux_test_surface_free_timeout();
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    while (!cmux_test_surface_free_started) {
        const int result = pthread_cond_timedwait_relative_np(
            &cmux_test_surface_free_condition,
            &cmux_test_surface_free_mutex,
            &timeout
        );
        if (result != 0) break;
    }
    const bool started = cmux_test_surface_free_started;
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
    return started;
}

bool cmux_test_ghostty_surface_free_blocking_did_start(void) {
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    const bool started = cmux_test_surface_free_started;
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
    return started;
}

bool cmux_test_ghostty_surface_free_blocking_is_active(void) {
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    const bool active =
        cmux_test_surface_free_should_block
        && cmux_test_surface_free_started
        && !cmux_test_surface_free_released
        && cmux_test_surface_free_target != NULL;
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
    return active;
}

void cmux_test_ghostty_surface_free_release(void) {
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    cmux_test_surface_free_released = true;
    pthread_cond_broadcast(&cmux_test_surface_free_condition);
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
}

void cmux_test_ghostty_surface_free_blocking_reset(void) {
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    cmux_test_surface_free_should_block = false;
    cmux_test_surface_free_started = false;
    cmux_test_surface_free_released = true;
    cmux_test_surface_free_target = NULL;
    pthread_cond_broadcast(&cmux_test_surface_free_condition);
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);
}

void cmux_test_ghostty_process_output_blocking_begin(void *surface) {
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    cmux_test_process_output_should_block = true;
    cmux_test_process_output_started = false;
    cmux_test_process_output_released = false;
    cmux_test_process_output_called_on_main = false;
    cmux_test_process_output_target = surface;
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
}

bool cmux_test_ghostty_process_output_wait_until_started(void) {
    const struct timespec timeout = cmux_test_surface_free_timeout();
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    while (!cmux_test_process_output_started) {
        const int result = pthread_cond_timedwait_relative_np(
            &cmux_test_process_output_condition,
            &cmux_test_process_output_mutex,
            &timeout
        );
        if (result != 0) break;
    }
    const bool started = cmux_test_process_output_started;
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
    return started;
}

bool cmux_test_ghostty_process_output_called_on_main_thread(void) {
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    const bool called_on_main = cmux_test_process_output_called_on_main;
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
    return called_on_main;
}

void cmux_test_ghostty_process_output_release(void) {
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    cmux_test_process_output_released = true;
    pthread_cond_broadcast(&cmux_test_process_output_condition);
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
}

void cmux_test_ghostty_process_output_blocking_reset(void) {
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    cmux_test_process_output_should_block = false;
    cmux_test_process_output_started = false;
    cmux_test_process_output_released = true;
    cmux_test_process_output_called_on_main = false;
    cmux_test_process_output_target = NULL;
    pthread_cond_broadcast(&cmux_test_process_output_condition);
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
}

void cmux_test_ghostty_renderer_realized_begin(void* surface) {
    cmux_test_renderer_realized_target = surface;
    cmux_test_renderer_realized_call_count = 0;
    cmux_test_renderer_rebuild_call_count = 0;
    cmux_test_renderer_realized_result = true;
    cmux_test_renderer_occlusion_visible = true;
    cmux_test_renderer_release_was_occluded = false;
}

void cmux_test_ghostty_renderer_realized_reset(void) {
    cmux_test_renderer_realized_target = NULL;
    cmux_test_renderer_realized_call_count = 0;
    cmux_test_renderer_rebuild_call_count = 0;
    cmux_test_renderer_realized_result = true;
    cmux_test_renderer_occlusion_visible = true;
    cmux_test_renderer_release_was_occluded = false;
}

bool cmux_test_ghostty_renderer_occlusion_visible(void) {
    return cmux_test_renderer_occlusion_visible;
}

void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name) {
    cmux_test_needs_confirm_quit = needs_confirm;
    cmux_test_foreground_pid = foreground_pid;
    cmux_test_tty_name = tty_name;
}

uint32_t cmux_test_ghostty_renderer_realized_call_count(void) {
    return cmux_test_renderer_realized_call_count;
}

uint32_t cmux_test_ghostty_renderer_rebuild_call_count(void) {
    return cmux_test_renderer_rebuild_call_count;
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
    if (surface == cmux_test_font_surface) {
        if (!cmux_test_font_binding_succeeds) return false;
        const float previous_points =
            cmux_test_font_runtime_points;
        const bool previous_adjusted =
            cmux_test_font_adjusted;
        int32_t observed_action = -1;
        char buffer[128];
        const uintptr_t copy_len =
            action_len < sizeof(buffer) - 1
                ? action_len
                : sizeof(buffer) - 1;
        memcpy(buffer, action, copy_len);
        buffer[copy_len] = '\0';
        const char *set_prefix = "set_font_size:";
        if (strncmp(
                buffer,
                set_prefix,
                strlen(set_prefix)
            ) == 0) {
            cmux_test_font_runtime_points =
                strtof(buffer + strlen(set_prefix), NULL);
            if (cmux_test_font_runtime_points > 255) {
                cmux_test_font_runtime_points = 255;
            }
            if (cmux_test_font_runtime_points < 1) {
                cmux_test_font_runtime_points = 1;
            }
            cmux_test_font_adjusted = true;
            observed_action = 3;
        } else if (strcmp(buffer, "reset_font_size") == 0) {
            cmux_test_font_runtime_points =
                cmux_test_font_configured_runtime_points;
            cmux_test_font_adjusted = false;
            observed_action = 2;
        } else if (strncmp(buffer, "increase_font_size:", 19) == 0) {
            cmux_test_font_runtime_points += strtof(buffer + 19, NULL);
            if (cmux_test_font_runtime_points > 255) {
                cmux_test_font_runtime_points = 255;
            }
            cmux_test_font_adjusted = true;
            observed_action = 0;
        } else if (strncmp(buffer, "decrease_font_size:", 19) == 0) {
            cmux_test_font_runtime_points -= strtof(buffer + 19, NULL);
            if (cmux_test_font_runtime_points < 1) {
                cmux_test_font_runtime_points = 1;
            }
            cmux_test_font_adjusted = true;
            observed_action = 1;
        }
        if (observed_action >= 0
            && cmux_test_font_callback_surface == surface
            && cmux_test_font_callback != NULL) {
            cmux_test_font_callback(
                cmux_test_font_callback_userdata,
                observed_action,
                previous_points,
                cmux_test_font_runtime_points,
                previous_adjusted,
                cmux_test_font_adjusted);
        }
    }
    return true;
}

bool ghostty_surface_set_font_size_action_callback(
    void *surface,
    ghostty_font_size_action_cb callback,
    void *userdata
) {
    if (surface == NULL || callback == NULL) return false;
    cmux_test_font_callback_surface = surface;
    cmux_test_font_callback = callback;
    cmux_test_font_callback_userdata = userdata;
    return true;
}

void ghostty_surface_config_new(void) {}
void ghostty_surface_free(void *surface) {
    const struct timespec timeout = cmux_test_surface_free_timeout();
    pthread_mutex_lock(&cmux_test_surface_free_mutex);
    if (cmux_test_surface_free_should_block
        && surface == cmux_test_surface_free_target) {
        cmux_test_surface_free_started = true;
        pthread_cond_broadcast(&cmux_test_surface_free_condition);
        while (!cmux_test_surface_free_released) {
            const int result = pthread_cond_timedwait_relative_np(
                &cmux_test_surface_free_condition,
                &cmux_test_surface_free_mutex,
                &timeout
            );
            if (result != 0) break;
        }
        cmux_test_surface_free_should_block = false;
        cmux_test_surface_free_target = NULL;
    }
    pthread_mutex_unlock(&cmux_test_surface_free_mutex);

    if (cmux_test_font_callback_surface == surface) {
        cmux_test_font_callback_surface = NULL;
        cmux_test_font_callback = NULL;
        cmux_test_font_callback_userdata = NULL;
    }
}
void ghostty_surface_free_text(void) {}
float ghostty_surface_font_size(void *surface) {
    return surface == cmux_test_font_surface
        ? cmux_test_font_runtime_points
        : 0;
}
bool ghostty_surface_font_size_adjusted(void *surface) {
    return surface == cmux_test_font_surface
        && cmux_test_font_adjusted;
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
void ghostty_surface_process_output(void *surface, const char *data, uintptr_t len) {
    (void)data;
    (void)len;
    pthread_mutex_lock(&cmux_test_process_output_mutex);
    if (cmux_test_process_output_should_block
        && surface == cmux_test_process_output_target) {
        cmux_test_process_output_started = true;
        cmux_test_process_output_called_on_main = pthread_main_np() != 0;
        pthread_cond_broadcast(&cmux_test_process_output_condition);
        while (!cmux_test_process_output_released) {
            const struct timespec timeout = cmux_test_surface_free_timeout();
            const int result = pthread_cond_timedwait_relative_np(
                &cmux_test_process_output_condition,
                &cmux_test_process_output_mutex,
                &timeout
            );
            if (result != 0) break;
        }
        cmux_test_process_output_should_block = false;
        cmux_test_process_output_target = NULL;
    }
    pthread_mutex_unlock(&cmux_test_process_output_mutex);
}
void ghostty_surface_quicklook_font(void) {}
void ghostty_surface_read_screen_tail_vt(void) {}
void ghostty_surface_read_text(void) {}
void ghostty_surface_refresh(void) {}
void ghostty_surface_render_grid_json(void) {}
void ghostty_surface_render_grid_json_with_theme(void) {}
ghostty_string_s ghostty_surface_render_grid_json_v2(
    void *surface,
    const char *surface_id,
    uintptr_t surface_id_len,
    uint64_t state_seq,
    uintptr_t scrollback_lines,
    bool include_theme,
    bool anchor_active) {
    (void)surface;
    (void)surface_id;
    (void)surface_id_len;
    (void)state_seq;
    (void)scrollback_lines;
    (void)include_theme;
    (void)anchor_active;
    return (ghostty_string_s){0};
}
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
bool ghostty_surface_rebuild_renderer(void *surface) {
    if (surface != cmux_test_renderer_realized_target) return true;
    cmux_test_renderer_rebuild_call_count++;
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
    cmux_test_tty_name_call_count++;
    if (cmux_test_tty_name == NULL) {
        return (ghostty_string_s){0};
    }
    return (ghostty_string_s){.ptr = cmux_test_tty_name, .len = strlen(cmux_test_tty_name), .sentinel = false};
}

uint32_t cmux_test_ghostty_tty_name_call_count(void) {
    return cmux_test_tty_name_call_count;
}

bool cmux_test_ghostty_surface_was_updated(void *surface) {
    return surface == cmux_test_last_updated_surface;
}

void cmux_test_ghostty_font_state_begin(
    void *surface,
    float runtime_points,
    bool adjusted,
    float configured_runtime_points
) {
    cmux_test_font_surface = surface;
    cmux_test_font_runtime_points = runtime_points;
    cmux_test_font_adjusted = adjusted;
    cmux_test_font_configured_runtime_points =
        configured_runtime_points;
    cmux_test_font_binding_succeeds = true;
}

void cmux_test_ghostty_font_state_end(void) {
    cmux_test_font_surface = NULL;
    cmux_test_font_runtime_points = 0;
    cmux_test_font_configured_runtime_points = 0;
    cmux_test_font_adjusted = false;
    cmux_test_font_binding_succeeds = true;
    cmux_test_font_callback_surface = NULL;
    cmux_test_font_callback = NULL;
    cmux_test_font_callback_userdata = NULL;
}

void cmux_test_ghostty_font_binding_result(bool result) {
    cmux_test_font_binding_succeeds = result;
}
