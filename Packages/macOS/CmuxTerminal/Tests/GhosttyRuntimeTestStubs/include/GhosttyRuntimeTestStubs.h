#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stdint.h>

// Test-only stand-ins for the libghostty symbols referenced by CmuxTerminal
// and CmuxTerminalCore object files. SwiftPM cannot link the GhosttyKit macOS
// archive (its binary is not lib-prefixed), so the test runner provides these
// stubs to satisfy the link. No test ever calls them (tests construct no
// runtime surface), so only the symbol names matter; C symbols carry no type
// information for the linker.
typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

bool ghostty_surface_clear_selection(void *surface);

void ghostty_config_diagnostics_count(void);
void ghostty_config_get(void);
void ghostty_config_get_diagnostic(void);
void ghostty_config_load_file(void);
void ghostty_config_load_string(void);
void ghostty_string_free(void);
void ghostty_surface_read_selection(void);
void ghostty_surface_binding_action(void);
void ghostty_surface_config_new(void);
void ghostty_surface_free(void);
void ghostty_surface_free_text(void);
uint64_t ghostty_surface_foreground_pid(void *surface);
void ghostty_surface_has_selection(void);
void ghostty_surface_key(void);
void ghostty_surface_mouse_button(void);
void ghostty_surface_mouse_pos(void);
void ghostty_surface_mouse_scroll(void);
void ghostty_surface_needs_confirm_quit(void);
void ghostty_surface_new(void);
void ghostty_surface_process_exited(void);
void ghostty_surface_process_output(void);
void ghostty_surface_quicklook_font(void);
void ghostty_surface_read_text(void);
void ghostty_surface_refresh(void);
void ghostty_surface_render_grid_json(void);
void ghostty_surface_set_content_scale(void);
void ghostty_surface_set_display_id(void);
void ghostty_surface_set_focus(void);
void ghostty_surface_set_occlusion(void);
void ghostty_surface_set_renderer_realized(void);
void ghostty_surface_set_size(void);
void ghostty_surface_size(void);
void ghostty_surface_text(void);
void ghostty_surface_text_input(void);
ghostty_string_s ghostty_surface_tty_name(void *surface);

// Test-only stand-in for the GhosttyKit symbol referenced by
// CmuxTerminalCore's GhosttyWindowBlurInterop.applyWindowBackgroundBlur; no
// test calls it. Matches GhosttyKit's
// `void ghostty_set_window_background_blur(ghostty_app_t, void*)`.
void ghostty_set_window_background_blur(void *app, void *window);

// Test-only stand-in for the GhosttyKit symbol referenced by CmuxTerminal's
// NSEvent+GhosttyKeyEvent (translation-mods resolution). No test calls it; the
// linker only needs the symbol. Real signature returns/takes ghostty_input_mods_e
// (a uint32-backed enum); the width matches so the C stub links cleanly.
uint32_t ghostty_surface_key_translation_mods(void *surface, uint32_t mods);

#endif
