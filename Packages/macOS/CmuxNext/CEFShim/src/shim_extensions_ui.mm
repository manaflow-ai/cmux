// Extension UI that the host draws (fork API 12): install and permission
// prompts, chrome.omnibox keyword sessions, the New Tab page URL and the
// native messaging folders Chromium also searches.

#include <mutex>
#include <utility>

#include "include/cef_navigation_entry.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Stored until CefInitialize has bound the fork (the host may call the
// setters first).
struct PendingSettings {
  std::mutex lock;
  bool has_new_tab_url = false;
  std::string new_tab_url;
  std::vector<std::pair<std::string, int>> native_messaging_dirs;
  bool installed = false;
};

PendingSettings& pending() {
  static PendingSettings settings;
  return settings;
}

void InstallPromptTrampoline(void*, int prompt_id, int browser_id, const char* json) {
  Emit(CMUX_SHIM_INSTALL_PROMPT, browser_id, prompt_id, 0, 0, json ? json : "{}");
}

void OmniboxSuggestionsTrampoline(void*, int request_id, const char* extension_id, const char* json) {
  Emit(CMUX_SHIM_OMNIBOX_SUGGESTIONS, 0, request_id, 0, 0, extension_id ? extension_id : "",
       json ? json : "[]");
}

}  // namespace

void InstallExtensionUIHandlers() {
  ForkApi& api = fork_api();
  if (api.set_install_prompt_handler) {
    api.set_install_prompt_handler(InstallPromptTrampoline, nullptr);
  }
  if (api.set_omnibox_suggestions_handler) {
    api.set_omnibox_suggestions_handler(OmniboxSuggestionsTrampoline, nullptr);
  }
  PendingSettings& settings = pending();
  std::lock_guard<std::mutex> guard(settings.lock);
  settings.installed = true;
  if (settings.has_new_tab_url && api.set_new_tab_page_url) {
    api.set_new_tab_page_url(settings.new_tab_url.c_str());
  }
  if (api.add_native_messaging_dir) {
    for (const auto& [path, user_level] : settings.native_messaging_dirs) {
      api.add_native_messaging_dir(path.c_str(), user_level);
    }
  }
}

std::string DisplayAddress(CefRefPtr<CefBrowser> browser, const std::string& url) {
  CefRefPtr<CefNavigationEntry> entry = browser->GetHost()->GetVisibleNavigationEntry();
  if (!entry) {
    return url;
  }
  const std::string display = entry->GetDisplayURL().ToString();
  if (display == "chrome://newtab/" || display == "chrome://newtab") {
    return "chrome://newtab/";
  }
  return url;
}

std::string DisplayTitle(CefRefPtr<CefBrowser> browser, const std::string& title) {
  if (DisplayAddress(browser, "") != "chrome://newtab/") {
    return title;
  }
  if (title.empty() || title.rfind("chrome://newtab", 0) == 0 || title.rfind("about:blank", 0) == 0) {
    return std::string();
  }
  return title;
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_new_tab_page_url(const char* url) {
  PendingSettings& settings = pending();
  std::lock_guard<std::mutex> guard(settings.lock);
  settings.has_new_tab_url = true;
  settings.new_tab_url = url ? url : "";
  if (settings.installed && fork_api().set_new_tab_page_url) {
    fork_api().set_new_tab_page_url(settings.new_tab_url.c_str());
  }
}

int cmux_shim_add_native_messaging_dir(const char* path, int user_level) {
  if (!path || !*path) {
    return 0;
  }
  PendingSettings& settings = pending();
  std::lock_guard<std::mutex> guard(settings.lock);
  settings.native_messaging_dirs.emplace_back(path, user_level);
  if (settings.installed) {
    return fork_api().add_native_messaging_dir ? fork_api().add_native_messaging_dir(path, user_level) : 0;
  }
  return 1;
}

void cmux_shim_set_popup_windows_enabled(int enabled) {
  if (fork_api().set_popup_windows_enabled) {
    fork_api().set_popup_windows_enabled(enabled);
  }
}

int cmux_shim_popup_window_bounds(int window_id, int* x, int* y, int* width, int* height) {
  return fork_api().popup_window_bounds ? fork_api().popup_window_bounds(window_id, x, y, width, height) : 0;
}

int cmux_shim_popup_window_attach(int window_id, void* parent_view, int width, int height) {
  return fork_api().popup_window_attach && parent_view
             ? fork_api().popup_window_attach(window_id, parent_view, width, height)
             : 0;
}

char* cmux_shim_side_panel_state(int browser_id) {
  return fork_api().side_panel_state ? fork_api().side_panel_state(browser_id) : nullptr;
}

int cmux_shim_side_panel_press(int browser_id, const char* control) {
  return fork_api().side_panel_press && control ? fork_api().side_panel_press(browser_id, control) : 0;
}

int cmux_shim_install_prompt_reply(int prompt_id, int result) {
  return fork_api().install_prompt_reply ? fork_api().install_prompt_reply(prompt_id, result) : 0;
}

char* cmux_shim_omnibox_keywords(int browser_id) {
  return fork_api().omnibox_keywords ? fork_api().omnibox_keywords(browser_id) : nullptr;
}

int cmux_shim_omnibox_input(int browser_id, const char* extension_id, int event, const char* text, int value) {
  if (!fork_api().omnibox_input || !extension_id) {
    return 0;
  }
  return fork_api().omnibox_input(browser_id, extension_id, event, text ? text : "", value);
}

}  // extern "C"
