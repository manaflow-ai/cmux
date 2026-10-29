// Per-browser commands: window creation, fork tab API, navigation, find,
// zoom, DevTools methods, extension actions, <select> popups.

#import <AppKit/AppKit.h>

#include <cstdint>
#include <cstring>

#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/cef_values.h"
#include "frame_renderers.h"
#include "renderer_end.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

CefRefPtr<CefBrowserHost> HostOf(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  return browser ? browser->GetHost() : nullptr;
}

// The one way the shim builds a Chromium window: a pane's (cmux_shim_create_window) and a spare's
// renderer-less placeholder window (cmux_shim_create_placeholder_window) differ only in `url` and
// `extra_info`.
int CreateWindowWith(int request, void* parent_view, int width, int height, const char* url,
                     const char* profile_cache_path, CefRefPtr<CefDictionaryValue> extra_info) {
  if (!parent_view || stopping()) {
    return 0;
  }
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)(__bridge NSView*)parent_view, CefRect(0, 0, width, height));
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  settings.background_color = BackgroundColor();
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path ? profile_cache_path : "");
  return CefBrowserHost::CreateBrowser(info, MakeClient(request), url ? url : "", settings, extra_info, context) ? 1 : 0;
}

// The renderer client id of each frame of browser (the main frame and every
// iframe, in its process or out of it; RendererClientIdOf): one entry per
// frame.
std::vector<int> FrameRendererClientIDs(CefRefPtr<CefBrowser> browser) {
  std::vector<int> clients;
  if (!browser) return clients;
  std::vector<CefString> identifiers;
  browser->GetFrameIdentifiers(identifiers);
  clients.reserve(identifiers.size());
  for (const CefString& identifier : identifiers) {
    const int id = RendererClientIdOf(identifier.ToString());
    if (id > 0) clients.push_back(id);
  }
  return clients;
}

// The fork's answer to one built-in extension load (cmux_ext_load_command_line_async, UI thread):
// a CMUX_SHIM_REPLY under the reply id cmux_shim_ext_load_command_line passed as the context.
void BuiltInLoadAnswered(void* context, int loaded) {
  Emit(CMUX_SHIM_REPLY, 0, static_cast<int>(reinterpret_cast<intptr_t>(context)), loaded == 1 ? 1 : 0, 0);
}

// <select> popups go to the host while it takes them (cmux_shim_set_popup_menus).
bool& popup_menus_on() {
  static bool on = false;
  return on;
}

bool HasPopupMenuCalls() {
  return fork_api().browser_set_popup_menu_handler && fork_api().browser_popup_menu_reply;
}

// Fork API 31 (task 171): a page opened a <select> popup. The Chromium Host
// is never the active app, so Chromium's NSMenu (content::PopupMenuHelper,
// popup_menu_helper_mac.mm) would track in the wrong process; cmux shows the
// menu, as Chrome's app shim does for its browser process (PopupMenuRunner,
// content/common/render_widget_host_ns_view.mojom).
void PopupMenuShow(void*, int browser_id, const ForkPopupMenu* menu) {
  if (!menu) return;
  if (!PopupMenuReadable(*menu)) {
    // A struct this shim cannot read: the popup closes with no choice, so
    // the page never waits for an answer.
    fork_api().browser_popup_menu_reply(browser_id, menu->token, -1);
    return;
  }
  Emit(CMUX_SHIM_POPUP_MENU, browser_id, 0, menu->token, 0, PopupMenuJson(*menu));
}

void PopupMenuHide(void*, int browser_id, int64_t token) {
  Emit(CMUX_SHIM_POPUP_MENU_HIDE, browser_id, 0, token);
}

// Sets or removes browser_id's popup handler in the fork, which hides an
// open popup of the handler it replaces through PopupMenuHide.
void SetPopupMenuHandler(int browser_id, bool on) {
  if (on) {
    fork_api().browser_set_popup_menu_handler(browser_id, &PopupMenuShow, &PopupMenuHide, nullptr);
  } else {
    fork_api().browser_set_popup_menu_handler(browser_id, nullptr, nullptr, nullptr);
  }
}

// The browsers whose frame renderers changed and the set each last reported (frame_renderers.h).
FrameRenderers& frame_renderers() {
  static FrameRenderers renderers;
  return renderers;
}

