// Process level: library load, fork API, NSApp adoption, CefInitialize with
// the external message pump, shutdown.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <cstring>
#include <set>

#include "include/cef_application_mac.h"
#include "include/cef_parser.h"
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

bool& stopping() {
  static bool value = false;
  return value;
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

bool IsHostClose(int browser_id) {
  return host_closes().count(browser_id) > 0;
}

namespace {

struct BeforeUnloadQuestion {
  int browser_id;
  CefRefPtr<CefJSDialogCallback> callback;
};

std::map<int, BeforeUnloadQuestion>& before_unload_questions() {
  static std::map<int, BeforeUnloadQuestion> map;
  return map;
}

// Removes the browser's questions and returns their callbacks.
std::vector<CefRefPtr<CefJSDialogCallback>> TakeBeforeUnload(int browser_id) {
  std::vector<CefRefPtr<CefJSDialogCallback>> taken;
  auto& map = before_unload_questions();
  for (auto it = map.begin(); it != map.end();) {
    if (it->second.browser_id == browser_id) {
      taken.push_back(it->second.callback);
      it = map.erase(it);
    } else {
      ++it;
    }
  }
  return taken;
}

}  // namespace

int StoreBeforeUnloadCallback(int browser_id, CefRefPtr<CefJSDialogCallback> callback) {
  static int next = 1;
  int token = next++;
  before_unload_questions()[token] = {browser_id, callback};
  return token;
}

bool AnswerBeforeUnload(int browser_id, bool accept) {
  // Taken first: Continue can re-enter the dialog handler (OnResetDialogState).
  std::vector<CefRefPtr<CefJSDialogCallback>> callbacks = TakeBeforeUnload(browser_id);
  for (auto& callback : callbacks) callback->Continue(accept, CefString());
  return !callbacks.empty();
}

bool DropBeforeUnload(int browser_id) {
  return !TakeBeforeUnload(browser_id).empty();
}

static bool g_extension_developer_mode = false;
// accept_language_list from cmux_shim_initialize, for every request context.
static std::string g_accept_languages;
// browser.searchEngine as Chromium template URL data (JSON); empty keeps
// Chromium's own default search provider. Set by cmux_shim_set_default_search.
static std::string g_default_search_json;

namespace {

std::set<std::string>& initialized_contexts() {
  static std::set<std::string> set;
  return set;
}

// Makes g_default_search_json the profile's default search provider, or
// resets the preference to Chromium's own default when it is empty.
void ApplyDefaultSearch(CefRefPtr<CefRequestContext> context) {
  static const char kPref[] = "default_search_provider_data.template_url_data";
  if (!context || !context->CanSetPreference(kPref)) return;
  CefRefPtr<CefValue> value;  // null restores the default
  if (!g_default_search_json.empty()) {
    value = CefParseJSON(g_default_search_json, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return;
  }
  CefString error;
  context->SetPreference(kPref, value, error);
}

// Turns off Chromium's download bubble that opens by itself when a download
// ends ("partial view"; download_bubble_ui_controller.cc returns no rows for
// it while this preference is false, and the bubble then never shows). It
// anchors to a toolbar cmux never shows, so it opened over the page; the
// App's Downloads popup opens under its own toolbar button instead
// (BrowserDownloadsPopup). The full bubble opens only from Chromium's
// toolbar button, which cmux has none of.
void DisableDownloadBubble(CefRefPtr<CefRequestContext> context) {
  static const char kPref[] = "download_bubble.partial_view_enabled";
  if (!context || !context->CanSetPreference(kPref)) return;
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetBool(false);
  CefString error;
  context->SetPreference(kPref, value, error);
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
    ApplyDefaultSearch(context);
    DisableDownloadBubble(context);
    initialized_contexts().insert(cache_path_);
    WatchBookmarks(cache_path_);
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
  // owns tabs; session cookies end when the app quits.
  settings.persist_session_cookies = false;
  // Each profile is its own request context with its own default list.
  if (!g_accept_languages.empty()) {
    CefString(&settings.accept_language_list) = g_accept_languages;
  }
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, new ContextHandler(cache_path));
  contexts[cache_path] = context;
  // cmux-page:// pages added so far (each profile has its own factories).
  RegisterPageSchemes(context);
  return context;
}

void ReleaseRequestContext(const std::string& key) {
  ForgetPreferenceWatches(key);
  ForgetBookmarkWatch(key);
  request_contexts().erase(key);
  initialized_contexts().erase(key);
  ForgetContextProxy(key);
}

void ForEachRequestContext(const std::function<void(CefRefPtr<CefRequestContext>)>& body) {
  for (auto& [key, context] : request_contexts()) body(context);
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
  CMUX_BIND(tab_go_to_offset, "cmux_tab_go_to_offset");
  CMUX_BIND(password_import, "cmux_password_import");
  CMUX_BIND(tab_set_password_fill, "cmux_tab_set_password_fill");
  CMUX_BIND(tab_duplicate, "cmux_tab_duplicate");
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
  CMUX_BIND(tab_set_transparent_background, "cmux_tab_set_transparent_background");
  CMUX_BIND(browser_set_layer_hosting, "cmux_browser_set_layer_hosting");
  CMUX_BIND(browser_set_resize_sync, "cmux_browser_set_resize_sync");
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
  CMUX_BIND(devtools_inspected_bounds, "cmux_devtools_inspected_bounds");
  CMUX_BIND(side_panel_watch, "cmux_side_panel_watch");
  CMUX_BIND(side_panel_state, "cmux_side_panel_state");
  CMUX_BIND(side_panel_press, "cmux_side_panel_press");
  CMUX_BIND(profile_passkeys_list, "cmux_profile_passkeys_list");
  CMUX_BIND(profile_passkey_delete, "cmux_profile_passkey_delete");
  CMUX_BIND(password_list, "cmux_password_list");
  CMUX_BIND(password_remove, "cmux_password_remove");
  CMUX_BIND(password_exception_remove, "cmux_password_exception_remove");
  CMUX_BIND(password_set_username, "cmux_password_set_username");
  CMUX_BIND(password_reveal, "cmux_password_reveal");
  CMUX_BIND(password_export, "cmux_password_export");
  CMUX_BIND(password_import_v2, "cmux_password_import_v2");
  CMUX_BIND(password_import_replace, "cmux_password_import_replace");
  CMUX_BIND(set_password_prompt_handler, "cmux_set_password_prompt_handler");
  CMUX_BIND(password_prompt_answer, "cmux_password_prompt_answer");
  CMUX_BIND(set_password_generation_enabled, "cmux_set_password_generation_enabled");
  CMUX_BIND(bookmarks_observe, "cmux_bookmarks_observe");
  CMUX_BIND(bookmarks_sync, "cmux_bookmarks_sync");
  CMUX_BIND(browser_set_detached_hosting, "cmux_browser_set_detached_hosting");
  CMUX_BIND(browser_set_embedder_active, "cmux_browser_set_embedder_active");
  CMUX_BIND(post_user_input_task, "cmux_post_user_input_task");
  CMUX_BIND(browser_send_wheel, "cmux_browser_send_wheel");
  CMUX_BIND(browser_text_input_watch, "cmux_browser_text_input_watch");
  CMUX_BIND(browser_accessibility_token, "cmux_browser_accessibility_token");
  CMUX_BIND(set_drag_source_handler, "cmux_set_drag_source_handler");
  CMUX_BIND(browser_drag_source_ended, "cmux_browser_drag_source_ended");
  CMUX_BIND(browser_drag_target_enter_source, "cmux_browser_drag_target_enter_source");
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

void cmux_shim_set_default_search(const char* template_url_json) {
  g_default_search_json = template_url_json ? template_url_json : "";
  for (const auto& entry : request_contexts()) {
    if (initialized_contexts().count(entry.first)) ApplyDefaultSearch(entry.second);
  }
}

// Read once by cmux_shim_initialize (CefSettings.chrome_policy_id).
static std::string g_chrome_policy_id;

void cmux_shim_set_chrome_policy_id(const char* policy_id) {
  g_chrome_policy_id = policy_id ? policy_id : "";
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

// Chromium's page window (NativeWidgetMacNSWindow) re-encodes its restorable state after every
// key, order or frame change (invalidateRestorableState -> saveRestorableState ->
// reallySaveRestorableState -> -encodeRestorableStateWithCoder:), for Chrome's own session restore
// (OnWindowStateRestorationDataChanged). Each encode asks the WindowServer for the window's Space
// name, a synchronous round trip on the main thread; in cmux it ran after every pane focus move
// across Chromium panes (a515). CEF never restores these windows and cmux restores its own, so the
// encode becomes a no-op. A CEF without that private method keeps its behavior.
static void StopChromiumWindowRestorationData() {
  Class window_class = NSClassFromString(@"NativeWidgetMacNSWindow");
  SEL selector = NSSelectorFromString(@"reallySaveRestorableState");
  Method method = window_class ? class_getInstanceMethod(window_class, selector) : nullptr;
  if (!method) {
    return;
  }
  IMP no_op = imp_implementationWithBlock(^(id) {
  });
  class_replaceMethod(window_class, selector, no_op, method_getTypeEncoding(method));
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
  if (!g_chrome_policy_id.empty()) {
    CefString(&settings.chrome_policy_id) = g_chrome_policy_id;
  }
  settings.background_color = BackgroundColor();
  g_accept_languages = accept_languages ? accept_languages : "";
  if (!g_accept_languages.empty()) {
    CefString(&settings.accept_language_list) = g_accept_languages;
  }

  std::vector<std::string> switches;
  for (const char* const* it = switch_list; it && *it; ++it) {
    switches.emplace_back(*it);
  }
  CefMainArgs args(0, nullptr);
  if (!CefInitialize(args, settings, MakeApp(std::move(switches)), nullptr)) {
    return 0;
  }
  StopChromiumWindowRestorationData();
  return 1;
}

void cmux_shim_do_work(void) {
  CefDoMessageLoopWork();
}

void cmux_shim_close_all(void) {
  stopping() = true;
  // Copy: CloseBrowser can re-enter OnBeforeClose synchronously.
  auto all = browsers();
  for (auto& [id, browser] : all) {
    MarkHostClose(id);
    // Quit never asks: a question already showing is answered Leave.
    AnswerBeforeUnload(id, true);
    browser->GetHost()->CloseBrowser(true);
  }
}

int cmux_shim_before_unload_reply(int token, int accept) {
  auto& map = before_unload_questions();
  auto it = map.find(token);
  if (it == map.end()) return 0;
  CefRefPtr<CefJSDialogCallback> callback = it->second.callback;
  map.erase(it);
  callback->Continue(accept != 0, CefString());
  return 1;
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
  RemovePasswordPromptHandler();
  host() = Host();
  // Preference observer registrations go before their contexts.
  ReleasePreferenceWatches();
  ReleaseBookmarkWatches();
  request_contexts().clear();
  // Download callbacks hold Chromium objects: release them first.
  ForgetDownloads();
  ForgetPermissionPrompts();
  CefShutdown();
}

}  // extern "C"
