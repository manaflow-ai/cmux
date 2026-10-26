// Fork API 30 wrappers: the helper-app browser process
// (plans/cmux-next/cef-helper-app-DESIGN.md 3.3 and 6). Detached hosting and
// its key state, input on the user-input queue, wheel phases, the text input
// watch, the remote accessibility token and page drags; fork API 31: the
// detached page's IME and composition bounds. Each returns 0 (or
// does nothing) when the fork lacks the call. UI thread only unless noted.

#include <cstddef>

#include "shim_internal.h"

using namespace cmux_shim;

// The fork reads these spans as its cmux_ime_span_t {int start, end, thick;
// uint32_t underline_color, background_color} (include/cef_cmux.h).
static_assert(sizeof(cmux_shim_ime_span) == 20 && offsetof(cmux_shim_ime_span, thick) == 8 &&
                  offsetof(cmux_shim_ime_span, underline_color) == 12 &&
                  offsetof(cmux_shim_ime_span, background_color) == 16,
              "cmux_shim_ime_span must keep the fork's cmux_ime_span_t layout");

// Fork API 31 (task p01-process-170): IME of a detached page, used from the
// release that declares API 31 (task 178), as cef_cmux.h's history says.
static bool HasDetachedIme() {
  return fork_api().version >= kDetachedImeForkApi;
}

extern "C" {

int cmux_shim_browser_set_detached_hosting(int browser_id, int enabled) {
  if (!fork_api().browser_set_detached_hosting) return 0;
  return fork_api().browser_set_detached_hosting(browser_id, enabled ? 1 : 0);
}

int cmux_shim_browser_set_embedder_active(int browser_id, int active) {
  if (!fork_api().browser_set_embedder_active) return 0;
  return fork_api().browser_set_embedder_active(browser_id, active ? 1 : 0);
}

int cmux_shim_post_user_input_task(void (*fn)(void* context), void* context) {
  if (!fork_api().post_user_input_task) return 0;
  return fork_api().post_user_input_task(fn, context);
}

int cmux_shim_browser_send_wheel(int browser_id, double x, double y, double dx, double dy, int precise, int phase,
                                 int momentum_phase, int modifiers) {
  if (!fork_api().browser_send_wheel) return 0;
  return fork_api().browser_send_wheel(browser_id, x, y, dx, dy, precise, phase, momentum_phase, modifiers);
}

int cmux_shim_browser_text_input_watch(int browser_id, void (*fn)(void* context, int browser_id, const void* state),
                                       void* context) {
  if (!fork_api().browser_text_input_watch) return 0;
  return fork_api().browser_text_input_watch(browser_id, fn, context);
}

int cmux_shim_browser_accessibility_token(int browser_id, int embedder_pid, const uint8_t* parent_token,
                                          int parent_token_length, const uint8_t* window_token,
                                          int window_token_length, uint8_t* out, int capacity) {
  if (!fork_api().browser_accessibility_token) return 0;
  return fork_api().browser_accessibility_token(browser_id, embedder_pid, parent_token, parent_token_length,
                                                window_token, window_token_length, out, capacity);
}

void cmux_shim_set_drag_source_handler(void (*fn)(void* context, int browser_id, const void* drag), void* context) {
  if (!fork_api().set_drag_source_handler) return;
  fork_api().set_drag_source_handler(fn, context);
}

int cmux_shim_browser_drag_source_ended(int browser_id, double x, double y, double screen_x, double screen_y,
                                        int operation) {
  if (!fork_api().browser_drag_source_ended) return 0;
  return fork_api().browser_drag_source_ended(browser_id, x, y, screen_x, screen_y, operation);
}

int cmux_shim_browser_drag_target_enter_source(int browser_id, int x, int y, int allowed_operations, int modifiers) {
  if (!fork_api().browser_drag_target_enter_source) return 0;
  return fork_api().browser_drag_target_enter_source(browser_id, x, y, allowed_operations, modifiers);
}

int cmux_shim_browser_ime_set_composition(int browser_id, const char* text, const cmux_shim_ime_span* spans,
                                          int span_count, int replacement_start, int replacement_end,
                                          int selection_start, int selection_end) {
  if (!HasDetachedIme() || !fork_api().browser_ime_set_composition) return 0;
  return fork_api().browser_ime_set_composition(browser_id, text, spans, span_count, replacement_start,
                                                replacement_end, selection_start, selection_end);
}

int cmux_shim_browser_ime_commit_text(int browser_id, const char* text, int replacement_start, int replacement_end) {
  if (!HasDetachedIme() || !fork_api().browser_ime_commit_text) return 0;
  return fork_api().browser_ime_commit_text(browser_id, text, replacement_start, replacement_end);
}

int cmux_shim_browser_ime_finish_composing(int browser_id) {
  if (!HasDetachedIme() || !fork_api().browser_ime_finish_composing) return 0;
  return fork_api().browser_ime_finish_composing(browser_id);
}

int cmux_shim_browser_ime_cancel(int browser_id) {
  if (!HasDetachedIme() || !fork_api().browser_ime_cancel) return 0;
  return fork_api().browser_ime_cancel(browser_id);
}

int cmux_shim_browser_composition_bounds_watch(int browser_id,
                                               void (*fn)(void* context, int browser_id, const void* bounds),
                                               void* context) {
  if (!HasDetachedIme() || !fork_api().browser_composition_bounds_watch) return 0;
  return fork_api().browser_composition_bounds_watch(browser_id, fn, context);
}

}  // extern "C"
