// Process level: library load, fork API, NSApp adoption, CefInitialize with
// the external message pump, shutdown.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <cstring>
#include <set>

#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "shim_internal.h"

namespace cmux_shim {

ForkApi& fork_api() {
  static ForkApi api;
  return api;
}

Host& host() {
  static Host h;
  return h;
}

void Emit(int kind, int browser_id, int request, int64_t a, int64_t b,
          const std::string& s1, const std::string& s2) {
  Host& h = host();
  if (!h.event) {
    return;
  }
  h.event(h.ctx, kind, browser_id, request, a, b, s1.c_str(), s2.c_str());
}

std::map<int, CefRefPtr<CefBrowser>>& browsers() {
  static std::map<int, CefRefPtr<CefBrowser>> map;
  return map;
}

CefRefPtr<CefBrowser> BrowserById(int browser_id) {
  auto& map = browsers();
  auto it = map.find(browser_id);
  return it == map.end() ? nullptr : it->second;
}

static std::set<int>& host_closes() {
  static std::set<int> set;
  return set;
}

void MarkHostClose(int browser_id) {
  host_closes().insert(browser_id);
}

bool TakeHostClose(int browser_id) {
  return host_closes().erase(browser_id) > 0;
}

static bool g_extension_developer_mode = false;
static cef_color_t g_background_color = 0;

cef_color_t BackgroundColor() {
  return g_background_color;
}
// accept_language_list from cmux_shim_initialize, for every request context.
static std::string g_accept_languages;

namespace {

std::set<std::string>& initialized_contexts() {
  static std::set<std::string> set;
  return set;
}

// Applies per-profile preferences once the profile is loaded.
class ContextHandler : public CefRequestContextHandler {
 public:
  explicit ContextHandler(std::string cache_path) : cache_path_(std::move(cache_path)) {}

  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    if (g_extension_developer_mode) {
      CefRefPtr<CefValue> value = CefValue::Create();
      value->SetBool(true);
      CefString error;
      context->SetPreference("extensions.ui.developer_mode", value, error);
    }
    // Remote localhost: before any browser of this context navigates.
    ApplyContextProxy(context, cache_path_);
    initialized_contexts().insert(cache_path_);
  }

 private:
  std::string cache_path_;
  IMPLEMENT_REFCOUNTING(ContextHandler);
};

}  // namespace

static std::map<std::string, CefRefPtr<CefRequestContext>>& request_contexts() {
  static std::map<std::string, CefRefPtr<CefRequestContext>> map;
  return map;
}

bool IsOffTheRecordKey(const std::string& key) {
  return key.rfind(kOffTheRecordPrefix, 0) == 0;
}

CefRefPtr<CefRequestContext> RequestContextFor(const std::string& cache_path) {
  auto& contexts = request_contexts();
  if (cache_path.empty()) {
    return nullptr;
  }
  auto it = contexts.find(cache_path);
  if (it != contexts.end()) {
    return it->second;
  }
  CefRequestContextSettings settings;
  // An off-the-record key (an incognito window's store) gets an empty cache
  // path: Chrome style then makes a new, unique in-memory profile for this
  // context, which Chromium destroys once the context and its browsers are
  // gone (cmux_shim_release_context). Nothing of it is written to disk.
  if (!IsOffTheRecordKey(cache_path)) {
    CefString(&settings.cache_path) = cache_path;
  }
  // Not persisted: in Chrome style this flag also sets the profile's
  // "restore on startup" to the last session, and with tabbed windows
  // Chromium then restores old tabs into the first new window. The daemon
  // owns tabs; session cookies end with the app, as in Chrome's default.
  settings.persist_session_cookies = false;
  // Each profile is its own request context with its own default list.
  if (!g_accept_languages.empty()) {
    CefString(&settings.accept_language_list) = g_accept_languages;
  }
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, new ContextHandler(cache_path));
  contexts[cache_path] = context;
  return context;
}

void ReleaseRequestContext(const std::string& key) {
  request_contexts().erase(key);
  initialized_contexts().erase(key);
  ForgetContextProxy(key);
}

CefRefPtr<CefRequestContext> ExistingRequestContext(const std::string& cache_path) {
  if (!initialized_contexts().count(cache_path)) return nullptr;
  auto& contexts = request_contexts();
  auto it = contexts.find(cache_path);
  return it == contexts.end() ? nullptr : it->second;
}

static void ForkObserver(void*, int event, int window_id, int browser_id, int a) {
  Emit(CMUX_SHIM_TAB_EVENT, browser_id, event, window_id, a);
}