// The check NoteFrameRenderersChanged posts: after the task's frame changes, FRAME_RENDERERS when the
// browser's renderer set is new.
class CheckFrameRenderers : public CefTask {
 public:
  explicit CheckFrameRenderers(int browser_id) : browser_id_(browser_id) {}
  void Execute() override {
    CefRefPtr<CefBrowser> browser = BrowserById(browser_id_);
    if (!browser) {
      frame_renderers().Forget(browser_id_);  // it closed before the check ran
      return;
    }
    if (frame_renderers().Check(browser_id_, FrameRendererClientIDs(browser))) {
      Emit(CMUX_SHIM_FRAME_RENDERERS, browser_id_);
    }
  }

 private:
  int browser_id_;
  IMPLEMENT_REFCOUNTING(CheckFrameRenderers);
};

}  // namespace

namespace cmux_shim {

void NoteFrameRenderersChanged(int browser_id) {
  if (frame_renderers().Changed(browser_id)) CefPostTask(TID_UI, new CheckFrameRenderers(browser_id));
}

void ForgetFrameRenderers(int browser_id) {
  frame_renderers().Forget(browser_id);
}

void ApplyPopupMenus(int browser_id) {
  if (popup_menus_on() && HasPopupMenuCalls()) SetPopupMenuHandler(browser_id, true);
}

// Chromium asks to focus a page: after every navigation it starts (a new
// browser's first load, LoadURL), and inside cmux's own SetFocus and
// embedder-active calls. In process cmux's handler answers (CEFTab+Focus.swift:
// a page window that took focus would take the keys from the omnibar). The
// Chromium Host installs none: a page cmux marked embedder-active, one its
// window's first responder shows, may take focus, also after its own load;
// any other page (a background pane, a page not adopted yet) may not.
bool RefusesFocus(int browser_id, int source) {
  const Host& h = host();
  return h.embedder_focus.Refuses(h.focus_request, h.ctx, browser_id, source);
}

void NoteEmbedderActive(int browser_id, bool active) {
  host().embedder_focus.SetActive(browser_id, active);
}

}  // namespace cmux_shim

extern "C" {

int cmux_shim_create_window(int request, void* parent_view, int width, int height, const char* url,
                            const char* profile_cache_path) {
  return CreateWindowWith(request, parent_view, width, height, url, profile_cache_path, nullptr);
}

int cmux_shim_placeholder_supported(void) {
  return fork_api().tab_renderer_state ? 1 : 0;
}

int cmux_shim_create_placeholder_window(int request, void* parent_view, int width, int height,
                                        const char* profile_cache_path) {
  if (!cmux_shim_placeholder_supported()) {
    return 0;
  }
  // CMUX_EXTRA_INFO_NO_RENDERER (include/cef_cmux.h): honored with an empty URL only.
  CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
  extra_info->SetBool("cmux_no_renderer", true);
  return CreateWindowWith(request, parent_view, width, height, "", profile_cache_path, extra_info);
}

int cmux_shim_tab_add(int window_browser_id, const char* url, int index, int activate) {
  if (stopping()) return 0;
  return fork_api().tab_add ? fork_api().tab_add(window_browser_id, url ? url : "", index, activate) : 0;
}

int cmux_shim_tab_duplicate(int browser_id, int window_browser_id, int index) {
  if (stopping()) return 0;
  return fork_api().tab_duplicate ? fork_api().tab_duplicate(browser_id, window_browser_id, index) : 0;
}

int cmux_shim_tab_activate(int browser_id) {
  // The tab's Browser may not exist yet in OnAfterCreated: watch its side
  // panel once it is shown (the fork ignores a Browser it already watches).
  if (fork_api().side_panel_watch) fork_api().side_panel_watch(browser_id);
  return fork_api().tab_activate ? fork_api().tab_activate(browser_id) : 0;
}

int cmux_shim_tab_window_id(int browser_id) {
  return fork_api().tab_window_id ? fork_api().tab_window_id(browser_id) : 0;
}

void cmux_shim_load_url(int browser_id, const char* url) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) {
    browser->GetMainFrame()->LoadURL(url ? url : "");
  }
}

void cmux_shim_go_back(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) browser->GoBack();
}

void cmux_shim_go_forward(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) browser->GoForward();
}

void cmux_shim_reload(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) browser->Reload();
}

int cmux_shim_unresponsive_reply(int browser_id, int terminate) {
  CefRefPtr<CefUnresponsiveProcessCallback> callback = TakeUnresponsiveCallback(browser_id);
  if (!callback) {
    return 0;
  }
  if (terminate) {
    callback->Terminate();
  } else {
    callback->Wait();
  }
  return 1;
}

