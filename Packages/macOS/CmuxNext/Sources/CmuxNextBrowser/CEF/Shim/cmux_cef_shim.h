// C ABI between CmuxNextBrowser (Swift) and libcmux_cef_shim.dylib (C++ over
// the CEF wrapper of the pinned artifact, scripts/cmux-next/cef-manifest.json).
//
// The Swift side never includes this header: it resolves these functions with
// dlsym after it dlopens the shim on the first CEF tab, and mirrors the types
// in CEFShimLibrary.swift. Update both sides together.
//
// ABI identity: the SHA-256 of this file's bytes. build-cef-shim.sh compiles
// it into the shim (cmux_shim_abi_id), and CmuxNextBrowser bundles this file
// as a resource and hashes it (CEFShimABI). Any edit here changes the
// identity on both sides, so there is no number to bump and two parallel
// changes can never merge into the same identity. This file lives in the
// Swift target because SwiftPM resources must be inside the target.
//
// Threading: everything except the schedule callback runs on the main thread,
// which is the CEF UI thread (external message pump).

#ifndef CMUX_CEF_SHIM_H_
#define CMUX_CEF_SHIM_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_SHIM_EXPORT __attribute__((visibility("default")))

typedef enum {
  CMUX_SHIM_CONTEXT_INITIALIZED = 1,
  // browser_id created; request = token passed to create_window (0 when
  // Chromium created the tab itself); a = Chromium window id (0 while the
  // tab is in no window yet: a popup before Chromium places it);
  // b = opener browser id << 32 | the cef_window_open_disposition_t the
  // opener asked for (0 = unknown); s1 = "x,y,width,height" window features
  // of a popup, or "".
  CMUX_SHIM_AFTER_CREATED = 2,
  CMUX_SHIM_BEFORE_CLOSE = 3,
  CMUX_SHIM_ADDRESS = 4,          // s1 = url (main frame)
  CMUX_SHIM_TITLE = 5,            // s1 = title
  CMUX_SHIM_FAVICON = 6,          // s1 = first favicon url or ""
  CMUX_SHIM_LOADING_STATE = 7,    // a = loading | back << 1 | forward << 2
  CMUX_SHIM_LOAD_START = 8,       // main frame; s1 = url
  CMUX_SHIM_LOAD_END = 9,         // main frame; a = http status
  CMUX_SHIM_LOAD_ERROR = 10,      // main frame; a = cef_errorcode_t, s1 = text, s2 = url
  CMUX_SHIM_PROGRESS = 11,        // a = progress * 1000
  CMUX_SHIM_FULLSCREEN = 12,      // a = 1 entering
  CMUX_SHIM_DEVTOOLS_RESULT = 13, // request = message id, a = success, s1 = JSON
  CMUX_SHIM_FIND_RESULT = 14,     // request = find id, a = count, b = active | final << 32
  CMUX_SHIM_CLOSE_REQUESTED = 15, // the page asked to close (window.close)
  CMUX_SHIM_TAB_EVENT = 16,       // request = cmux_tab_event_t, a = window id, b = value
  CMUX_SHIM_POPUP = 17,           // s1 = url, a = WindowOpenDisposition
  // Reply to an async site call (ABI 3): request = the caller's reply id,
  // a = result (1 success, or the deleted cookie count), s1 = JSON.
  CMUX_SHIM_REPLY = 18,
  // Chromium's page context menu. request = token for
  // cmux_shim_context_menu_done, a/b = x/y in view coordinates (DIPs, top
  // left), s1 = JSON items [{id,label,type,enabled,checked,items?}],
  // s2 = JSON {link_url,source_url,page_url,selection,editable,media_type}.
  CMUX_SHIM_CONTEXT_MENU = 19,
  // DevTools of browser_id (the inspected page) is about to be created. The
  // host calls cmux_shim_devtools_set_placement before returning.
  CMUX_SHIM_DEVTOOLS_WILL_OPEN = 20,
  CMUX_SHIM_DEVTOOLS_OPENED = 21, // a = DevTools browser id, b = 1 docked
  CMUX_SHIM_DEVTOOLS_CLOSED = 22, // a = DevTools browser id
  // The tab's renderer process ended unexpectedly (Chromium's "Aw, Snap!").
  // a = cef_termination_status_t, b = error code (exit code or signal),
  // s1 = Chromium's error string.
  CMUX_SHIM_RENDER_TERMINATED = 23,
  // The renderer stopped processing input for 15 s (hang monitor). The host
  // answers with cmux_shim_unresponsive_reply; until then Chromium waits.
  CMUX_SHIM_RENDER_UNRESPONSIVE = 24,
  // The renderer answers again after RENDER_UNRESPONSIVE.
  CMUX_SHIM_RENDER_RESPONSIVE = 25,
  // A Chromium command that opens a window of Chromium's own (New Window,
  // New Incognito Window, Task Manager, feedback, guest profile, Move Tab to
  // New Window, app windows). The shim blocked it; request = the IDC_*
  // command id (chrome/app/chrome_command_ids.h).
  CMUX_SHIM_CHROME_COMMAND = 26,
  // The navigation guard (cmux_shim_set_navigation_guard) cancelled a
  // main-frame navigation that would leave the tab's store. s1 = url,
  // a = 1 for a redirect. The host re-creates the tab in the other store.
  CMUX_SHIM_NAVIGATION_REROUTE = 27,
  // The page did not handle a key down (CefKeyboardHandler::OnKeyEvent
  // after the renderer): Escape without modifiers (a popup panel closes on
  // it), or a letter A-Z without Command, Control or Option while no
  // editable field has focus (single-key page shortcuts). a = Windows key
  // code (0x1B, or 0x41-0x5A), b = 1 when Shift was down.
  CMUX_SHIM_KEY_UNHANDLED = 28,
  // An extension install or permission prompt (fork API 12): request =
  // prompt id (0 = "installed" notice, no reply), s1 = JSON (cef_cmux.h,
  // cmux_install_prompt_handler_t). Answer with cmux_shim_install_prompt_reply.
  CMUX_SHIM_INSTALL_PROMPT = 29,
  // chrome.omnibox suggestions (fork API 12): request = the request id of
  // cmux_shim_omnibox_input CHANGED, s1 = extension id, s2 = JSON
  // [{"content","description","deletable","styles":[{"offset","style"}]}].
  CMUX_SHIM_OMNIBOX_SUGGESTIONS = 30,
  // Focus left the page (CefFocusHandler::OnTakeFocus): Tab past the last
  // element (a = 1) or Shift-Tab past the first (a = 0).
  CMUX_SHIM_TAKE_FOCUS = 31,
} cmux_shim_event_kind_t;

