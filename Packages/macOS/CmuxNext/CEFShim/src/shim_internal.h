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
#include "embedder_focus_policy.h"
#include "embedder_ui_args.h"
#include "find_ids.h"
#include "popup_menu_args.h"
#include "suggestion_rows.h"

namespace cmux_shim {

// One underline of an IME composition as the fork reads it: its
// cmux_ime_span_t (include/cef_cmux.h, Chrome's ExtractUnderlines): [start,
// end) in the composition text in UTF-16 units, thick 1 for the selected
// clause, colors 0xAARRGGBB (0: the page's text color).
struct ForkImeSpan {
  int start;
  int end;
  int thick;
  uint32_t underline_color;
  uint32_t background_color;
};

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
  int (*ext_load_command_line_async)(const char*, const char*, void (*)(void*, int), void*) = nullptr;
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
  // API version 32: the resize fence in display frames.
  int (*browser_set_resize_fence)(int, uint32_t, uint32_t) = nullptr;
  // API version 34: a hosted page's visibility from the app.
  int (*browser_set_embedder_visibility)(int, int) = nullptr;
  // API version 36: a tab's Chromium views in an embedder NSView.
  int (*browser_attach_view)(int, void*) = nullptr;
  // API version 37: a tab's visibility and capture from the app.
  int (*tab_set_visibility)(int, int, int) = nullptr;
  // API version 43 (the fork train p13-webui-086's number for p13-webui-079): a
  // string to a cmux-page document's receiver (the page push channel).
  int (*tab_page_push)(int, const char*, size_t) = nullptr;
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
  // API version 31: the app's own UI for choosers, screen share and locks,
  // a detached page's display, page state per entry (shim_helper_host.mm).
  // The handler structs are embedder_ui_args.h's copies.
  int (*set_color_chooser_handler)(const ForkColorChooserHandler*) = nullptr;
  int (*color_chooser_choose)(int64_t, uint32_t) = nullptr;
  int (*color_chooser_end)(int64_t) = nullptr;
  int (*set_device_chooser_handler)(const ForkDeviceChooserHandler*) = nullptr;
  int (*device_chooser_answer)(int64_t, int, const int*, int) = nullptr;
  int (*set_desktop_media_handler)(const ForkDesktopMediaHandler*) = nullptr;
  int (*desktop_media_answer)(int64_t, int, int64_t, int) = nullptr;
  int (*set_lock_handler)(const ForkLockHandler*) = nullptr;
  int (*browser_pointer_lock_answer)(int, int) = nullptr;
  int (*browser_keyboard_lock_answer)(int, int) = nullptr;
  int (*browser_exit_pointer_lock)(int, int) = nullptr;
  int (*browser_exit_keyboard_lock)(int) = nullptr;
  int (*browser_send_locked_mouse_move)(int, double, double, int) = nullptr;
  int (*browser_set_page_display)(int, uint32_t, double, double) = nullptr;
  int (*browser_set_page_visibility)(int, int) = nullptr;  // shim_browser.mm
  char* (*tab_entry_page_state)(int, int) = nullptr;
  int (*tab_page_state_watch)(int, void (*)(void*, int, int), void*) = nullptr;
  int (*tab_restore_entries)(int, const ForkRestoreEntry*, int, int) = nullptr;
  // API version 31 (task 172): the renderer's answer to each DragTarget*
  // enter and over of a detached page (shim_helper_host.mm).
  int (*browser_drag_target_watch)(int, void (*)(void*, int, int, int), void*) = nullptr;
  // API version 31 (task 171): <select> popups as data (shim_browser.mm,
  // popup_menu_args.h).
  int (*browser_set_popup_menu_handler)(int, ForkPopupMenuShowFn, ForkPopupMenuHideFn, void*) = nullptr;
  int (*browser_popup_menu_reply)(int, int64_t, int) = nullptr;
  // API version 31 (task 172): autofill, password and <datalist> suggestions
  // as data, drawn by the app (shim_password_core.mm; suggestion_rows.h).
  int (*browser_set_suggestion_handler)(int, const ForkSuggestionHandler*) = nullptr;
  int (*browser_suggestion_action)(int, int64_t, int, int) = nullptr;
  // API version 31: IME of a detached page and its
  // composition bounds (shim_helper_host.mm). Used only when `version` >=
  // kDetachedImeForkApi.
  int (*browser_ime_set_composition)(int, const char*, const ForkImeSpan*, int, int, int, int, int) = nullptr;
  int (*browser_ime_commit_text)(int, const char*, int, int) = nullptr;
  int (*browser_ime_finish_composing)(int) = nullptr;
  int (*browser_ime_cancel)(int) = nullptr;
  int (*browser_composition_bounds_watch)(int, void (*)(void*, int, const void*), void*) = nullptr;
  // API 38 (numbered by the fork train p13-webui-086): its
  // presence says the fork honors CMUX_EXTRA_INFO_NO_RENDERER.
  int (*tab_renderer_state)(int) = nullptr;
  // No API number yet (the fork bundle p14-energy-136 numbers
  // it): delayed pump work as absolute run times with Chromium's leeway.
  void (*set_on_schedule_delayed)(void (*)(void*, int64_t, int64_t, int), void*) = nullptr;
  // p14-energy-029 (numbered by the fork bundle p14-energy-136): Energy Saver
  // with cmux's input and own-page exemption.
  void (*set_energy_saver)(bool, const char*) = nullptr;
  // No API number yet (numbered by p14-energy-136): the pid
  // of the renderer hosting a tab's main frame, 0 while none.
  int (*browser_renderer_pid)(int) = nullptr;
  // No API number yet (the fork train p07-memory-074 numbers
  // it): cmux's voter in Chromium's MultiSourceMemoryPressureMonitor.
  int (*memory_pressure_vote)(int) = nullptr;
  // No API number yet (the fork train numbers it): the
  // slice of the next CefDoMessageLoopWork call only, in microseconds.
  void (*set_message_loop_time_slice)(int64_t) = nullptr;
};