int cmux_shim_renderer_client_ids(int browser_id, int* out, int capacity) {
  if (!out || capacity <= 0) {
    return 0;
  }
  // Each frame's render process host id, once.
  int count = 0;
  for (const int id : FrameRendererClientIDs(BrowserById(browser_id))) {
    bool seen = false;
    for (int i = 0; i < count; ++i) {
      if (out[i] == id) {
        seen = true;
        break;
      }
    }
    if (!seen && count < capacity) out[count++] = id;
  }
  return count;
}

int cmux_shim_renderer_frames(int* browser_ids, int* client_ids, int* frame_counts, int capacity) {
  if (!browser_ids || !client_ids || !frame_counts || capacity < 0) {
    return 0;
  }
  // Every browser the shim holds: the clients' (tabs, popups, spares) and the DevTools front ends,
  // which are not in browsers() but run in renderers of their own.
  std::vector<std::pair<int, CefRefPtr<CefBrowser>>> all(browsers().begin(), browsers().end());
  for (const CefRefPtr<CefBrowser>& devtools : DevToolsBrowsers()) all.emplace_back(devtools->GetIdentifier(), devtools);
  int count = 0;
  for (const auto& [browser_id, browser] : all) {
    std::vector<std::pair<int, int>> renderers;  // client id, frames
    for (const int id : FrameRendererClientIDs(browser)) {
      size_t at = 0;
      while (at < renderers.size() && renderers[at].first != id) ++at;
      if (at < renderers.size()) {
        ++renderers[at].second;
      } else {
        renderers.emplace_back(id, 1);
      }
    }
    for (const auto& [client_id, frames] : renderers) {
      if (count < capacity) {
        browser_ids[count] = browser_id;
        client_ids[count] = client_id;
        frame_counts[count] = frames;
      }
      ++count;
    }
  }
  return count;
}

int cmux_shim_renderer_pid(int browser_id) {
  return fork_api().browser_renderer_pid ? fork_api().browser_renderer_pid(browser_id) : 0;
}

void cmux_shim_stop(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) browser->StopLoad();
}

void cmux_shim_set_focus(int browser_id, int focus) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->SetFocus(focus != 0);
}

void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn handler) {
  host().focus_request = handler;
}

void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn handler) {
  host().unhandled_key = handler;
}

void cmux_shim_set_zoom_level(int browser_id, double level) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->SetZoomLevel(level);
}

void cmux_shim_set_accessibility(int browser_id, int enabled) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id))
    host->SetAccessibilityState(enabled != 0 ? STATE_ENABLED : STATE_DISABLED);
}

int cmux_shim_browser_set_embedder_visibility(int browser_id, int visibility) {
  if (!fork_api().browser_set_embedder_visibility) return 0;
  return fork_api().browser_set_embedder_visibility(browser_id, visibility);
}

// The fork's call is Chromium's WasHidden / WasOccluded for the detached page
// window (its widget's Hide and ShowInactive, its NSWindow's occluded state);
// CefBrowserHost::WasHidden does nothing for a Chrome-style browser.
int cmux_shim_browser_set_page_visibility(int browser_id, int visibility) {
  if (visibility < CMUX_SHIM_PAGE_VISIBLE || visibility > CMUX_SHIM_PAGE_OCCLUDED) return 0;
  if (!fork_api().browser_set_page_visibility) return 0;
  return fork_api().browser_set_page_visibility(browser_id, visibility);
}

int cmux_shim_tab_set_visibility(int browser_id, int visibility, int capture) {
  if (!fork_api().tab_set_visibility) return 0;
  return fork_api().tab_set_visibility(browser_id, visibility, capture);
}

int cmux_shim_tab_page_push(int browser_id, const char* text) {
  if (!text || !fork_api().tab_page_push) return 0;
  return fork_api().tab_page_push(browser_id, text, strlen(text));
}

int cmux_shim_print(int browser_id) {
  CefRefPtr<CefBrowserHost> host = HostOf(browser_id);
  if (!host) return 0;
  host->Print();
  return 1;
}

void cmux_shim_find(int browser_id, int find_id, const char* text, int forward, int match_case, int find_next) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) {
    // Before Find, which starts the search: its results carry `find_id` (find_ids.h).
    cmux_shim::host().find_ids.Sent(browser_id, find_id);
    host->Find(text ? text : "", forward != 0, match_case != 0, find_next != 0);
  }
}

void cmux_shim_stop_finding(int browser_id, int clear_selection) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->StopFinding(clear_selection != 0);
}