typedef enum {
  CMUX_SHIM_DEVTOOLS_SHOW = 1,        // open, or focus the open DevTools
  CMUX_SHIM_DEVTOOLS_CONSOLE = 2,     // Chromium's IDC_DEV_TOOLS_CONSOLE
  CMUX_SHIM_DEVTOOLS_INSPECT = 3,     // Chromium's IDC_DEV_TOOLS_INSPECT (element picker)
  CMUX_SHIM_DEVTOOLS_INSPECT_AT = 4,  // inspect the element at (x, y), view coordinates
  CMUX_SHIM_DEVTOOLS_CLOSE = 5,
} cmux_shim_devtools_command_t;


// Any thread. Swift moves it to the main run loop timer.
typedef void (*cmux_shim_schedule_fn)(void* ctx, int64_t delay_ms);
// Main thread. Strings are never NULL and are valid for the duration of the
// call. Plain parameters (no struct) so Swift needs no layout assumptions.
typedef void (*cmux_shim_event_fn)(void* ctx,
                                   int kind,
                                   int browser_id,
                                   int request,
                                   int64_t a,
                                   int64_t b,
                                   const char* s1,
                                   const char* s2);
// Main thread, before the page sees a key down. ns_event is an NSEvent*.
// Return 1 when the host consumed it.
typedef int (*cmux_shim_key_fn)(void* ctx, int browser_id, void* ns_event);
// Main thread, possibly inside a Chromium navigation (fork API 8). Chromium
// wants a window of its own, or a tab with no window to hold it: a link or
// window.open that opens a new window or popup, a link from a chrome://
// page, chrome.windows.create, a Browser Chromium created by itself.
// kind = cmux_window_request_kind_t of the fork (0 tab, 1 window, 2 popup,
// 3 incognito, 4 app); disposition = the requested
// cef_window_open_disposition_t; source_browser_id = the tab that asked, or
// 0; x/y/width/height are valid when has_bounds (screen DIPs); profile_path
// = the Chromium profile directory. Return the browser id of a tab whose
// window gets the new tab, or 0 to open nothing in Chromium. Must not
// create or close browsers.
typedef int (*cmux_shim_window_request_fn)(void* ctx,
                                           int kind,
                                           int disposition,
                                           int source_browser_id,
                                           int has_bounds,
                                           int x,
                                           int y,
                                           int width,
                                           int height,
                                           const char* url,
                                           const char* profile_path);