void InstallForkObserver() {
  // UI thread only, so it runs from OnContextInitialized.
  if (fork_api().set_observer) {
    fork_api().set_observer(ForkObserver, nullptr);
  }
}

static void BindForkApi(const char* framework_binary) {
  // The wrapper opens the framework RTLD_LOCAL, so the fork exports are not
  // visible through RTLD_DEFAULT. Reopen the same image by path.
  void* image = dlopen(framework_binary, RTLD_NOLOAD | RTLD_LAZY);
  if (!image) {
    return;
  }
  auto version = reinterpret_cast<int (*)()>(dlsym(image, "cmux_cef_api_version"));
  if (!version) {
    return;
  }
  ForkApi& api = fork_api();
  api.version = version();
#define CMUX_BIND(field, name) api.field = reinterpret_cast<decltype(api.field)>(dlsym(image, name))
  CMUX_BIND(free_string, "cmux_cef_free");
  CMUX_BIND(set_observer, "cmux_tab_set_observer");
  CMUX_BIND(tab_add, "cmux_tab_add");
  CMUX_BIND(tab_activate, "cmux_tab_activate");
  CMUX_BIND(tab_window_id, "cmux_tab_window_id");
  CMUX_BIND(ext_actions, "cmux_ext_actions");
  CMUX_BIND(ext_action_run, "cmux_ext_action_run");
  CMUX_BIND(ext_action_hide_popup, "cmux_ext_action_hide_popup");
  CMUX_BIND(ext_action_context_menu, "cmux_ext_action_context_menu");
  CMUX_BIND(window_count, "cmux_browser_window_count");
  CMUX_BIND(ext_list, "cmux_ext_list");
  CMUX_BIND(ext_set_enabled, "cmux_ext_set_enabled");
  CMUX_BIND(ext_uninstall, "cmux_ext_uninstall");
  CMUX_BIND(ext_reload, "cmux_ext_reload");
  CMUX_BIND(ext_move_pinned, "cmux_ext_move_pinned");
  CMUX_BIND(ext_set_pinned, "cmux_ext_set_pinned");
  CMUX_BIND(ext_open_options, "cmux_ext_open_options");
  CMUX_BIND(ext_load_unpacked, "cmux_ext_load_unpacked");
  CMUX_BIND(ext_commands, "cmux_ext_commands");
  CMUX_BIND(ext_command_run, "cmux_ext_command_run");
  CMUX_BIND(tab_move_to_window, "cmux_tab_move_to_window");
  CMUX_BIND(set_window_request_handler, "cmux_set_window_request_handler");
  CMUX_BIND(foreign_browser_count, "cmux_foreign_browser_count");
  CMUX_BIND(tab_navigation_state, "cmux_tab_navigation_state");
  CMUX_BIND(tab_restore_navigation, "cmux_tab_restore_navigation");
  CMUX_BIND(browser_set_background_color, "cmux_browser_set_background_color");
  CMUX_BIND(set_new_tab_page_url, "cmux_set_new_tab_page_url");
  CMUX_BIND(set_install_prompt_handler, "cmux_set_install_prompt_handler");
  CMUX_BIND(install_prompt_reply, "cmux_install_prompt_reply");
  CMUX_BIND(omnibox_keywords, "cmux_omnibox_keywords");
  CMUX_BIND(omnibox_input, "cmux_omnibox_input");
  CMUX_BIND(set_omnibox_suggestions_handler, "cmux_set_omnibox_suggestions_handler");
  CMUX_BIND(add_native_messaging_dir, "cmux_add_native_messaging_dir");
  CMUX_BIND(set_popup_windows_enabled, "cmux_set_popup_windows_enabled");
  CMUX_BIND(popup_window_bounds, "cmux_popup_window_bounds");
  CMUX_BIND(popup_window_attach, "cmux_popup_window_attach");
#undef CMUX_BIND
}

// MARK: - NSApp check

// Chromium requires NSApp to implement CefAppProtocol before CefInitialize.
// The app's NSApplication subclass (CmuxApplication) conforms statically and
// maintains the sendEvent flag itself; the shim only checks.

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

#ifndef CMUX_CEF_SHIM_ABI_ID
#error "build-cef-shim.sh defines CMUX_CEF_SHIM_ABI_ID (SHA-256 of cmux_cef_shim.h)"
#endif

const char* cmux_shim_abi_id(void) {
  return CMUX_CEF_SHIM_ABI_ID;
}

