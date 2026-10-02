// Internal state shared by the shim translation units.
#pragma once

#include <map>
#include <vector>
#include <string>

#include <set>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_unresponsive_process_callback.h"
#include "cmux_cef_shim.h"  // Sources/CmuxNextBrowser/CEF/Shim

namespace cmux_shim {

// Fork C API resolved with dlsym (include/cef_cmux.h in the artifact).
struct ForkApi {
  int version = 0;
  void (*free_string)(char*) = nullptr;
  void (*set_observer)(void (*)(void*, int, int, int, int), void*) = nullptr;
  int (*tab_add)(int, const char*, int, int) = nullptr;
  int (*tab_activate)(int) = nullptr;
  // API version 14: one history step to an entry (Back/Forward menus).
  int (*tab_go_to_offset)(int, int) = nullptr;
  // API version 15: saved passwords into a profile's password store
  // (entries laid out as cmux_shim_password_entry, which cef_cmux.h's
  // cmux_password_entry matches), and password filling per tab.
  int (*password_import)(const char*, const cmux_shim_password_entry*, int, void (*)(void*, int, int, int, int), void*) = nullptr;
  int (*tab_set_password_fill)(int, int) = nullptr;
  int (*tab_window_id)(int) = nullptr;
  char* (*ext_actions)(int, int) = nullptr;
  int (*ext_action_run)(int, const char*, int, int) = nullptr;
  void (*ext_action_hide_popup)(int, const char*) = nullptr;
  void (*ext_action_context_menu)(int, const char*, int, int) = nullptr;
  int (*window_count)() = nullptr;
  // API version 3.
  char* (*ext_list)(int) = nullptr;
  int (*ext_set_enabled)(int, const char*, int) = nullptr;
  int (*ext_uninstall)(int, const char*) = nullptr;
  int (*ext_reload)(int, const char*) = nullptr;  // API 5
  int (*ext_move_pinned)(int, const char*, int) = nullptr;  // API 6
  int (*ext_set_pinned)(int, const char*, int) = nullptr;
  int (*ext_open_options)(int, const char*) = nullptr;
  int (*ext_load_unpacked)(int, const char*) = nullptr;
  char* (*ext_commands)(int) = nullptr;
  int (*ext_command_run)(int, const char*, const char*) = nullptr;
  int (*tab_move_to_window)(int, int, int) = nullptr;
  // API version 8: Chromium never shows a window of its own.
  void (*set_window_request_handler)(int (*)(void*, const void*), void*) = nullptr;
  int (*foreign_browser_count)() = nullptr;
  // API version 7: navigation state (tab hibernation, session restore).
  char* (*tab_navigation_state)(int) = nullptr;
  int (*tab_restore_navigation)(int, const char*) = nullptr;
  // API version 12: page background, New Tab page, install prompts,
  // chrome.omnibox keyword sessions, native messaging fallback folders.
  int (*browser_set_background_color)(int, unsigned int) = nullptr;
  void (*set_new_tab_page_url)(const char*) = nullptr;
  void (*set_install_prompt_handler)(void (*)(void*, int, int, const char*), void*) = nullptr;
  int (*install_prompt_reply)(int, int) = nullptr;
  char* (*omnibox_keywords)(int) = nullptr;
  int (*omnibox_input)(int, const char*, int, const char*, int) = nullptr;
  void (*set_omnibox_suggestions_handler)(void (*)(void*, int, const char*, const char*), void*) = nullptr;
  int (*add_native_messaging_dir)(const char*, int) = nullptr;
  // API version 11: popup windows extensions create.
  void (*set_popup_windows_enabled)(int) = nullptr;
  int (*popup_window_bounds)(int, int*, int*, int*, int*) = nullptr;
  int (*popup_window_attach)(int, void*, int, int) = nullptr;
  // API version 13: the side panel header for the host.
  void (*side_panel_watch)(int) = nullptr;
  char* (*side_panel_state)(int) = nullptr;
  int (*side_panel_press)(int, const char*) = nullptr;
};

struct Host {
  void* ctx = nullptr;
  cmux_shim_schedule_fn schedule = nullptr;
  cmux_shim_event_fn event = nullptr;
  cmux_shim_key_fn key = nullptr;
  cmux_shim_key_fn devtools_key = nullptr;
  cmux_shim_window_request_fn window_request = nullptr;
  cmux_shim_focus_request_fn focus_request = nullptr;
};

ForkApi& fork_api();
void InstallForkObserver();
Host& host();

// Emits one event to Swift (main thread only).
void Emit(int kind,
          int browser_id,
          int request = 0,
          int64_t a = 0,
          int64_t b = 0,
          const std::string& s1 = std::string(),
          const std::string& s2 = std::string());

// Live browsers by identifier (UI thread only).
std::map<int, CefRefPtr<CefBrowser>>& browsers();
CefRefPtr<CefBrowser> BrowserById(int browser_id);

// Browsers the host asked to close (so DoClose can tell window.close apart).
void MarkHostClose(int browser_id);
bool TakeHostClose(int browser_id);

// Unanswered renderer hangs by browser (UI thread only). Storing replaces an
// older callback of the same browser; Take removes it.
void StoreUnresponsiveCallback(int browser_id, CefRefPtr<CefUnresponsiveProcessCallback> callback);
CefRefPtr<CefUnresponsiveProcessCallback> TakeUnresponsiveCallback(int browser_id);

// cmux_shim_set_background_color; 0 = Chromium's default.
cef_color_t BackgroundColor();
// A closed browser's own page background is forgotten.
void ForgetOwnBackground(int browser_id);
// Browsers with a page background of their own (not the theme color).
std::set<int>& own_background_browsers();

// Request contexts per profile cache path.
CefRefPtr<CefRequestContext> RequestContextFor(const std::string& cache_path);
// Keys with this prefix name an off-the-record (in-memory) context.
inline constexpr char kOffTheRecordPrefix[] = "cmux-otr:";
bool IsOffTheRecordKey(const std::string& key);
// Drops the shim's reference to the context of key (and its proxy entry).
void ReleaseRequestContext(const std::string& key);
void ForgetContextProxy(const std::string& key);
// The initialized context of cache_path this launch, or null.
CefRefPtr<CefRequestContext> ExistingRequestContext(const std::string& cache_path);

// Remote localhost (shim_proxy.mm). UI thread unless noted.
void ApplyContextProxy(CefRefPtr<CefRequestContext> context, const std::string& cache_path);
bool IsLoopbackHost(const std::string& host);
// True when a main-frame navigation of browser_id to url breaks its guard.
bool NavigationViolatesGuard(int browser_id, const std::string& url);
void ForgetNavigationGuard(int browser_id);

// One client per Chromium window. The first OnAfterCreated through it reports
// `request`; later tabs of the window (cmux_tab_add, chrome.tabs.create,
// target=_blank) report request 0.
CefRefPtr<CefClient> MakeClient(int request);
// Client for browsers Chromium creates in windows the host did not create
// (CefBrowserProcessHandler::GetDefaultClient).
CefRefPtr<CefClient> DefaultClient();

// Popups a page asked for (OnBeforePopup), waiting for their
// OnAfterCreated: the disposition and window features go with the new tab's
// AFTER_CREATED event (shim_windows.mm).
void RememberPopup(int opener, int disposition, const CefPopupFeatures& features);
// Returns opener << 32 | disposition for AFTER_CREATED's b, and the window
// features ("x,y,width,height" or ""). Takes the opener's oldest popup.
int64_t TakePopup(CefRefPtr<CefBrowser> browser, std::string* features);
void ForgetPopups(int opener);
// Chromium commands that would open a window of Chromium's own.
bool IsWindowCommand(int command_id);
// Binds the host's window request handler to the fork (API 8).
void InstallWindowRequestHandler();
// Binds the install prompt and omnibox suggestion handlers (API 12) and
// applies the New Tab page URL and native messaging folders stored before
// CefInitialize (shim_extensions_ui.mm).
void InstallExtensionUIHandlers();
// The visible entry's virtual URL when it is chrome://newtab (the New Tab
// page, which loads another URL), else `url`.
std::string DisplayAddress(CefRefPtr<CefBrowser> browser, const std::string& url);
// "" for the New Tab page's placeholder title (Chromium titles a page
// without <title> with its URL, "chrome://newtab" or "about:blank"), so the
// host shows its own "New Tab"; else `title`.
std::string DisplayTitle(CefRefPtr<CefBrowser> browser, const std::string& title);
// The request handler that adds the store's browser headers to requests to
// the Chrome Web Store's origin, or null for any other URL (shim_webstore.mm).
CefRefPtr<CefResourceRequestHandler> WebStoreRequestHandler(const std::string& url);
bool IsWebStoreURL(const std::string& url);

// Context menus the host is showing, by token (UI thread only).
int StoreMenuCallback(CefRefPtr<CefRunContextMenuCallback> callback);
CefRefPtr<CefRunContextMenuCallback> TakeMenuCallback(int token);
CefRefPtr<CefApp> MakeApp(std::vector<std::string> switches);

// OnBeforeDevToolsPopup of a page client: asks the host where DevTools of
// `inspected` goes and gives it a DevTools-only client (shim_devtools.mm).
void PrepareDevToolsPopup(int inspected, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                          bool* use_default_window);
// The page closed: drop its DevTools placement.
void ForgetDevTools(int inspected);

}  // namespace cmux_shim
