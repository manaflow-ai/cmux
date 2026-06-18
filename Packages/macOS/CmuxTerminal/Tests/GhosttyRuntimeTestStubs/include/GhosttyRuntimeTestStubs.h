#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>

// Test-only stand-ins for the libghostty symbols referenced by CmuxTerminal
// and CmuxTerminalCore object files. SwiftPM cannot link the GhosttyKit macOS
// archive (its binary is not lib-prefixed), so the test runner provides these
// stubs to satisfy the link. No test ever calls them (tests construct no
// runtime surface), so only the symbol names matter; C symbols carry no type
// information for the linker.
bool ghostty_surface_clear_selection(void *surface);

void ghostty_config_diagnostics_count(void);
void ghostty_config_get_diagnostic(void);
void ghostty_string_free(void);
void ghostty_surface_binding_action(void);
void ghostty_surface_config_new(void);
void ghostty_surface_free(void);
void ghostty_surface_free_text(void);
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

#endif