int cmux_shim_load(const char* framework_binary, char* err, size_t err_len) {
  static bool loaded = false;
  if (loaded) {
    return 1;
  }
  if (!cef_load_library(framework_binary)) {
    if (err && err_len) {
      snprintf(err, err_len, "cef_load_library failed: %s", dlerror() ?: "unknown");
    }
    return 0;
  }
  loaded = true;
  BindForkApi(framework_binary);
  return 1;
}

void cmux_shim_set_extension_developer_mode(int enabled) {
  g_extension_developer_mode = enabled != 0;
}

void cmux_shim_set_background_color(unsigned int argb) {
  const bool changed = g_background_color != static_cast<cef_color_t>(argb);
  g_background_color = static_cast<cef_color_t>(argb);
  // Fork API 12: live tabs follow a theme change too.
  if (changed && argb && fork_api().browser_set_background_color) {
    for (auto& [id, browser] : browsers()) {
      fork_api().browser_set_background_color(id, argb);
    }
  }
}

int cmux_shim_fork_api_version(void) {
  return fork_api().version;
}

int cmux_shim_prepare_application(void) {
  NSApplication* app = [NSApplication sharedApplication];
  return [app conformsToProtocol:@protocol(CefAppProtocol)] &&
                 [app respondsToSelector:@selector(isHandlingSendEvent)] &&
                 [app respondsToSelector:@selector(setHandlingSendEvent:)]
             ? 1
             : 0;
}

int cmux_shim_initialize(const char* framework_dir, const char* main_bundle_path, const char* subprocess_path,
                         const char* root_cache_path, const char* log_file, int log_severity,
                         const char* locale, const char* accept_languages,
                         const char* const* switch_list, void* ctx, cmux_shim_schedule_fn schedule,
                         cmux_shim_event_fn event, cmux_shim_key_fn key) {
  Host& h = host();
  h.ctx = ctx;
  h.schedule = schedule;
  h.event = event;
  h.key = key;

  CefSettings settings;
  settings.external_message_pump = true;
  settings.no_sandbox = false;  // helpers enter the sandbox themselves
  settings.persist_session_cookies = false;  // see RequestContextFor
  if (log_severity) {
    settings.log_severity = static_cast<cef_log_severity_t>(log_severity);
  }
  CefString(&settings.framework_dir_path) = framework_dir ?: "";
  CefString(&settings.main_bundle_path) = main_bundle_path ?: "";
  CefString(&settings.browser_subprocess_path) = subprocess_path ?: "";
  CefString(&settings.root_cache_path) = root_cache_path ?: "";
  if (log_file) {
    CefString(&settings.log_file) = log_file;
  }
  if (locale && *locale) {
    CefString(&settings.locale) = locale;
  }
  settings.background_color = g_background_color;
  g_accept_languages = accept_languages ? accept_languages : "";
  if (!g_accept_languages.empty()) {
    CefString(&settings.accept_language_list) = g_accept_languages;
  }

  std::vector<std::string> switches;
  for (const char* const* it = switch_list; it && *it; ++it) {
    switches.emplace_back(*it);
  }
  CefMainArgs args(0, nullptr);
  return CefInitialize(args, settings, MakeApp(std::move(switches)), nullptr) ? 1 : 0;
}

void cmux_shim_do_work(void) {
  CefDoMessageLoopWork();
}

void cmux_shim_close_all(void) {
  // Copy: CloseBrowser can re-enter OnBeforeClose synchronously.
  auto all = browsers();
  for (auto& [id, browser] : all) {
    MarkHostClose(id);
    browser->GetHost()->CloseBrowser(true);
  }
}

int cmux_shim_live_browser_count(void) {
  return static_cast<int>(browsers().size());
}

int cmux_shim_window_count(void) {
  return fork_api().window_count ? fork_api().window_count() : -1;
}

void cmux_shim_shutdown(void) {
  if (fork_api().set_observer) {
    fork_api().set_observer(nullptr, nullptr);
  }
  if (fork_api().set_window_request_handler) {
    fork_api().set_window_request_handler(nullptr, nullptr);
  }
  if (fork_api().set_install_prompt_handler) {
    fork_api().set_install_prompt_handler(nullptr, nullptr);
  }
  if (fork_api().set_omnibox_suggestions_handler) {
    fork_api().set_omnibox_suggestions_handler(nullptr, nullptr);
  }
  host() = Host();
  request_contexts().clear();
  CefShutdown();
}

}  // extern "C"
