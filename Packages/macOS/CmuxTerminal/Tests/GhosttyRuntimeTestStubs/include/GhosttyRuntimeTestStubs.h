#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stdint.h>

// Test-only stand-ins for the libghostty symbols referenced by CmuxTerminal
// and CmuxTerminalCore object files. SwiftPM cannot link the GhosttyKit macOS
// archive (its binary is not lib-prefixed), so the test runner provides these
// stubs to satisfy the link. Most tests construct no runtime surface, but close
// confirmation tests configure the process/tty stubs below.
typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

typedef void (*ghostty_font_size_action_cb)(
    void* userdata,
    int32_t action,
    float previous_points,
    float current_points,
    bool previous_adjusted,
    bool current_adjusted);

bool ghostty_surface_clear_selection(void *surface);

void *ghostty_config_new(void);
void ghostty_config_free(void *config);
void ghostty_config_load_string(
    void *config,
    const char *contents,
    uintptr_t contents_len,
    const char *path);
ghostty_string_s ghostty_config_serialize(void *config);
bool ghostty_config_get(
    void *config,
    void *value,
    const char *key,
    uintptr_t key_len);
uint32_t ghostty_config_diagnostics_count(void *config);
void ghostty_config_get_diagnostic(void);
void ghostty_string_free(ghostty_string_s string);
bool ghostty_surface_binding_action(
    void *surface,
    const char *action,
    uintptr_t action_len);
bool ghostty_surface_set_font_size_action_callback(
    void *surface,
    ghostty_font_size_action_cb callback,
    void *userdata);
void ghostty_surface_config_new(void);
void ghostty_surface_free(void *surface);
void ghostty_surface_free_text(void);
float ghostty_surface_font_size(void *surface);
bool ghostty_surface_font_size_adjusted(void *surface);
uint64_t ghostty_surface_foreground_pid(void *surface);
void ghostty_surface_has_selection(void);
void ghostty_surface_key(void);
void ghostty_surface_mouse_button(void);
void ghostty_surface_mouse_pos(void);
void ghostty_surface_mouse_scroll(void);
bool ghostty_surface_needs_confirm_quit(void *surface);
void ghostty_surface_new(void);
bool ghostty_surface_process_exited(void *surface);
void ghostty_surface_process_output(void *surface, const char *data, uintptr_t len);
void ghostty_surface_quicklook_font(void);
void ghostty_surface_read_screen_tail_vt(void);
void ghostty_surface_read_text(void);
void ghostty_surface_refresh(void);
void ghostty_surface_render_grid_json(void);
void ghostty_surface_render_grid_json_with_theme(void);
ghostty_string_s ghostty_surface_render_grid_json_v2(
    void *surface,
    const char *surface_id,
    uintptr_t surface_id_len,
    uint64_t state_seq,
    uintptr_t scrollback_lines,
    bool include_theme,
    bool anchor_active);
void ghostty_surface_set_content_scale(void);
void ghostty_surface_set_display_id(void);
void ghostty_surface_set_focus(void);
void ghostty_surface_set_occlusion(void *surface, bool visible);
bool ghostty_surface_set_renderer_realized(void *surface, bool realized);
bool ghostty_surface_rebuild_renderer(void *surface);
void ghostty_surface_set_size(void);
void ghostty_surface_size(void);
void ghostty_surface_text(void);
void ghostty_surface_text_input(void);
void ghostty_surface_update_config(void *surface, void *config);
ghostty_string_s ghostty_surface_tty_name(void *surface);

void cmux_test_ghostty_runtime_stubs_reset(void);
void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name);
void cmux_test_ghostty_surface_free_blocking_begin(void *surface);
bool cmux_test_ghostty_surface_free_wait_until_started(void);
bool cmux_test_ghostty_surface_free_blocking_did_start(void);
bool cmux_test_ghostty_surface_free_blocking_is_active(void);
void cmux_test_ghostty_surface_free_release(void);
void cmux_test_ghostty_surface_free_blocking_reset(void);
void cmux_test_ghostty_process_output_blocking_begin(void *surface);
bool cmux_test_ghostty_process_output_wait_until_started(void);
bool cmux_test_ghostty_process_output_called_on_main_thread(void);
void cmux_test_ghostty_process_output_release(void);
void cmux_test_ghostty_process_output_blocking_reset(void);
uint32_t cmux_test_ghostty_tty_name_call_count(void);
void cmux_test_ghostty_renderer_realized_begin(void *surface);
void cmux_test_ghostty_renderer_realized_reset(void);
uint32_t cmux_test_ghostty_renderer_realized_call_count(void);
uint32_t cmux_test_ghostty_renderer_rebuild_call_count(void);
bool cmux_test_ghostty_renderer_realized_call_value(uint32_t index);
void cmux_test_ghostty_renderer_realized_set_result(bool result);
bool cmux_test_ghostty_renderer_release_was_occluded(void);
bool cmux_test_ghostty_renderer_occlusion_visible(void);
bool cmux_test_ghostty_surface_was_updated(void *surface);
void cmux_test_ghostty_font_state_begin(
    void *surface,
    float runtime_points,
    bool adjusted,
    float configured_runtime_points);
void cmux_test_ghostty_font_state_end(void);
void cmux_test_ghostty_font_binding_result(bool result);

#endif
