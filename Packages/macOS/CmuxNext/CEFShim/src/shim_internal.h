// Internal state shared by the shim translation units.
#pragma once

#include <functional>
#include <map>
#include <vector>
#include <string>

#include <set>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_jsdialog_handler.h"
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
  // API version 16: a user-owned copy of a tab (history, sessionStorage).
  int (*tab_duplicate)(int, int, int) = nullptr;
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
  // API version 17: see-through pages.
  int (*tab_set_transparent_background)(int, int) = nullptr;
  uint32_t (*browser_set_layer_hosting)(int, int) = nullptr;
  int (*browser_set_resize_sync)(int, int) = nullptr;
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
  // API version 24: DevTools device mode bounds.
  int (*devtools_inspected_bounds)(int, int*) = nullptr;
  // API version 13: the side panel header for the host.
  void (*side_panel_watch)(int) = nullptr;
  char* (*side_panel_state)(int) = nullptr;
  int (*side_panel_press)(int, const char*) = nullptr;
  // API version 18: profile (Touch ID) passkeys, metadata only.
  int (*profile_passkeys_list)(const char*, void (*)(void*, const char*), void*) = nullptr;
  int (*profile_passkey_delete)(const char*, const char*, void (*)(void*, int), void*) = nullptr;
  // API version 18: password manager core (shim_password_core.mm).
  int (*password_list)(const char*, void (*)(void*, const char*), void*) = nullptr;
  int (*password_remove)(const char*, const char* const*, int, void (*)(void*, int), void*) = nullptr;
  int (*password_exception_remove)(const char*, const char*, void (*)(void*, int), void*) = nullptr;
  int (*password_set_username)(const char*, const char*, const char*, void (*)(void*, int), void*) = nullptr;
  int (*password_reveal)(const char*, const char*, void (*)(void*, const char*, size_t), void*) = nullptr;
  int (*password_export)(const char*, const char*, void (*)(void*, int), void*) = nullptr;
  // API version 20: import with the conflicting rows' indices, and Replace
  // for them (the person's explicit choice; shim_password_import.mm).
  int (*password_import_v2)(const char*, const cmux_shim_password_entry*, int,
                            void (*)(void*, int, int, int, const int*, int), void*) = nullptr;
  int (*password_import_replace)(const char*, const cmux_shim_password_entry*, int, void (*)(void*, int, int, int),
                                 void*) = nullptr;
  // API version 20: save and update prompts go to the host (shim_password_core.mm).
  void (*set_password_prompt_handler)(void (*)(void*, const char*), void*) = nullptr;
  int (*password_prompt_answer)(int, int, const char*) = nullptr;
  int (*set_password_generation_enabled)(int) = nullptr;
  // API version 22: the chrome.bookmarks bridge (shim_bookmarks.mm).
  int (*bookmarks_observe)(const char*, void (*)(void*, const char*), void*) = nullptr;
  int (*bookmarks_sync)(const char*, const char*) = nullptr;
  // API version 30: the helper-app browser process (shim_helper_host.mm).
  int (*browser_set_detached_hosting)(int, int) = nullptr;
  int (*browser_set_embedder_active)(int, int) = nullptr;
  int (*post_user_input_task)(void (*)(void*), void*) = nullptr;
  int (*browser_send_wheel)(int, double, double, double, double, int, int, int, int) = nullptr;
  int (*browser_text_input_watch)(int, void (*)(void*, int, const void*), void*) = nullptr;
  int (*browser_accessibility_token)(int, int, const uint8_t*, int, const uint8_t*, int, uint8_t*, int) = nullptr;
  void (*set_drag_source_handler)(void (*)(void*, int, const void*), void*) = nullptr;
  int (*browser_drag_source_ended)(int, double, double, double, double, int) = nullptr;
  int (*browser_drag_target_enter_source)(int, int, int, int, int) = nullptr;
};

struct Host {
  void* ctx = nullptr;
  cmux_shim_schedule_fn schedule = nullptr;
  cmux_shim_event_fn event = nullptr;
  cmux_shim_key_fn key = nullptr;
  cmux_shim_key_fn devtools_key = nullptr;
  cmux_shim_key_fn unhandled_key = nullptr;
  cmux_shim_window_request_fn window_request = nullptr;
  cmux_shim_focus_request_fn focus_request = nullptr;
};

ForkApi& fork_api();
void InstallForkObserver();
Host& host();

