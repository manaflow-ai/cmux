// Fork API 30 wrappers: the helper-app browser process
// (plans/cmux-next/cef-helper-app-DESIGN.md 3.3 and 6). Detached hosting and
// its key state, input on the user-input queue, wheel phases, the text input
// watch, the remote accessibility token and page drags. Fork API 31 (task
// 227): the app's own choosers, screen-share picker and locks, a detached
// page's display and page state per entry. Each returns 0 (or does nothing)
// when the fork lacks the call. UI thread only unless noted.

#include <vector>

#include "include/cef_drag_data.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// The app's fork API 31 handlers (UI thread). The fork calls the trampolines
// below, which call the app's fn with its context and the event.
using ColorFn = void (*)(void* context, int event, int browser_id, int64_t token, unsigned int color,
                         const void* data);
using ChooserFn = void (*)(void* context, int event, int browser_id, int64_t token, const void* data);
using LockFn = void (*)(void* context, int event, int browser_id, int escape_locked);

struct AppHandlers {
  AppHandler<ColorFn> color;
  AppHandler<ChooserFn> device;
  AppHandler<ChooserFn> desktop_media;
  AppHandler<LockFn> lock;
};

AppHandlers& app_handlers() {
  static AppHandlers handlers;
  return handlers;
}

void ColorOpen(void*, int browser_id, const ForkColorChooserHead* chooser) {
  const auto& app = app_handlers().color;
  if (app.fn) app.fn(app.context, CMUX_SHIM_COLOR_CHOOSER_OPEN, browser_id, chooser->token, chooser->color, chooser);
}
void ColorSet(void*, int64_t token, uint32_t color) {
  const auto& app = app_handlers().color;
  if (app.fn) app.fn(app.context, CMUX_SHIM_COLOR_CHOOSER_SET_COLOR, 0, token, color, nullptr);
}
void ColorEnd(void*, int64_t token) {
  const auto& app = app_handlers().color;
  if (app.fn) app.fn(app.context, CMUX_SHIM_COLOR_CHOOSER_END, 0, token, 0, nullptr);
}

void DeviceUpdate(void*, int browser_id, const ForkTokenHead* state) {
  const auto& app = app_handlers().device;
  if (app.fn) app.fn(app.context, CMUX_SHIM_DEVICE_CHOOSER_UPDATE, browser_id, state->token, state);
}
void DeviceClose(void*, int64_t token) {
  const auto& app = app_handlers().device;
  if (app.fn) app.fn(app.context, CMUX_SHIM_DEVICE_CHOOSER_CLOSE, 0, token, nullptr);
}

void MediaOpen(void*, int browser_id, const ForkTokenHead* request) {
  const auto& app = app_handlers().desktop_media;
  if (app.fn) app.fn(app.context, CMUX_SHIM_DESKTOP_MEDIA_OPEN, browser_id, request->token, request);
}
void MediaClose(void*, int64_t token) {
  const auto& app = app_handlers().desktop_media;
  if (app.fn) app.fn(app.context, CMUX_SHIM_DESKTOP_MEDIA_CLOSE, 0, token, nullptr);
}

void Lock(int event, int browser_id, int escape_locked) {
  const auto& app = app_handlers().lock;
  if (app.fn) app.fn(app.context, event, browser_id, escape_locked);
}
void PointerLockRequested(void*, int browser_id) {
  Lock(CMUX_SHIM_POINTER_LOCK_REQUESTED, browser_id, 0);
}
void PointerUnlocked(void*, int browser_id) {
  Lock(CMUX_SHIM_POINTER_UNLOCKED, browser_id, 0);
}
void KeyboardLockRequested(void*, int browser_id, int escape_locked) {
  Lock(CMUX_SHIM_KEYBOARD_LOCK_REQUESTED, browser_id, escape_locked);
}
void KeyboardUnlocked(void*, int browser_id) {
  Lock(CMUX_SHIM_KEYBOARD_UNLOCKED, browser_id, 0);
}

// Fork API 31 (task 172): the renderer's answer to a DragTarget* enter or
// over, which the app's drag destination returns from -draggingUpdated:.
void DragAnswered(void*, int browser_id, int operation, int document_is_handling_drag) {
  Emit(CMUX_SHIM_DRAG_OPERATION, browser_id, 0, operation, document_is_handling_drag);
}

