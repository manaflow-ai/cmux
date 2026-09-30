// Per-browser commands: window creation, fork tab API, navigation, find,
// zoom, DevTools methods, extension actions.

#import <AppKit/AppKit.h>

#include "include/cef_parser.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

CefRefPtr<CefBrowserHost> HostOf(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  return browser ? browser->GetHost() : nullptr;
}

}  // namespace

extern "C" {

int cmux_shim_create_window(int request, void* parent_view, int width, int height, const char* url,
                            const char* profile_cache_path) {
  if (!parent_view) {
    return 0;
  }
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)(__bridge NSView*)parent_view, CefRect(0, 0, width, height));
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  settings.background_color = BackgroundColor();
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path ? profile_cache_path : "");
  return CefBrowserHost::CreateBrowser(info, MakeClient(request), url ? url : "", settings, nullptr, context) ? 1 : 0;
}

int cmux_shim_tab_add(int window_browser_id, const char* url, int index, int activate) {
  return fork_api().tab_add ? fork_api().tab_add(window_browser_id, url ? url : "", index, activate) : 0;
}

int cmux_shim_tab_activate(int browser_id) {
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
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser || !out || capacity <= 0) {
    return 0;
  }
  // A frame identifier is "<render process host id>-<frame token>"
  // (frame_util::MakeFrameIdentifier); the host id is the renderer's
  // --renderer-client-id.
  std::vector<CefString> identifiers;
  browser->GetFrameIdentifiers(identifiers);
  int count = 0;
  for (const CefString& identifier : identifiers) {
    const std::string text = identifier.ToString();
    const size_t dash = text.find('-');
    if (dash == std::string::npos || dash == 0) continue;
    int id = 0;
    bool digits = true;
    for (size_t i = 0; i < dash; ++i) {
      if (text[i] < '0' || text[i] > '9' || id > 100000000) {
        digits = false;
        break;
      }
      id = id * 10 + (text[i] - '0');
    }
    if (!digits || id <= 0) continue;
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

void cmux_shim_stop(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserById(browser_id)) browser->StopLoad();
}

void cmux_shim_set_focus(int browser_id, int focus) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->SetFocus(focus != 0);
}

void cmux_shim_set_zoom_level(int browser_id, double level) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->SetZoomLevel(level);
}

void cmux_shim_find(int browser_id, int find_id, const char* text, int forward, int match_case, int find_next) {
  // CEF reports its own identifier in OnFindResult; this build ignores the
  // caller's, so Swift matches results by browser and the latest request.
  (void)find_id;
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) {
    host->Find(text ? text : "", forward != 0, match_case != 0, find_next != 0);
  }
}

void cmux_shim_stop_finding(int browser_id, int clear_selection) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) host->StopFinding(clear_selection != 0);
}

void cmux_shim_close(int browser_id) {
  if (CefRefPtr<CefBrowserHost> host = HostOf(browser_id)) {
    MarkHostClose(browser_id);
    host->CloseBrowser(true);
  }
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
  return host->ExecuteDevToolsMethod(0, method, params);
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

void cmux_shim_free(char* s) {
  if (s && fork_api().free_string) fork_api().free_string(s);
}

}  // extern "C"