// True once quit began to stop Chromium (cmux_shim_close_all): no browser is
// made after, as CEF aborts creating one once its shutdown began.
bool& stopping();

// Emits one event to Swift (main thread only).
void Emit(int kind,
          int browser_id,
          int request = 0,
          int64_t a = 0,
          int64_t b = 0,
          const std::string& s1 = std::string(),
          const std::string& s2 = std::string());

// The file chooser handler (shim_file_dialog.mm); CancelFileDialogs cancels
// the pending choosers of a browser that closed or crashed (UI thread).
CefRefPtr<CefDialogHandler> FileDialogHandlerInstance();
void CancelFileDialogs(int browser_id);
// A closed browser's per-browser chooser routing (shim_file_dialog.mm).
void ForgetFileDialogRoute(int browser_id);

// Live browsers by identifier (UI thread only).
std::map<int, CefRefPtr<CefBrowser>>& browsers();
CefRefPtr<CefBrowser> BrowserById(int browser_id);

// DevTools protocol traffic of the host (shim_devtools_protocol.mm, UI
// thread). The next id for a shim-internal call of browser_id (1 ..
// 2^30 - 1), or 0 when the browser used them all up.
int NextInternalDevToolsId(int browser_id);
// OnDevToolsMessage: forwards raw-send replies and watched events as
// CMUX_SHIM_DEVTOOLS_EVENT. True when the message is consumed (a raw-send
// reply), so it never reaches OnDevToolsMethodResult.
bool ForwardDevToolsMessage(int browser_id, const void* message, size_t message_size);
// The browser closed: drop its watch, raw-send mark and id counter.
void ForgetDevToolsProtocol(int browser_id);

// Profile preference watches (shim_prefs.mm, UI thread).
void ForgetPreferenceWatches(const std::string& key);
void ReleasePreferenceWatches();

// Bookmark watches (shim_bookmarks.mm, UI thread): one per initialized
// persistent profile, forwarded as CMUX_SHIM_BOOKMARKS_EVENT.
void WatchBookmarks(const std::string& key);
void ForgetBookmarkWatch(const std::string& key);
void ReleaseBookmarkWatches();

// cmux-page:// (shim_page_scheme.mm). Registers every page added so far on
// `context` (each profile keeps its own scheme handler factories).
void RegisterPageSchemes(CefRefPtr<CefRequestContext> context);
// Registers them on the global context once CEF is initialized.
void InstallPageSchemes();

// Browsers the host asked to close (so DoClose can tell window.close apart).
// A host close never asks: its beforeunload is answered Leave at once.
void MarkHostClose(int browser_id);
bool TakeHostClose(int browser_id);
bool IsHostClose(int browser_id);

// beforeunload questions the host answers (UI thread only; shim_process.mm).
// Store returns the token of BEFORE_UNLOAD_DIALOG; Answer continues every
// waiting question of the browser (accept = Leave) and Drop forgets them
// unanswered (Chromium ended them). Both return true when one was waiting.
int StoreBeforeUnloadCallback(int browser_id, CefRefPtr<CefJSDialogCallback> callback);
bool AnswerBeforeUnload(int browser_id, bool accept);
bool DropBeforeUnload(int browser_id);

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
// Every request context the shim holds (UI thread).
void ForEachRequestContext(const std::function<void(CefRefPtr<CefRequestContext>)>& body);
// The initialized context of cache_path this launch, or null.
CefRefPtr<CefRequestContext> ExistingRequestContext(const std::string& cache_path);

// Remote localhost (shim_proxy.mm). UI thread unless noted.
void ApplyContextProxy(CefRefPtr<CefRequestContext> context, const std::string& cache_path);
bool IsLoopbackHost(const std::string& host);
// True when a main-frame navigation of browser_id to url breaks its guard.
bool NavigationViolatesGuard(int browser_id, const std::string& url);
// True when browser_id is agent-driven (guard bit 4) and url is a Chromium
// page agents may not reach (AgentURLPolicy.swift).
bool NavigationRefusedForAgent(int browser_id, const std::string& url);
// True when browser_id is agent-driven (guard bit 4).
bool BrowserIsAgentDriven(int browser_id);
void ForgetNavigationGuard(int browser_id);
// True when url is the sign-in callback of browser_id (cmux_shim_set_auth_callback).
bool NavigationIsAuthCallback(int browser_id, const std::string& url);