// The fork API that has the detached-page IME calls.
inline constexpr int kDetachedImeForkApi = 31;

}  // namespace cmux_shim

// The detached page's IME ops (shim_helper_host.mm): optional exports of the
// shim that cmux_cef_shim.h does not declare (plans/cmux-next/chromium-host-ops.json
// optional_exports; the Chromium Host resolves them by name and names them in
// its hello). Text is UTF-16LE, clauses are task p04-input-064's kIme layout
// (per clause i32 start, i32 end, u32 color 0xAARRGGBB, u32 thick, little
// endian), offsets UTF-16 units, -1, -1 no replacement range. Each does nothing
// for a fork below API 31, a page that is not detached or a malformed buffer.
extern "C" {
CMUX_SHIM_EXPORT void cmux_shim_browser_ime_set_composition(int browser_id, const uint8_t* text, int text_length,
                                                            const uint8_t* clauses, int clauses_length,
                                                            int selection_start, int selection_end,
                                                            int replace_start, int replace_end);
CMUX_SHIM_EXPORT void cmux_shim_browser_ime_commit_text(int browser_id, const uint8_t* text, int text_length,
                                                        int replace_start, int replace_end);
CMUX_SHIM_EXPORT void cmux_shim_browser_ime_finish_composing(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_browser_ime_cancel_composition(int browser_id);
}  // extern "C"

namespace cmux_shim {

struct Host {
  void* ctx = nullptr;
  cmux_shim_schedule_fn schedule = nullptr;
  cmux_shim_schedule_delayed_fn schedule_delayed = nullptr;
  cmux_shim_event_fn event = nullptr;
  cmux_shim_key_fn key = nullptr;
  cmux_shim_key_fn devtools_key = nullptr;
  cmux_shim_key_fn unhandled_key = nullptr;
  cmux_shim_window_request_fn window_request = nullptr;
  cmux_shim_focus_request_fn focus_request = nullptr;
  // Decides Chromium's focus requests when focus_request is null (the
  // Chromium Host's mode).
  EmbedderFocusPolicy embedder_focus;
  // The caller's find id of each browser's last cmux_shim_find, which its
  // FIND_RESULT events carry (UI thread).
  FindIds find_ids;
};

ForkApi& fork_api();
void InstallForkObserver();
Host& host();

// True when CEF's request to focus `browser_id` must be cancelled
// (CefFocusHandler::OnSetFocus returns it). In process cmux's focus_request
// decides; with none installed (host mode) only a browser cmux marked
// embedder-active may take focus (shim_browser.mm).
bool RefusesFocus(int browser_id, int source);
// cmux marked `browser_id` embedder-active or not (shim_helper_host.mm),
// recorded before the fork is told, which focuses the page inside the call.
void NoteEmbedderActive(int browser_id, bool active);

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

// A browser Chromium made gets the <select> popup handler while the host
// takes popups (cmux_shim_set_popup_menus; shim_browser.mm, UI thread).
void ApplyPopupMenus(int browser_id);
// The live DevTools browsers' identifiers (shim_devtools.mm, UI thread): they
// are not in browsers(), and their <select> popups go to the host too.
std::vector<int> DevToolsBrowserIds();
// The live DevTools browsers themselves (same thread and set).
std::vector<CefRefPtr<CefBrowser>> DevToolsBrowsers();

// The file chooser handler (shim_file_dialog.mm); CancelFileDialogs cancels
// the pending choosers of a browser that closed or crashed (UI thread).
CefRefPtr<CefDialogHandler> FileDialogHandlerInstance();
void CancelFileDialogs(int browser_id);

// Live browsers by identifier (UI thread only).
std::map<int, CefRefPtr<CefBrowser>>& browsers();
CefRefPtr<CefBrowser> BrowserById(int browser_id);

// A frame of browser_id attached to its renderer, left it or became the main
// frame (CefFrameHandler): FRAME_RENDERERS follows once the task's changes are
// done, when the renderers of its frames changed (shim_browser.mm,
// frame_renderers.h). ForgetFrameRenderers at its close. UI thread only.
void NoteFrameRenderersChanged(int browser_id);
void ForgetFrameRenderers(int browser_id);

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

// Chromium Host only (shim_client.mm): the host's key frame
// applier sends `event` to `browser_id` with this, on the UI thread, in place
// of CefBrowserHost::SendKeyEvent. `seq` is the kKey frame's input seq
// (Header::seq). If the page leaves a Command or Control key-down unhandled,
// OnKeyEvent reports KEY_UNHANDLED with that seq (request, b bit 1) and cmux
// runs the action it held or re-dispatches the key to its menus.
void SendHostKeyEvent(int browser_id, uint32_t seq, const CefKeyEvent& event);

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
// A new browser's suggestions go to the app as SUGGESTIONS events while it
// asked for them (cmux_shim_set_suggestion_events; shim_password_core.mm).
void InstallSuggestionHandler(int browser_id);
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
                          bool* use_default_window);
// The page closed: drop its DevTools placement.
void ForgetDevTools(int inspected);

}  // namespace cmux_shim
