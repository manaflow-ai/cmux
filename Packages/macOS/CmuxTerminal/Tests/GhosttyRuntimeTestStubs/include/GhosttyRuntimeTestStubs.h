#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stddef.h>
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

typedef void* ghostty_app_t;
typedef void* ghostty_surface_t;
typedef int32_t ghostty_platform_e;
typedef int32_t ghostty_surface_context_e;
typedef int32_t ghostty_surface_io_mode_e;
typedef void (*ghostty_io_write_cb)(void*, const char*, uintptr_t);

typedef union {
  struct { void* nsview; } macos;
  struct { void* uiview; } ios;
} ghostty_platform_u;

// Matches ghostty_surface_config_s so the test stub can execute the real
// CmuxTerminal surface-creation path without linking libghostty.
typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  void* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;
  ghostty_surface_io_mode_e io_mode;
  ghostty_io_write_cb io_write_cb;
  void* io_write_userdata;
} ghostty_surface_config_s;

bool ghostty_surface_clear_selection(void *surface);

void *ghostty_config_new(void);
void ghostty_config_free(void *config);
void ghostty_config_load_string(
    void *config,
    const char *contents,
    uintptr_t contents_len,
    const char *path);
bool ghostty_config_get(
    void *config,
    void *value,
    const char *key,
    uintptr_t key_len);
uint32_t ghostty_config_diagnostics_count(void *config);
void ghostty_config_get_diagnostic(void);
void ghostty_string_free(ghostty_string_s string);
void ghostty_surface_binding_action(void);
ghostty_surface_config_s ghostty_surface_config_new(void);
void ghostty_surface_free(ghostty_surface_t surface);
void ghostty_surface_free_text(void);
uint64_t ghostty_surface_foreground_pid(void *surface);
void ghostty_surface_has_selection(void);
void ghostty_surface_key(void);
void ghostty_surface_mouse_button(void);
void ghostty_surface_mouse_pos(void);
void ghostty_surface_mouse_scroll(void);
bool ghostty_surface_needs_confirm_quit(void *surface);
ghostty_surface_t ghostty_surface_new(ghostty_app_t app, const ghostty_surface_config_s* config);
bool ghostty_surface_process_exited(void *surface);
void ghostty_surface_process_output(void);
void* ghostty_surface_quicklook_font(ghostty_surface_t surface);
void ghostty_surface_read_screen_tail_vt(void);
void ghostty_surface_read_text(void);
void ghostty_surface_refresh(ghostty_surface_t surface);
void ghostty_surface_render_grid_json(void);
void ghostty_surface_render_grid_json_with_theme(void);
void ghostty_surface_set_content_scale(void);
void ghostty_surface_set_display_id(void);
void ghostty_surface_set_focus(void);
void ghostty_surface_set_occlusion(void *surface, bool visible);
void ghostty_surface_set_renderer_realized(void);
void ghostty_surface_set_size(void);
void ghostty_surface_size(void);
void ghostty_surface_text(void);
void ghostty_surface_text_input(void);
ghostty_string_s ghostty_surface_tty_name(void *surface);

void cmux_test_ghostty_runtime_stubs_reset(void);
void cmux_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name);
void cmux_test_ghostty_runtime_stubs_reset_occlusion(void);
uint64_t cmux_test_ghostty_runtime_stubs_occlusion_call_count(void);
uintptr_t cmux_test_ghostty_runtime_stubs_last_occlusion_surface(void);
bool cmux_test_ghostty_runtime_stubs_last_occlusion_visible(void);
uint64_t cmux_test_ghostty_runtime_stubs_last_occlusion_sequence(void);
uint64_t cmux_test_ghostty_runtime_stubs_last_refresh_sequence(void);

#endif