// One client per Chromium window. The first OnAfterCreated through it reports
// `request`; later tabs of the window (cmux_tab_add, chrome.tabs.create,
// target=_blank) report request 0.
CefRefPtr<CefClient> MakeClient(int request);
// Client for browsers Chromium creates in windows the host did not create
// (CefBrowserProcessHandler::GetDefaultClient).
CefRefPtr<CefClient> DefaultClient();

// Popups a page asked for (OnBeforePopup), waiting for their
// OnAfterCreated: the target URL, disposition, gesture and window features go
// with the new tab's AFTER_CREATED event (shim_windows.mm, PendingPopups in
// download_state.h). A popup Chromium aborts drops out (AbortPopup); one
// older than PendingPopups::kLifetimeMs expires.
void RememberPopup(int opener, int popup_id, const std::string& url, int disposition, bool user_gesture,
                   const CefPopupFeatures& features);
void AbortPopup(int opener, int popup_id);
// Returns opener << 32 | user_gesture << 16 | disposition for AFTER_CREATED's
// b, the window features ("x,y,width,height" or "") and the target URL. Takes
// the opener's popup whose target URL is the new tab's visible URL, else its
// oldest live popup.
int64_t TakePopup(CefRefPtr<CefBrowser> browser, std::string* features, std::string* url);
void ForgetPopups(int opener);
// Chromium commands that would open a window of Chromium's own.
bool IsWindowCommand(int command_id);
// Binds the host's window request handler to the fork (API 8).
void InstallWindowRequestHandler();
// Binds the install prompt and omnibox suggestion handlers (API 12) and
// applies the New Tab page URL and native messaging folders stored before
// CefInitialize (shim_extensions_ui.mm).
void InstallExtensionUIHandlers();
// Sends Chromium's password save and update prompts to the host (API 20),
// so Chromium's bubble does not show (shim_password_core.mm).
void InstallPasswordPromptHandler();
void RemovePasswordPromptHandler();
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
// The Web Store's CRX download URL (https://clients2.google.com/service/
// update2/crx, any query): the URL Chromium's WebstoreInstaller downloads an
// extension package from (extension_urls::IsWebstoreUpdateUrl).
bool IsWebStoreCrxURL(const std::string& url);

// Downloads (shim_downloads.mm, UI thread). The page clients' download
// handler: every download waits for the host's path (DOWNLOAD_STARTED,
// cmux_shim_download_continue) and reports its progress and end.
CefRefPtr<CefDownloadHandler> DownloadHandler();
// Releases every waiting and running download callback (before CefShutdown).
void ForgetDownloads();

// Permission prompts (shim_permissions.mm, UI thread). The page clients'
// permission handler: location requests wait for the host's answer
// (PERMISSION_PROMPT, cmux_shim_permission_continue).
CefRefPtr<CefPermissionHandler> PermissionHandler();
// Releases every waiting prompt callback (before CefShutdown).
void ForgetPermissionPrompts();

// A Proceed the host asked for on a certificate warning
// (cmux_shim_certificate_proceed, shim_site.mm, UI thread): taken by the
// browser's next certificate error with that host and error code.
enum class CertificateProceed { kNone, kContinue, kChromium };
CertificateProceed TakeCertificateProceed(int browser_id, const std::string& host, int code);
// The browser's certificate error `code` and its answer: cancelled (the host
// shows its warning) or left to Chromium's interstitial.
void NoteCertificateError(int browser_id, int code, bool chromium_interstitial);
// The main-frame load error the host sees: Chromium may end a cancelled
// certificate request as ERR_ABORTED, which reports the certificate error
// instead; `chromium_interstitial` when Chromium shows its own page for it.
// Every main-frame load start or error ends the browser's pending
// certificate state (a Proceed covers only its own load).
int CertificateLoadError(int browser_id, int code, std::string* text, bool* chromium_interstitial);
void ForgetCertificateState(int browser_id);

// Context menus the host is showing, by token (UI thread only).
int StoreMenuCallback(CefRefPtr<CefRunContextMenuCallback> callback);
CefRefPtr<CefRunContextMenuCallback> TakeMenuCallback(int token);
CefRefPtr<CefApp> MakeApp(std::vector<std::string> switches);

// OnBeforeDevToolsPopup of a page client: asks the host where DevTools of
// `inspected` goes and gives it a DevTools-only client (shim_devtools.mm).
void PrepareDevToolsPopup(int inspected, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                          CefBrowserSettings& settings, bool* use_default_window);
// The page closed: drop its DevTools placement.
void ForgetDevTools(int inspected);

}  // namespace cmux_shim