// Main thread, when Chromium asks to focus a page (CefFocusHandler::
// OnSetFocus; source = cef_focus_source_t, 0 navigation, 1 system). CEF
// asks after every navigation it starts (a new browser's first load,
// cmux_shim_load_url); cmux_shim_set_focus(id, 1) asks as system inside
// that call. Return 1 to let the page take focus, 0 to refuse.
typedef int (*cmux_shim_focus_request_fn)(void* ctx, int browser_id, int source);


// SHA-256 (64 lowercase hex digits) of this header as the shim was built.
CMUX_SHIM_EXPORT const char* cmux_shim_abi_id(void);

// Loads the framework (dlopen) and binds the fork API. Returns 1 on success;
// on failure writes a message into err.
CMUX_SHIM_EXPORT int cmux_shim_load(const char* framework_binary, char* err, size_t err_len);
// cmux_cef_api_version() of the fork, or 0 for stock CEF.
CMUX_SHIM_EXPORT int cmux_shim_fork_api_version(void);
// Turns on extensions.ui.developer_mode in every profile the shim creates.
// Chromium disables unpacked (--load-extension) extensions without it.
// Development and verification only; call before cmux_shim_initialize.
CMUX_SHIM_EXPORT void cmux_shim_set_extension_developer_mode(int enabled);
// Page background before the first paint and for documents without one
// (CefSettings.background_color and CefBrowserSettings.background_color),
// as opaque 0xAARRGGBB; 0 keeps Chromium's default. Browsers created after
// the call use it; call before cmux_shim_initialize so tabs the fork adds
// (cmux_shim_tab_add) fall back to it too.
CMUX_SHIM_EXPORT void cmux_shim_set_background_color(unsigned int argb);
// Fork API 12: browser_id's own page background (0xAARRGGBB), kept across
// tab moves and popups; later theme changes (cmux_shim_set_background_color)
// no longer repaint it. Returns 0 when the fork lacks the call.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_background_color(int browser_id, unsigned int argb);
// The page chrome://newtab shows when no extension overrides the New Tab
// page (fork API 12); NULL or "" keeps Chromium's. Any time, also before
// cmux_shim_initialize. The ADDRESS event reports "chrome://newtab/" for a
// New Tab page, whatever URL it loaded.
CMUX_SHIM_EXPORT void cmux_shim_set_new_tab_page_url(const char* url);
// Adds a folder Chromium searches for native messaging host manifests after
// its own (fork API 12), in call order. user_level = 1 for a per-user folder
// (skipped when policy forbids user-level hosts). Returns 0 when the fork
// cannot (after initialize) or the path is empty.
CMUX_SHIM_EXPORT int cmux_shim_add_native_messaging_dir(const char* path, int user_level);
// Returns 1 when NSApp conforms to CefAppProtocol and implements its
// methods (the host app's NSApplication subclass must), 0 otherwise. The shim
// no longer patches NSApp. Check before cmux_shim_initialize.
CMUX_SHIM_EXPORT int cmux_shim_prepare_application(void);
// CefInitialize with external_message_pump. CONTEXT_INITIALIZED arrives
// before this returns. Returns 1 on success.
//   framework_dir     .../Chromium Embedded Framework.framework
//   main_bundle_path  the .app
//   subprocess_path   base helper executable
//   log_file          NULL = CEF default
//   log_severity      cef_log_severity_t, 0 = default
//   locale            CefSettings.locale (Chromium name, "en-US"); NULL = CEF default
//   accept_languages  accept_language_list for CefSettings and every
//                     request context ("ja,en-US,en"); NULL = CEF default
//   switches          "name" or "name=value", NULL terminated
CMUX_SHIM_EXPORT int cmux_shim_initialize(const char* framework_dir,
                                          const char* main_bundle_path,
                                          const char* subprocess_path,
                                          const char* root_cache_path,
                                          const char* log_file,
                                          int log_severity,
                                          const char* locale,
                                          const char* accept_languages,
                                          const char* const* switches,
                                          void* ctx,
                                          cmux_shim_schedule_fn schedule,
                                          cmux_shim_event_fn event,
                                          cmux_shim_key_fn key);