// The detached page a drop goes to: none without fork API 31, whose
// DragTarget* reach a detached page (task 172; before it CEF's windowed
// path DCHECKs).
CefRefPtr<CefBrowserHost> DropTarget(int browser_id) {
  if (!fork_api().browser_drag_target_watch) return nullptr;
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  return browser ? browser->GetHost() : nullptr;
}

CefMouseEvent DragEvent(int x, int y, int modifiers) {
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = static_cast<uint32_t>(modifiers);
  return event;
}

}  // namespace

extern "C" {

int cmux_shim_browser_set_detached_hosting(int browser_id, int enabled) {
  if (!fork_api().browser_set_detached_hosting) return 0;
  return fork_api().browser_set_detached_hosting(browser_id, enabled ? 1 : 0);
}

int cmux_shim_browser_set_embedder_active(int browser_id, int active) {
  // cmux's mark decides focus requests in host mode even on a fork without
  // the call (RefusesFocus); first, as the fork focuses the page inside it.
  NoteEmbedderActive(browser_id, active != 0);
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

// Drops into a detached page (task 050): Chrome's WebDragDest makes the same
// four calls (content/browser/web_contents/web_drag_dest_mac.mm), with drop
// data from PopulateDropDataFromPasteboard.
int cmux_shim_browser_drag_target_enter(int browser_id, const char* const* files, int file_count, const char* text,
                                        const char* url, const char* url_title, int x, int y, int allowed_operations,
                                        int modifiers) {
  CefRefPtr<CefBrowserHost> host = DropTarget(browser_id);
  if (!host) return 0;
  CefRefPtr<CefDragData> data = CefDragData::Create();
  for (int i = 0; files && i < file_count; ++i) {
    if (files[i] && *files[i]) data->AddFile(files[i], CefString());
  }
  if (text && *text) data->SetFragmentText(text);
  if (url && *url) {
    data->SetLinkURL(url);
    if (url_title && *url_title) data->SetLinkTitle(url_title);
  }
  // One watch per browser: this replaces the last enter's.
  fork_api().browser_drag_target_watch(browser_id, &DragAnswered, nullptr);
  host->DragTargetDragEnter(data, DragEvent(x, y, modifiers), static_cast<cef_drag_operations_mask_t>(allowed_operations));
  return 1;
}

int cmux_shim_browser_drag_target_over(int browser_id, int x, int y, int allowed_operations, int modifiers) {
  CefRefPtr<CefBrowserHost> host = DropTarget(browser_id);
  if (!host) return 0;
  host->DragTargetDragOver(DragEvent(x, y, modifiers), static_cast<cef_drag_operations_mask_t>(allowed_operations));
  return 1;
}

int cmux_shim_browser_drag_target_leave(int browser_id) {
  CefRefPtr<CefBrowserHost> host = DropTarget(browser_id);
  if (!host) return 0;
  host->DragTargetDragLeave();
  return 1;
}

int cmux_shim_browser_drag_target_drop(int browser_id, int x, int y, int modifiers) {
  CefRefPtr<CefBrowserHost> host = DropTarget(browser_id);
  if (!host) return 0;
  host->DragTargetDrop(DragEvent(x, y, modifiers));
  return 1;
}

// Fork API 31 (task 227).

int cmux_shim_set_color_chooser_handler(ColorFn fn, void* context) {
  static const ForkColorChooserHandler handler = {sizeof(ForkColorChooserHandler), &ColorOpen, &ColorSet, &ColorEnd,
                                                  nullptr};
  return SetAppHandler(fork_api().set_color_chooser_handler, &handler, app_handlers().color, fn, context);
}

int cmux_shim_color_chooser_choose(int64_t token, unsigned int color) {
  if (!fork_api().color_chooser_choose) return 0;
  return fork_api().color_chooser_choose(token, color);
}

int cmux_shim_color_chooser_end(int64_t token) {
  if (!fork_api().color_chooser_end) return 0;
  return fork_api().color_chooser_end(token);
}

int cmux_shim_set_device_chooser_handler(ChooserFn fn, void* context) {
  static const ForkDeviceChooserHandler handler = {sizeof(ForkDeviceChooserHandler), &DeviceUpdate, &DeviceClose,
                                                   nullptr};
  return SetAppHandler(fork_api().set_device_chooser_handler, &handler, app_handlers().device, fn, context);
}

int cmux_shim_device_chooser_answer(int64_t token, int action, const cmux_shim_device_choice* choices,
                                    int choice_count) {
  std::vector<int> indices;
  if (!fork_api().device_chooser_answer || !DeviceChoiceIndices(choices, choice_count, &indices)) return 0;
  return fork_api().device_chooser_answer(token, action, indices.data(), static_cast<int>(indices.size()));
}

int cmux_shim_set_desktop_media_handler(ChooserFn fn, void* context) {
  static const ForkDesktopMediaHandler handler = {sizeof(ForkDesktopMediaHandler), &MediaOpen, &MediaClose, nullptr};
  return SetAppHandler(fork_api().set_desktop_media_handler, &handler, app_handlers().desktop_media, fn, context);
}

int cmux_shim_desktop_media_answer(int64_t token, int source_type, int64_t native_id, int tab_browser_id,
                                   int audio) {
  if (!fork_api().desktop_media_answer) return 0;
  return fork_api().desktop_media_answer(token, source_type,
                                         DesktopMediaAnswerId(source_type, native_id, tab_browser_id), audio);
}

int cmux_shim_set_lock_handler(LockFn fn, void* context) {
  static const ForkLockHandler handler = {sizeof(ForkLockHandler), &PointerLockRequested, &PointerUnlocked,
                                          &KeyboardLockRequested, &KeyboardUnlocked, nullptr};
  return SetAppHandler(fork_api().set_lock_handler, &handler, app_handlers().lock, fn, context);
}

int cmux_shim_browser_pointer_lock_answer(int browser_id, int allowed) {
  if (!fork_api().browser_pointer_lock_answer) return 0;
  return fork_api().browser_pointer_lock_answer(browser_id, allowed ? 1 : 0);
}

int cmux_shim_browser_keyboard_lock_answer(int browser_id, int allowed) {
  if (!fork_api().browser_keyboard_lock_answer) return 0;
  return fork_api().browser_keyboard_lock_answer(browser_id, allowed ? 1 : 0);
}

int cmux_shim_browser_exit_pointer_lock(int browser_id, int by_user) {
  if (!fork_api().browser_exit_pointer_lock) return 0;
  return fork_api().browser_exit_pointer_lock(browser_id, by_user ? 1 : 0);
}

int cmux_shim_browser_exit_keyboard_lock(int browser_id) {
  if (!fork_api().browser_exit_keyboard_lock) return 0;
  return fork_api().browser_exit_keyboard_lock(browser_id);
}

int cmux_shim_browser_send_locked_mouse_move(int browser_id, double dx, double dy, int modifiers) {
  if (!fork_api().browser_send_locked_mouse_move) return 0;
  return fork_api().browser_send_locked_mouse_move(browser_id, dx, dy, modifiers);
}

int cmux_shim_browser_set_page_display(int browser_id, unsigned int display_id, double screen_x, double screen_y) {
  if (!fork_api().browser_set_page_display) return 0;
  return fork_api().browser_set_page_display(browser_id, display_id, screen_x, screen_y);
}

char* cmux_shim_tab_entry_page_state(int browser_id, int index) {
  if (!fork_api().tab_entry_page_state) return nullptr;
  return fork_api().tab_entry_page_state(browser_id, index);
}

int cmux_shim_tab_page_state_watch(int browser_id, void (*fn)(void* context, int browser_id, int index),
                                   void* context) {
  if (!fork_api().tab_page_state_watch) return 0;
  return fork_api().tab_page_state_watch(browser_id, fn, context);
}

int cmux_shim_tab_restore_entries(int browser_id, const cmux_shim_restore_entry* entries, int count, int current) {
  if (!fork_api().tab_restore_entries) return 0;
  const RestoreEntries copies(entries, count);
  if (copies.count() == 0) return -3;  // as the fork answers no entries
  return fork_api().tab_restore_entries(browser_id, copies.data(), copies.count(), current);
}

}  // extern "C"