void cmux_shim_close(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) {
    MarkHostClose(browser_id);
    // A Chrome-style close still runs beforeunload (TabStripModel): the host
    // close never asks, so a question already showing is answered Leave, and
    // one the page asks during the close too (OnBeforeUnloadDialog).
    AnswerBeforeUnload(browser_id, true);
    host->CloseBrowser(true);
  }
}

int cmux_shim_try_close(int browser_id) {
  CefRefPtr<CefBrowserHost> host = HostOf(browser_id);
  if (!host) return 1;
  // False: beforeunload runs first; the page may ask (BEFORE_UNLOAD_DIALOG)
  // and BEFORE_CLOSE follows only when the close goes on.
  if (!host->TryCloseBrowser()) return 0;
  // Closing now, without a question: the host's own close (DoClose).
  MarkHostClose(browser_id);
  return 1;
}

int cmux_shim_devtools_call(int browser_id, const char* method, const char* params_json) {
  CefRefPtr<CefBrowserHost> host = HostOf(browser_id);
  if (!host || !method) {
    return 0;
  }
  CefRefPtr<CefDictionaryValue> params;
  if (params_json && *params_json) {
    CefRefPtr<CefValue> value = CefParseJSON(params_json, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) {
      return 0;
    }
    params = value->GetDictionary();
  }
  // An explicit id below 2^30 (the raw-send range starts there).
  int id = NextInternalDevToolsId(browser_id);
  return id ? host->ExecuteDevToolsMethod(id, method, params) : 0;
}

char* cmux_shim_ext_actions(int browser_id, int icon_px) {
  return fork_api().ext_actions ? fork_api().ext_actions(browser_id, icon_px) : nullptr;
}

int cmux_shim_ext_action_run(int browser_id, const char* extension_id, int x, int width) {
  return fork_api().ext_action_run && extension_id ? fork_api().ext_action_run(browser_id, extension_id, x, width) : 0;
}

void cmux_shim_ext_action_hide_popup(int browser_id, const char* extension_id) {
  if (fork_api().ext_action_hide_popup && extension_id) fork_api().ext_action_hide_popup(browser_id, extension_id);
}

void cmux_shim_ext_action_context_menu(int browser_id, const char* extension_id, int screen_x, int screen_y) {
  if (fork_api().ext_action_context_menu && extension_id) {
    fork_api().ext_action_context_menu(browser_id, extension_id, screen_x, screen_y);
  }
}

char* cmux_shim_ext_list(int browser_id) {
  return fork_api().ext_list ? fork_api().ext_list(browser_id) : nullptr;
}

int cmux_shim_ext_set_enabled(int browser_id, const char* extension_id, int enabled) {
  return fork_api().ext_set_enabled && extension_id ? fork_api().ext_set_enabled(browser_id, extension_id, enabled) : 0;
}

int cmux_shim_ext_move_pinned(int browser_id, const char* extension_id, int index) {
  return fork_api().ext_move_pinned && extension_id ? fork_api().ext_move_pinned(browser_id, extension_id, index) : 0;
}

int cmux_shim_ext_reload(int browser_id, const char* extension_id) {
  return fork_api().ext_reload && extension_id ? fork_api().ext_reload(browser_id, extension_id) : 0;
}

int cmux_shim_ext_uninstall(int browser_id, const char* extension_id) {
  return fork_api().ext_uninstall && extension_id ? fork_api().ext_uninstall(browser_id, extension_id) : 0;
}

int cmux_shim_ext_set_pinned(int browser_id, const char* extension_id, int pinned) {
  return fork_api().ext_set_pinned && extension_id ? fork_api().ext_set_pinned(browser_id, extension_id, pinned) : 0;
}

int cmux_shim_ext_open_options(int browser_id, const char* extension_id) {
  return fork_api().ext_open_options && extension_id ? fork_api().ext_open_options(browser_id, extension_id) : 0;
}

int cmux_shim_ext_load_unpacked(int browser_id, const char* path) {
  return fork_api().ext_load_unpacked && path ? fork_api().ext_load_unpacked(browser_id, path) : 0;
}

int cmux_shim_ext_load_later_supported(void) {
  return fork_api().ext_load_command_line_async ? 1 : 0;
}