CMUX_SHIM_EXPORT void cmux_shim_do_work(void);

// Creates a Chrome-style browser whose Chromium window tracks parent_view
// (NSView*). profile_cache_path selects a request context (NULL = global).
// AFTER_CREATED with `request` follows. Returns 1 if creation started.
CMUX_SHIM_EXPORT int cmux_shim_create_window(int request,
                            void* parent_view,
                            int width,
                            int height,
                            const char* url,
                            const char* profile_cache_path);
// Fork tab API; 0 on failure.
CMUX_SHIM_EXPORT int cmux_shim_tab_add(int window_browser_id, const char* url, int index, int activate);
CMUX_SHIM_EXPORT int cmux_shim_tab_activate(int browser_id);
// Back/Forward menu entries. JSON {"current": index, "entries": [{"url",
// "title"}]} (display URLs), freed with cmux_shim_free; NULL for an unknown
// browser. Works on every fork.
CMUX_SHIM_EXPORT char* cmux_shim_tab_navigation_entries(int browser_id);
// One history navigation to the entry `offset` from the current one
// (negative = back). 1 when it went; 0 on forks before API 14.
CMUX_SHIM_EXPORT int cmux_shim_tab_go_to_entry(int browser_id, int offset);
CMUX_SHIM_EXPORT int cmux_shim_tab_window_id(int browser_id);

CMUX_SHIM_EXPORT void cmux_shim_load_url(int browser_id, const char* url);
CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_go_forward(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_reload(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_stop(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_set_focus(int browser_id, int focus);
// Without a handler every focus request wins (CEF's default).
CMUX_SHIM_EXPORT void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn handler);
CMUX_SHIM_EXPORT void cmux_shim_set_zoom_level(int browser_id, double level);
// FIND_RESULT events carry `find_id`.
CMUX_SHIM_EXPORT void cmux_shim_find(int browser_id, int find_id, const char* text, int forward, int match_case, int find_next);
CMUX_SHIM_EXPORT void cmux_shim_stop_finding(int browser_id, int clear_selection);
CMUX_SHIM_EXPORT void cmux_shim_close(int browser_id);
// Runs a DevTools method in process; DEVTOOLS_RESULT carries the returned id.
// Returns 0 when the browser is gone or params_json is not a JSON object.
CMUX_SHIM_EXPORT int cmux_shim_devtools_call(int browser_id, const char* method, const char* params_json);

// DevTools. DevTools browsers are never tabs: they have their own
// client and report only CMUX_SHIM_DEVTOOLS_* events.
// Key downs in a DevTools browser; browser_id is the inspected page.
CMUX_SHIM_EXPORT void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn key);
// Where the next DevTools of browser_id goes: a child of parent_view
// (NSView*, width x height), or, with parent_view NULL, its own window at
// (x, y, width, height) in screen coordinates (0 size = Chromium's default).
CMUX_SHIM_EXPORT void cmux_shim_devtools_set_placement(int browser_id, void* parent_view, int x, int y, int width, int height);
// cmux_shim_devtools_command_t; returns 0 when browser_id is gone.
CMUX_SHIM_EXPORT int cmux_shim_devtools_command(int browser_id, int command, int x, int y);
// The DevTools browser id of browser_id, or 0 when DevTools is closed.
CMUX_SHIM_EXPORT int cmux_shim_devtools_browser(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_devtools_set_focus(int browser_id, int focus);

// Extension actions (fork API v1). Returned strings are freed with
// cmux_shim_free.
CMUX_SHIM_EXPORT char* cmux_shim_ext_actions(int browser_id, int icon_px);
CMUX_SHIM_EXPORT int cmux_shim_ext_action_run(int browser_id, const char* extension_id, int x, int width);
CMUX_SHIM_EXPORT void cmux_shim_ext_action_hide_popup(int browser_id, const char* extension_id);
CMUX_SHIM_EXPORT void cmux_shim_ext_action_context_menu(int browser_id, const char* extension_id, int screen_x, int screen_y);
CMUX_SHIM_EXPORT void cmux_shim_free(char* s);

// Navigation state (fork API v7; NULL/0 on older forks): the tab's history
// with page state as an opaque string (freed with cmux_shim_free), restored
// into a browser created with an empty URL. 1 when the fork has both.
CMUX_SHIM_EXPORT char* cmux_shim_tab_navigation_state(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_tab_restore_navigation(int browser_id, const char* state);
CMUX_SHIM_EXPORT int cmux_shim_navigation_restore_supported(void);

// Extension management and commands (fork API v3; 0/NULL on older forks).
CMUX_SHIM_EXPORT char* cmux_shim_ext_list(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_set_enabled(int browser_id, const char* extension_id, int enabled);
CMUX_SHIM_EXPORT int cmux_shim_ext_uninstall(int browser_id, const char* extension_id);
// Fork API v5: reloads an extension (also a terminated one); 0 on older forks.
CMUX_SHIM_EXPORT int cmux_shim_ext_reload(int browser_id, const char* extension_id);
// Fork API v6: moves a pinned extension to `index` among the pinned ones; 0 on older forks.
CMUX_SHIM_EXPORT int cmux_shim_ext_move_pinned(int browser_id, const char* extension_id, int index);
CMUX_SHIM_EXPORT int cmux_shim_ext_set_pinned(int browser_id, const char* extension_id, int pinned);
CMUX_SHIM_EXPORT int cmux_shim_ext_open_options(int browser_id, const char* extension_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_load_unpacked(int browser_id, const char* path);
CMUX_SHIM_EXPORT char* cmux_shim_ext_commands(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_command_run(int browser_id, const char* extension_id, const char* command);
CMUX_SHIM_EXPORT int cmux_shim_tab_move_to_window(int browser_id, int window_browser_id, int index);
// Answers RENDER_UNRESPONSIVE: terminate = 0 waits (restarts the hang timer),
// 1 ends the renderer (RENDER_TERMINATED follows). Returns 1 when the browser
// had an unanswered hang, 0 otherwise.
CMUX_SHIM_EXPORT int cmux_shim_unresponsive_reply(int browser_id, int terminate);
// Ends a CONTEXT_MENU: command_id < 0 cancels.
CMUX_SHIM_EXPORT void cmux_shim_context_menu_done(int token, int command_id, int event_flags);

// Popup windows extensions create (chrome.windows.create type "popup",
// fork API 11). Enabled, such a window stays hidden and keeps its window id
// until the host attaches it (tab events CMUX_POPUP_WINDOW_CREATED = 10 and
// CMUX_POPUP_WINDOW_BOUNDS = 11 of the fork); disabled (the default), its tab
// moves into a pane window. Call before cmux_shim_initialize; a host that
// enables it must attach or close every such window. No-ops and 0 on older
// forks.
CMUX_SHIM_EXPORT void cmux_shim_set_popup_windows_enabled(int enabled);
// Screen DIPs, top-left origin. Returns 0 when the window is unknown.
CMUX_SHIM_EXPORT int cmux_shim_popup_window_bounds(int window_id, int* x, int* y, int* width, int* height);
// Attaches the kept window over parent_view (NSView*); 1 on success. Call on a
// later run loop turn than its event.
CMUX_SHIM_EXPORT int cmux_shim_popup_window_attach(int window_id, void* parent_view, int width, int height);

// Side panel header (fork API 13). The side panel stays Chromium's; the
// host draws its header over Chromium's header area. The fork's tab event
// CMUX_SIDE_PANEL_CHANGED = 12 reports changes. State JSON (cef_cmux.h,
// cmux_side_panel_state), freed with cmux_shim_free; NULL on older forks.
CMUX_SHIM_EXPORT char* cmux_shim_side_panel_state(int browser_id);
// control: "close", "pin", "open_in_new_tab", "more_info". Runs Chromium's
// own control; 0 when it is not shown.
CMUX_SHIM_EXPORT int cmux_shim_side_panel_press(int browser_id, const char* control);

// Extension install and permission prompts (fork API 12). result: 0 abort,
// 1 accept, 2 cancel, 3 accept withholding host permissions. Returns 0 when
// the prompt is unknown.
CMUX_SHIM_EXPORT int cmux_shim_install_prompt_reply(int prompt_id, int result);

// chrome.omnibox keyword sessions (fork API 12). Keywords of the tab's
// profile as JSON [{"extension_id","keyword","name","icon_png",
// "default_description"}], freed with cmux_shim_free; NULL on older forks.
CMUX_SHIM_EXPORT char* cmux_shim_omnibox_keywords(int browser_id);
// event: 0 started, 1 changed (value = request id), 2 entered (value =
// 0 current tab, 1 new foreground tab, 2 new background tab), 3 cancelled,
// 4 delete suggestion (text = its content). CHANGED returns 1 when the
// extension listens (OMNIBOX_SUGGESTIONS follows).
CMUX_SHIM_EXPORT int cmux_shim_omnibox_input(int browser_id, const char* extension_id, int event,
                                             const char* text, int value);

// Chromium never shows a window of its own (fork API 8). The handler
// chooses where each window request goes; without one the fork uses the
// requesting tab's window. No-op on older forks.
CMUX_SHIM_EXPORT void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler);
// Browsers (windows) Chromium created outside cmux and never showed since
// start (fork API 8); -1 on older forks.
CMUX_SHIM_EXPORT int cmux_shim_foreign_browser_count(void);

// Shutdown ordering (fork API v2).
CMUX_SHIM_EXPORT void cmux_shim_close_all(void);
CMUX_SHIM_EXPORT int cmux_shim_live_browser_count(void);
CMUX_SHIM_EXPORT int cmux_shim_window_count(void);  // -1 when the fork API is missing
CMUX_SHIM_EXPORT void cmux_shim_shutdown(void);

// Site state for Page Info (ABI 3). Content types are named as
// SitePermissionKind raw values ("location", "popups", "thirdPartySignIn",
// see shim_site.mm); values are cef_content_setting_values_t.
//
// The effective setting for url in the browser's request context; url NULL
// or "" returns the default for the type. -1 for an unknown type or browser.
CMUX_SHIM_EXPORT int cmux_shim_content_setting(int browser_id, const char* url, const char* type);
// Stores value for url (0 = CEF_CONTENT_SETTING_VALUE_DEFAULT clears it).
// Returns 1 when stored.
CMUX_SHIM_EXPORT int cmux_shim_set_content_setting(int browser_id, const char* url, const char* type, int value);
// Visits every cookie of the browser's request context. REPLY with `reply`
// follows, s1 = [{"name","domain","path"}]. Returns 0 when not started.
CMUX_SHIM_EXPORT int cmux_shim_visit_cookies(int browser_id, int reply);
// Deletes the host and domain cookies of url named name (every name when
// name is NULL or ""). REPLY with `reply` follows, a = deleted count.
CMUX_SHIM_EXPORT int cmux_shim_delete_cookies(int browser_id, int reply, const char* url, const char* name);
// Browser import: writes cookies into the request context of
// profile_cache_path (a persistent profile; an off-the-record key returns 0),
// creating the context when no tab opened it yet. json = [{"url","name",
// "value","domain","path","secure","httponly","same_site" (cef_cookie_same_site_t),
// "has_expires","expires","creation","last_access" (decimal strings,
// microseconds since 1601)}]. REPLY with `reply` and browser 0 follows once
// every cookie was handled: a = written, s1 = {"written","rejected"}.
// Returns 0 when nothing was started (bad path or JSON).
CMUX_SHIM_EXPORT int cmux_shim_import_cookies(const char* profile_cache_path, int reply, const char* json);
// Browser import: saved passwords into the Chromium password store of
// profile_cache_path (a persistent profile; an off-the-record key returns 0),
// the store autofill reads, encrypted with cmux's own Keychain key. Every
// field is UTF-8 with an explicit length (no terminator needed). The shim
// copies the entries before it returns, so the caller zeroes its buffers at
// once; the shim zeroes its copies when the store has taken them. Values are
// never logged. REPLY with `reply` and browser 0 follows: s1 = {"added",
// "duplicate","conflict","rejected"} (counts only). Returns 0 when nothing was
// started (bad path, or the fork lacks cmux_password_import: API 15).
typedef struct {
  const char* url;
  size_t url_length;
  const char* signon_realm;
  size_t signon_realm_length;
  const char* username;
  size_t username_length;
  const char* password;
  size_t password_length;
  // Microseconds since 1601 (Chromium time); 0 = now.
  int64_t created;
} cmux_shim_password_entry;
CMUX_SHIM_EXPORT int cmux_shim_import_passwords(const char* profile_cache_path, int reply, const cmux_shim_password_entry* entries,
                                                int count);
// sizeof(cmux_shim_password_entry): Swift writes entries at the C offsets
// (url 0, url_length 8, signon_realm 16, signon_realm_length 24, username 32,
// username_length 40, password 48, password_length 56, created 64) and
// refuses to call when this is not 72.
CMUX_SHIM_EXPORT int cmux_shim_password_entry_size(void);
// 1 when this fork can write passwords (cmux_password_import, API 15).
CMUX_SHIM_EXPORT int cmux_shim_password_import_available(void);
// Turns Chromium's password filling on or off in one tab. An agent-driven
// tab has it off: a page script could otherwise read a filled password
// after an automated click (plans/cmux-next/browser.md, "Secure sign-in").
// Returns 0 when the fork lacks cmux_tab_set_password_fill (API 15).
CMUX_SHIM_EXPORT int cmux_shim_set_password_fill(int browser_id, int enabled);
// The visible entry's SSL status as JSON {"secure","certStatus",
// "contentStatus","sslVersion","url","chain":[base64 DER, leaf first]}, or
// NULL. Free with cmux_shim_free_owned.
CMUX_SHIM_EXPORT char* cmux_shim_ssl_status(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_free_owned(char* s);

// Renderer processes of a tab (resource hover cards). Writes at most
// `capacity` distinct renderer client ids (Chromium's RenderProcessHost id,
// the `--renderer-client-id=` switch of that renderer's helper process)
// that host a frame of browser_id: the main frame and every out-of-process
// iframe. Returns how many it wrote; 0 when the browser is gone.
CMUX_SHIM_EXPORT int cmux_shim_renderer_client_ids(int browser_id, int* out, int capacity);
// Remote localhost (plans/cmux-next/remote-localhost.md). Call before the
// first window with profile_cache_path each launch: that request context
// sends every request (loopback included) to the app's proxy at
// 127.0.0.1:port, which accepts only this app's processes. Returns 1 when
// stored.
CMUX_SHIM_EXPORT int cmux_shim_set_context_proxy(const char* profile_cache_path, int port);
// 2 applied to the request context, 1 pending (not initialized yet),
// 0 none, -1 Chromium refused the preference.
CMUX_SHIM_EXPORT int cmux_shim_context_proxy_state(const char* profile_cache_path);
// Drops the shim's request context for profile_cache_path. A key that starts
// with "cmux-otr:" names an off-the-record context (an empty cache path: a
// unique in-memory profile); Chromium destroys that profile, with all of its
// data, once no browser uses it.
CMUX_SHIM_EXPORT void cmux_shim_release_context(const char* profile_cache_path);
// Main-frame http(s) navigations of browser_id: 0 unrestricted, 1 must stay
// loopback (a remote machine's store), 2 must not be loopback (a normal
// store in a remote workspace). A violation is cancelled and reported as
// NAVIGATION_REROUTE.
CMUX_SHIM_EXPORT void cmux_shim_set_navigation_guard(int browser_id, int mode);

#ifdef __cplusplus
}
#endif

#endif  // CMUX_CEF_SHIM_H_