int cmux_shim_ext_load_command_line(const char* profile_cache_path, int reply, const char* path) {
  if (!fork_api().ext_load_command_line_async || !profile_cache_path || !*profile_cache_path ||
      IsOffTheRecordKey(profile_cache_path) || !path || !*path) {
    return 0;
  }
  // The fork finds the profile by its context's cache path: make the context first.
  if (!RequestContextFor(profile_cache_path)) return 0;
  // The reply id rides in the fork's context pointer; the fork answers once, from a posted task.
  return fork_api().ext_load_command_line_async(profile_cache_path, path, &BuiltInLoadAnswered,
                                                reinterpret_cast<void*>(static_cast<intptr_t>(reply)));
}

char* cmux_shim_ext_commands(int browser_id) {
  return fork_api().ext_commands ? fork_api().ext_commands(browser_id) : nullptr;
}

int cmux_shim_ext_command_run(int browser_id, const char* extension_id, const char* command) {
  return fork_api().ext_command_run && extension_id && command
             ? fork_api().ext_command_run(browser_id, extension_id, command)
             : 0;
}

int cmux_shim_tab_move_to_window(int browser_id, int window_browser_id, int index) {
  return fork_api().tab_move_to_window ? fork_api().tab_move_to_window(browser_id, window_browser_id, index) : 0;
}

void cmux_shim_context_menu_done(int token, int command_id, int event_flags) {
  if (CefRefPtr<CefRunContextMenuCallback> callback = TakeMenuCallback(token)) {
    if (command_id < 0) {
      callback->Cancel();
    } else {
      callback->Continue(command_id, static_cast<cef_event_flags_t>(event_flags));
    }
  }
}

char* cmux_shim_tab_navigation_state(int browser_id) {
  return fork_api().tab_navigation_state ? fork_api().tab_navigation_state(browser_id) : nullptr;
}

int cmux_shim_tab_restore_navigation(int browser_id, const char* state) {
  return fork_api().tab_restore_navigation && state ? fork_api().tab_restore_navigation(browser_id, state) : 0;
}

int cmux_shim_navigation_restore_supported(void) {
  return fork_api().tab_navigation_state && fork_api().tab_restore_navigation ? 1 : 0;
}

void cmux_shim_set_popup_menus(int enabled) {
  const bool on = enabled != 0;
  if (popup_menus_on() == on) return;
  popup_menus_on() = on;
  if (!HasPopupMenuCalls()) return;
  for (const auto& [browser_id, browser] : browsers()) SetPopupMenuHandler(browser_id, on);
  for (int browser_id : DevToolsBrowserIds()) SetPopupMenuHandler(browser_id, on);
}

void cmux_shim_browser_popup_menu_reply(int browser_id, int64_t token, int index) {
  if (!fork_api().browser_popup_menu_reply) return;
  // The fork refuses an item the page cannot take and keeps its popup open;
  // cmux's menu has closed, so the page's popup closes too.
  if (!fork_api().browser_popup_menu_reply(browser_id, token, index) && index != -1) {
    fork_api().browser_popup_menu_reply(browser_id, token, -1);
  }
}

void cmux_shim_free(char* s) {
  if (s && fork_api().free_string) fork_api().free_string(s);
}

}  // extern "C"

namespace {

// Collects the navigation entries in order (CEF calls the visitor
// synchronously on the UI thread).
class EntryCollector : public CefNavigationEntryVisitor {
 public:
  bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int index, int total) override {
    CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
    item->SetString("url", entry->GetDisplayURL());
    item->SetString("title", entry->GetTitle());
    entries->SetDictionary(entries->GetSize(), item);
    if (current) current_index = index;
    return true;
  }
  CefRefPtr<CefListValue> entries = CefListValue::Create();
  int current_index = -1;
  IMPLEMENT_REFCOUNTING(EntryCollector);
};

}  // namespace

char* cmux_shim_tab_navigation_entries(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return nullptr;
  CefRefPtr<EntryCollector> collector = new EntryCollector();
  browser->GetHost()->GetNavigationEntries(collector, false);
  CefRefPtr<CefDictionaryValue> root = CefDictionaryValue::Create();
  root->SetInt("current", collector->current_index);
  root->SetList("entries", collector->entries);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(root);
  return strdup(CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString().c_str());
}

int cmux_shim_tab_go_to_entry(int browser_id, int offset) {
  return fork_api().tab_go_to_offset ? fork_api().tab_go_to_offset(browser_id, offset) : 0;
}

int cmux_shim_browser_attach_view(int browser_id, void* parent_view) {
  if (!fork_api().browser_attach_view) return 0;
  return fork_api().browser_attach_view(browser_id, parent_view);
}
