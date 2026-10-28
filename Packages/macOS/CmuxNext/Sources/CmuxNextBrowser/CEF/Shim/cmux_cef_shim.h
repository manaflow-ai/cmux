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
  // b = opener browser id << 32 | 1 << 16 when the opener's request had a
  // user gesture | the cef_window_open_disposition_t the opener asked for
  // (0 = unknown); s1 = "x,y,width,height" window features of a popup, or "";
  // s2 = the popup's target URL (OnBeforePopup), or "". The opener's pending
  // popup is matched by the new tab's URL; a popup Chromium aborted, or one
  // older than about 1 s, never matches.
  CMUX_SHIM_AFTER_CREATED = 2,
  CMUX_SHIM_BEFORE_CLOSE = 3,
  CMUX_SHIM_ADDRESS = 4,          // s1 = url (main frame)
  CMUX_SHIM_TITLE = 5,            // s1 = title
  CMUX_SHIM_FAVICON = 6,          // s1 = first favicon url or ""
  CMUX_SHIM_LOADING_STATE = 7,    // a = loading | back << 1 | forward << 2
  CMUX_SHIM_LOAD_START = 8,       // main frame; s1 = url, a = 1 when the entry came from a POST
  CMUX_SHIM_LOAD_END = 9,         // main frame; a = http status
  CMUX_SHIM_LOAD_ERROR = 10,      // main frame; a = cef_errorcode_t, b = 1 when Chromium shows its certificate
                                  // interstitial for it, s1 = text, s2 = url
  CMUX_SHIM_PROGRESS = 11,        // a = progress * 1000
  CMUX_SHIM_FULLSCREEN = 12,      // a = 1 entering
  CMUX_SHIM_DEVTOOLS_RESULT = 13, // request = message id, a = success, s1 = JSON
  CMUX_SHIM_FIND_RESULT = 14,     // request = find id, a = count, b = active | final << 32
  CMUX_SHIM_CLOSE_REQUESTED = 15, // the page asked to close (window.close)
  CMUX_SHIM_TAB_EVENT = 16,       // request = cmux_tab_event_t, a = window id, b = value
  CMUX_SHIM_POPUP = 17,           // s1 = url, a = WindowOpenDisposition, b = 1 with a user gesture
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
  // a = cef_termination_status_t, b = error code (exit code or signal) in
  // the low 32 bits | the renderer's client id (its --renderer-client-id,
  // 0 when the shim cannot name it) << 32, s1 = Chromium's error string.
  // request = 1 for the first browser of the renderer's end, 2 for each
  // other browser it hosted (Chromium tells them all in one task), 0 when
  // the shim cannot name the process.
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
  // A DevTools protocol message of browser_id
  // (CefDevToolsMessageObserver::OnDevToolsMessage). s1 = the raw JSON
  // message. Two kinds come here: every reply to cmux_shim_devtools_send
  // (its "id" is >= 2^30; it never also arrives as DEVTOOLS_RESULT), and,
  // while cmux_shim_devtools_watch_events is on for browser_id, every
  // protocol event (a message without "id", for example
  // Runtime.bindingCalled). Replies to cmux_shim_devtools_call stay
  // DEVTOOLS_RESULT only.
  CMUX_SHIM_DEVTOOLS_EVENT = 32,
  // A watched preference changed (cmux_shim_pref_watch). browser_id = 0,
  // s1 = the preference name, s2 = the profile cache path.
  CMUX_SHIM_PREF_CHANGED = 33,
  // Downloads (CefDownloadHandler). Every download Chromium starts (a page's
  // download, Option-click, cmux_shim_download_url) waits for the host's
  // path: the host answers DOWNLOAD_STARTED with cmux_shim_download_continue
  // (during the event or later). request = the shim's download token (one
  // per download, never reused; Chromium's own ids repeat across profiles),
  // browser_id = the tab, or 0. STARTED: a = total bytes (-1 unknown),
  // s1 = the original url, s2 = Chromium's suggested file name.
  CMUX_SHIM_DOWNLOAD_STARTED = 34,
  // a = received bytes, b = total bytes (-1 unknown), s1 = bytes per second
  // (decimal), s2 = "paused" or "".
  CMUX_SHIM_DOWNLOAD_PROGRESS = 35,
  // Once per download: a = 1 complete, 2 cancelled, 3 interrupted;
  // b = cef_download_interrupt_reason_t; s1 = the full path ("" if none).
  CMUX_SHIM_DOWNLOAD_DONE = 36,
  // A sign-in tab (cmux_shim_set_auth_callback) navigated its main frame to
  // the session's callback. The shim cancelled the navigation before it
  // loaded; s1 = the callback url.
  CMUX_SHIM_AUTH_CALLBACK = 37,
  // A main-frame navigation to a local file cmux shows elsewhere (Markdown,
  // or H.264/HEVC or AAC media this build cannot decode;
  // CEFShim/src/local_file_handoff.h). The shim cancelled it; s1 = url. The
  // host opens the file in cmux's markdown page or a WebKit tab.
  CMUX_SHIM_LOCAL_FILE_HANDOFF = 38,
  // The chrome.bookmarks bridge (fork API 22): s1 = one cmux_bookmarks_observe
  // event (JSON), s2 = the profile cache path. Every persistent profile is
  // watched once its request context is initialized; {"op": "loaded"} asks
  // the host to sync (cmux_shim_bookmarks_sync).
  CMUX_SHIM_BOOKMARKS_EVENT = 39,
  // A main-frame navigation to a scheme neither Chromium nor cmux loads
  // (mailto:, an app's own scheme; CEFShim/src/external_url.h). The shim
  // cancelled it; s1 = url, a = 1 when the user's gesture started it. The
  // host opens it in its app or asks first (BrowserExternalApps).
  CMUX_SHIM_EXTERNAL_URL = 40,
  // A page asks for a permission the host decides (location;
  // CEFShim/src/shim_permissions.mm). Chromium waits for
  // cmux_shim_permission_continue (during the event or later). request =
  // the prompt's token, a = the cef_permission_request_types_t bits,
  // s1 = the requesting origin.
  CMUX_SHIM_PERMISSION_PROMPT = 41,
  // Chromium ended a waiting PERMISSION_PROMPT itself (the page navigated or
  // closed); request = its token. Not sent after the host's answer.
  CMUX_SHIM_PERMISSION_DISMISSED = 42,
  // Chromium's password manager asks to save or update a sign-in (fork API
  // 20; Chromium's bubble does not show). request = prompt id, s1 = JSON
  // {"prompt_id","browser_id","kind": "save" | "update" | "gone","origin",
  // "username","other_usernames_count"}; never the password. "gone": the
  // tab navigated or closed and the prompt can no longer be answered.
  // Answer once with cmux_shim_password_prompt_answer.
  CMUX_SHIM_PASSWORD_PROMPT = 43,
  // The page's beforeunload asks before it unloads (a navigation, a reload,
  // or a close the host started with cmux_shim_try_close); Chromium's own
  // dialog does not show. request = the question's token, a = 1 for a
  // reload. Chromium waits for cmux_shim_before_unload_reply (Leave or
  // Stay). A close by cmux_shim_close or cmux_shim_close_all never asks.
  CMUX_SHIM_BEFORE_UNLOAD_DIALOG = 44,
  // Chromium ended a waiting BEFORE_UNLOAD_DIALOG itself (the renderer
  // ended, the page navigated or closed). Not sent after the host's answer.
  CMUX_SHIM_BEFORE_UNLOAD_DISMISSED = 45,
  // A cmux-page:// page asks for one of its dynamic paths
  // (cmux_shim_page_scheme_add_first_party_dynamic). request = token,
  // s1 = the full URL. Chromium waits for cmux_shim_page_resource_respond
  // (during the event or later); a request the page cancels drops it.
  CMUX_SHIM_PAGE_RESOURCE = 46,
  // A drag of files from outside the app entered a page (CefDragHandler::
  // OnDragEnter); s1 = JSON array of the files' absolute paths. The page
  // still gets the drag.
  CMUX_SHIM_PAGE_DRAG_ENTER = 47,
  // A page opened a file chooser (<input type=file>, a save picker): browser_id;
  // request = the dialog id for cmux_shim_file_dialog_answer; a = mode (0 open
  // one file, 1 open several, 2 a folder, 3 save); s1 = accept types one per
  // line (MIME types and ".ext"); s2 = the default path or file name. Chromium
  // shows no panel; a closed or crashed browser cancels it.
  CMUX_SHIM_FILE_DIALOG = 48,
  // 49 to 53 are taken (plans/cmux-next/chromium-host-ops.json, optional_events).
  // The page's cursor changed (CefDisplayHandler::OnCursorChange), only after
  // cmux_shim_set_cursor_events(1): a = cef_cursor_type_t. For CT_CUSTOM (45)
  // s1 = the image as PNG, base64; request = image pixels per DIP x 1000;
  // b = the hotspot in image pixels, x in the low 32 bits, y in the high 32.
  CMUX_SHIM_CURSOR = 54,
  // The page answered a drag over it (cmux_shim_browser_drag_target_enter
  // and _over; fork API 31's cmux_browser_drag_target_watch, task
  // p01-process-172): a = the operation the page takes
  // (cef_drag_operations_mask_t, 0 none); b = 1 when the document handles
  // the drag itself. It may come turns after the enter or over it answers;
  // the drag's destination returns the last one (Chrome's WebDragDest
  // -setCurrentOperation:).
  CMUX_SHIM_DRAG_OPERATION = 55,
  // 56 is the Chromium Host's CMUX_SHIM_WHEEL_ACK (HOST/src/host_wheel_ack.h).
  // The page's tooltip changed (CefDisplayHandler::OnTooltip), only after
  // cmux_shim_set_cursor_events(1): s1 = the text, UTF-8; "" hides it.
  // Chromium shows no tooltip of its own then.
  CMUX_SHIM_TOOLTIP = 57,
  // A page opened a <select> popup, only after cmux_shim_set_popup_menus(1):
  // a = the popup's token; s1 = JSON {"x", "y", "width", "height": the
  // <select>'s rect in the page view's DIPs from its top left; "fontSize":
  // the items' size in points; "selected": the selected item's index, -1 for
  // none; "rightAligned"; "items": [{"label", "toolTip", "type" (0 option,
  // 1 checkable option, 2 group label, 3 separator, 4 submenu), "enabled",
  // "checked", "rtl", "directionOverride"}]}. The page has at most one open
  // popup. Answer it once with cmux_shim_browser_popup_menu_reply.
  CMUX_SHIM_POPUP_MENU = 58,
  // Chromium closed popup a (the token) before cmux answered it (the page
  // removed or closed the <select>, navigated, was hidden or closed): close
  // its menu with no answer (Chrome's PopupMenuRunner.Hide).
  CMUX_SHIM_POPUP_MENU_HIDE = 59,
  // A field's autofill, password or <datalist> suggestions, which the app
  // draws (only after cmux_shim_set_suggestion_events(1); fork API 31's
  // suggestion handler, tasks p01-process-172 and 061): request =
  // cmux_shim_suggestion_event_t, a = the rows' token (0 for ANNOUNCE).
  // SHOW: s1 = JSON {"x","y","width","height" (the field in the page view's
  // DIP, top left origin), "rtl", "selected" (-1 none), "rows":[{"kind" (0
  // entry, 1 separator, 2 title, 3 footer), "type" (Chromium's
  // autofill::SuggestionType), "main", "minor", "label" (one line per label
  // line), "voice_over", "selectable", "acceptable", "loading"}]}: it shows
  // the rows or replaces the shown ones and their token. SELECT: b = the row
  // a key selected, -1 none. HIDE: the token's rows close. ANNOUNCE: s1 =
  // what VoiceOver reads.
  CMUX_SHIM_SUGGESTIONS = 60,
  // Host mode only (task p01-process-228): the Chromium Host's pushes of the
  // fork API 31 color chooser, device chooser and screen-share picker
  // handlers, which it installs while the app has set
  // cmux_shim_set_color_chooser_handler, _set_device_chooser_handler or
  // _set_desktop_media_handler. request = that handler's event
  // (CMUX_SHIM_COLOR_CHOOSER_OPEN ...), a = token, b = the color (color
  // chooser), s1 = the fork struct's fields as bytes
  // (ChromiumHost/src/host_choosers.h). The remote shim calls the handler's
  // fn with them; they never reach the event fn, and the in-process shim
  // never sends them.
  CMUX_SHIM_COLOR_CHOOSER = 61,
  CMUX_SHIM_DEVICE_CHOOSER = 62,
  CMUX_SHIM_DESKTOP_MEDIA = 63,
  // A frame other than a browser's main frame gained or lost its renderer
  // (CefFrameHandler::OnFrameAttached and OnFrameDetached): browser_id;
  // request = the frame's renderer client id (its render process host id, the
  // renderer's --renderer-client-id); a = 1 attached, 0 detached; s1 = the
  // frame's identifier (CefFrame::GetIdentifier). A renderer's
  // death detaches its frames too (WebContentsObserver::RenderFrameDeleted),
  // before or after the app sees the process end. The app names the pages a
  // renderer's crash leaves a sad frame in from it (Chrome's
  // DiscardPageWithCrashedSubframePolicy reads the dead process's frame nodes).
  CMUX_SHIM_SUBFRAME_RENDERER = 64,
  // Host mode only: one call of the fork's lock handler, pushed by the
  // Chromium Host while cmux's remote shim has a lock handler
  // (cmux_shim_set_lock_handler, task p01-process-229): request =
  // cmux_shim_lock_event_t, a = its detail. The remote shim calls cmux's
  // lock fn with them; cmux's event fn never sees this kind.
  CMUX_SHIM_LOCK = 65,
  // A window request the shim decided with the policy cmux pushed
  // (cmux_shim_set_window_request_policy), while no window_request_fn is
  // installed: the Chromium Host decides inside Chromium's navigation and
  // cmux applies the result. browser_id = the requesting tab, or 0;
  // request = the Chromium window of the anchor (INSERT), else 0; a = the
  // anchor whose window gets the new tab (INSERT), else 0; b's low 32 bits =
  // cmux_shim_window_outcome_t | cmux_shim_new_tab_t << 8 | the request's
  // kind << 16 | its cef_window_open_disposition_t (7 bits) << 24 |
  // user_gesture << 31, and its high 32 bits the id the Chromium Host minted
  // for an INSERT's tab (0: none; the shim leaves them 0); s1 = the URL;
  // s2 = "x,y,width,height" (or nothing), ";", the request's store (the
  // source pane's, else the normalized profile directory). An INSERT's tab
  // comes in its own AFTER_CREATED, which names it by that minted id.
  CMUX_SHIM_WINDOW_REQUEST_RESULT = 66,
  // The renderer processes that host browser_id's frames changed: a frame
  // attached to its renderer, left it or became the main frame
  // (CefFrameHandler), as an iframe added after the load, an out-of-process
  // iframe's swap or its renderer's end do. Sent once after a task's
  // changes, and only when the set of the frames' renderer client ids
  // (cmux_shim_renderer_client_ids) differs from the one it last reported.
  CMUX_SHIM_FRAME_RENDERERS = 67,
} cmux_shim_event_kind_t;

typedef enum {
  CMUX_SHIM_SUGGESTIONS_SHOW = 0,
  CMUX_SHIM_SUGGESTIONS_SELECT = 1,
  CMUX_SHIM_SUGGESTIONS_HIDE = 2,
  CMUX_SHIM_SUGGESTIONS_ANNOUNCE = 3,
} cmux_shim_suggestion_event_t;

typedef enum {
  CMUX_SHIM_DEVTOOLS_SHOW = 1,        // open, or focus the open DevTools
  CMUX_SHIM_DEVTOOLS_CONSOLE = 2,     // Chromium's IDC_DEV_TOOLS_CONSOLE
  CMUX_SHIM_DEVTOOLS_INSPECT = 3,     // Chromium's IDC_DEV_TOOLS_INSPECT (element picker)
  CMUX_SHIM_DEVTOOLS_INSPECT_AT = 4,  // inspect the element at (x, y), view coordinates
  CMUX_SHIM_DEVTOOLS_CLOSE = 5,
} cmux_shim_devtools_command_t;


// Any thread. Swift moves it to the main run loop timer.
typedef void (*cmux_shim_schedule_fn)(void* ctx, int64_t delay_ms);
// CEF's next delayed work, from a fork with cmux_set_on_schedule_delayed
// (cmux_shim_set_schedule_delayed): run_time_ns is the earliest time it may
// run in CLOCK_UPTIME_RAW nanoseconds (Chromium's TimeTicks), INT64_MAX for
// none; leeway_ns how much later it may run; precise 1 when it has no leeway.
// It replaces schedule's delayed requests; "now" still comes through schedule.
// The CEF UI thread (the main thread); Swift handles any thread as for schedule.
typedef void (*cmux_shim_schedule_delayed_fn)(void* ctx, int64_t run_time_ns, int64_t leeway_ns, int precise);
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
// 0; x/y/width/height are valid when has_bounds (screen DIPs); user_gesture
// = 1 when a user gesture caused the request (a click, not a script); profile_path
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
                                           int user_gesture,
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
// Chromium's default search provider in every profile, incognito included,
// now and for profiles made later: template_url_json is
// default_search_provider_data.template_url_data as JSON (browser.searchEngine);
// NULL or "" restores Chromium's own default. UI thread.
CMUX_SHIM_EXPORT void cmux_shim_set_default_search(const char* template_url_json);
// Chrome enterprise policies Chromium reads natively (CefSettings.chrome_policy_id):
// a managed preference domain such as "com.google.Chrome", read the way Chrome
// reads it (forced values mandatory, others recommended). NULL or "" reads none.
// Call before cmux_shim_initialize; later calls do nothing.
// plans/cmux-next/chrome-enterprise-policy-DESIGN.md.
CMUX_SHIM_EXPORT void cmux_shim_set_chrome_policy_id(const char* policy_id);
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
// Fork API 17: browser_id's page is see-through (transparent 1): where the
// document draws no background of its own (and before its first paint) the
// parent view under the page window shows, as under a WebKit view that draws
// no background. 0 gives the page its background color back. Kept across
// navigations and tab moves. Returns 0 when the fork lacks the call.
CMUX_SHIM_EXPORT int cmux_shim_tab_set_transparent_background(int browser_id, int transparent);
// Fork API 26: layer hosting. enabled 1 moves browser_id's page pixels into
// a Core Animation context and returns its CAContextID (> 0), which the
// embedder shows with a CALayerHost in the parent view's layer tree; the page
// window stays as a transparent input target. 0 turns it off. Returns 0 when
// off, when the fork lacks the call, or when the browser has no page window.
// 1: file choosers come to the host as CMUX_SHIM_FILE_DIALOG (it must answer
// each); 0 (the default): Chromium shows its own panel. UI thread.
CMUX_SHIM_EXPORT void cmux_shim_set_file_dialogs(int enabled);
// Answers a CMUX_SHIM_FILE_DIALOG: `paths` are absolute paths, one per line
// (NULL or "" cancels); `multiple` 0 keeps only the first (open one, save).
// Returns 0 when the id is unknown or already answered. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_file_dialog_answer(int dialog_id, int multiple, const char* paths);
CMUX_SHIM_EXPORT unsigned int cmux_shim_browser_set_layer_hosting(int browser_id, int enabled);
// Fork API 27: how long (ms) a resize of browser_id's page window may hold
// this app's Core Animation commit for Chromium's frame at the new size; 0
// never holds it (the fork's default). Fork API 27 to 31 only: from API 32 a
// page window never holds the commit (the resize fence replaces it), so the
// shim makes no call and returns 0. Returns 0 when the fork lacks the call or
// the browser has no page window.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_resize_sync(int browser_id, int timeout_ms);
// Fork API 32 (cmux_browser_set_resize_fence; p03-rendering-042): browser_id's
// page shows its first frame at its new size in the same WindowServer update
// as the app's commit that resized its parent view, with no main-thread wait.
// The app makes fence_port (a send right name of this process) with
// -[CAContext createFencePort] on its window's context, holds that commit on
// it (-[CAContext setFencePort:]), calls this for each page the transaction
// resizes, in the same main-thread turn as the geometry change, and drops its
// own right after its commit. The fork takes its own send right and drops it
// after the commit that shows the page at the new size, at the deadline
// (deadline_frames display frames of the parent window's screen, at most 30;
// 0: after this turn's commit), or when the page hides, stops being layer
// hosted or closes; a busy or crashed renderer never holds it past the
// deadline. The app's right stays the app's. Returns 1 when the fork took its
// right; 0 for port 0, an unknown browser, a hidden page, a page with no
// context yet, or a fork without the call. In-process only: a port name means
// nothing in another process. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_resize_fence(int browser_id, unsigned int fence_port,
                                                        unsigned int deadline_frames);
// Fork API 34 (cmux_browser_set_embedder_visibility; p03-rendering-058): the
// app gives browser_id's layer-hosted page its window-level visibility, as
// Chrome's browser window gives its tabs theirs
// (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm), so the page
// window's order and macOS's occlusion no longer decide it: a page whose
// window never orders in keeps drawing while the app shows it.
typedef enum {
  // The page window's order and occlusion decide (the default).
  CMUX_SHIM_EMBEDDER_VISIBILITY_WINDOW = 0,
  // Visible: the page draws, ordered in or not.
  CMUX_SHIM_EMBEDDER_VISIBILITY_VISIBLE = 1,
  // Occluded: the page draws no frames and reads as hidden (after Chrome's
  // one second of coalescing), as a tab of a covered Chrome window.
  CMUX_SHIM_EMBEDDER_VISIBILITY_OCCLUDED = 2,
  // Hidden: the page's compositor is suspended and the page is hidden.
  CMUX_SHIM_EMBEDDER_VISIBILITY_HIDDEN = 3,
} cmux_shim_embedder_visibility_t;
// visibility is a cmux_shim_embedder_visibility_t; it applies while the page
// is layer hosted (kept across hosting off and on). While it is not WINDOW
// only the app changes the page's visibility (its parent view's hidden state
// does not), and the page window is the input target only. Returns 1, or 0
// for an unknown value or browser, a browser with no page window, or a fork
// without the call. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_embedder_visibility(int browser_id, int visibility);
// Fork API 36 (cmux_browser_attach_view; p03-rendering-044, Track B; 33 is
// p14-energy's, 34 p03-rendering-058's, 35 p03-rendering-056's): browser_id's
// page shows in parent_view (an NSView* of this process, in any app window)
// as Chromium's own views: its WebContentsViewCocoa fills parent_view, below
// its other subviews, and each RenderWidgetHostViewCocoa draws through its
// own layer tree. Input, IME, cursor, drag, popups and accessibility come
// from those views, and the page's visibility and active state follow
// parent_view and its window (and Chromium's active tab). The page window
// stays headless (never ordered in) while a tab of it is attached, also after
// the tab moved there from another window; layer hosting, detached hosting
// and the resize fence refuse the page then. parent_view NULL gives the tab
// back to its page window, which shows again once none of its tabs is
// attached (also after an attached tab closed or moved away). Returns 1, or 0
// for an unknown browser, a browser with no page window, or a fork without
// the call. In-process only: an NSView* means nothing in another process. UI
// thread.
CMUX_SHIM_EXPORT int cmux_shim_browser_attach_view(int browser_id, void* parent_view);
// Fork API 30: the helper-app browser process (plans/cmux-next/cef-helper-app-DESIGN.md).
// Each returns 0 (or does nothing) when the fork lacks the call; the fork's
// include/cef_cmux.h documents the semantics. UI thread only unless noted.
//
// Detached hosting: a layer-hosted page window that never orders in, visible
// to Chromium while the parent view shows; input only by forwarding.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_detached_hosting(int browser_id, int enabled);
// The key state of a detached page (page focus without a key window).
CMUX_SHIM_EXPORT int cmux_shim_browser_set_embedder_active(int browser_id, int active);
// Runs fn(context) on Chromium's UI thread from its user-input queue (highest
// priority). Any thread.
CMUX_SHIM_EXPORT int cmux_shim_post_user_input_task(void (*fn)(void* context), void* context);
// A wheel event with scroll and momentum phases (NSEventPhase-like values:
// 0 none, 1 may begin, 2 began, 3 changed, 4 ended, 5 cancelled); (x, y) in
// the page view's points, top left origin; (dx, dy) pixels as NSEvent
// scrollingDeltaX/Y; modifiers are cef_event_flags_t.
CMUX_SHIM_EXPORT int cmux_shim_browser_send_wheel(int browser_id, double x, double y, double dx, double dy,
                                                  int precise, int phase, int momentum_phase, int modifiers);
// Watches the page's text input state for an NSTextInputClient. `state`
// points at the fork's cmux_text_input_state_t (include/cef_cmux.h), valid
// only during the call. fn NULL stops the watch.
CMUX_SHIM_EXPORT int cmux_shim_browser_text_input_watch(int browser_id,
                                                        void (*fn)(void* context, int browser_id, const void* state),
                                                        void* context);
// The page view's remote accessibility token (returns its length; copies it
// when capacity is enough); sets the embedder's parent and window tokens.
CMUX_SHIM_EXPORT int cmux_shim_browser_accessibility_token(int browser_id, int embedder_pid,
                                                           const uint8_t* parent_token, int parent_token_length,
                                                           const uint8_t* window_token, int window_token_length,
                                                           uint8_t* out, int capacity);
// Page drags go to fn (the fork's cmux_drag_source_t) instead of an AppKit
// drag session; NULL restores Chromium's.
CMUX_SHIM_EXPORT void cmux_shim_set_drag_source_handler(void (*fn)(void* context, int browser_id, const void* drag),
                                                        void* context);
// Ends the page's drag with the destination's NSDragOperation.
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_source_ended(int browser_id, double x, double y, double screen_x,
                                                         double screen_y, int operation);
// The page's own drag came back over the page: a drop target drag with the
// page's data; continue with the DragTarget* calls.
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_target_enter_source(int browser_id, int x, int y,
                                                                int allowed_operations, int modifiers);
// A drag from outside the page is over it (Chrome's WebDragDest: enter, over,
// leave, drop; content/app_shim_remote_cocoa/web_drag_dest_mac.mm). x and y
// are page-view points from the top left; allowed_operations is the drag
// source's cef_drag_operations_mask_t; modifiers are cef_event_flags_t. The
// enter carries the drag's data: files (absolute paths), text, url and
// url_title, each NULL or empty when the drag has none. Each enter and over
// is answered by CMUX_SHIM_DRAG_OPERATION when the fork watches drags
// (API 31). A drop grants the page the dropped files, as a native drop does.
// Each returns 0 when the browser is gone.
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_target_enter(int browser_id, const char* const* files, int file_count,
                                                         const char* text, const char* url, const char* url_title,
                                                         int x, int y, int allowed_operations, int modifiers);
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_target_over(int browser_id, int x, int y, int allowed_operations,
                                                        int modifiers);
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_target_leave(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_browser_drag_target_drop(int browser_id, int x, int y, int modifiers);
// Suggestions as data (fork API 31, task p01-process-172): a field's
// autofill, password and <datalist> suggestions come as CMUX_SHIM_SUGGESTIONS
// events for every browser, new ones included, while enabled is 1, and
// Chromium's popup shows them again after 0. The field keeps Chrome's keys
// (arrows, Page Up and Down select; Return and Tab accept; Shift+Delete
// removes; Escape dismisses). Nothing changes with a fork below API 31. Any
// time, also before cmux_shim_initialize.
CMUX_SHIM_EXPORT void cmux_shim_set_suggestion_events(int enabled);
// The app's answer for the shown rows of token: SHOWN once they are on screen
// (Chrome takes an ACCEPT only 500 ms after it), SELECT the row under the
// pointer (-1 none: Chrome previews the row's values), ACCEPT a clicked row,
// REMOVE an autocomplete row's delete button, DISMISS a click outside. index
// is ignored for SHOWN and DISMISS. Returns 0 for a token that is not shown,
// an index outside the rows, or a refused ACCEPT or REMOVE (the fork's
// cmux_browser_suggestion_action).
typedef enum {
  CMUX_SHIM_SUGGESTION_SHOWN = 0,
  CMUX_SHIM_SUGGESTION_SELECT = 1,
  CMUX_SHIM_SUGGESTION_ACCEPT = 2,
  CMUX_SHIM_SUGGESTION_REMOVE = 3,
  CMUX_SHIM_SUGGESTION_DISMISS = 4,
} cmux_shim_suggestion_action_t;
CMUX_SHIM_EXPORT int cmux_shim_browser_suggestion_action(int browser_id, int64_t token, int action, int index);
// Fork API 31 (p01-process task 227): Chromium's own windows for these would
// open in the helper-app browser process, which has no visible window, so the
// app shows its own UI from data and answers by token. Each returns 0 when
// the fork lacks the call (cmux_shim_fork_api_version() < 31); the fork's
// include/cef_cmux.h documents the semantics. UI thread only.
//
// Each handler is one fn(context, event, ...) for all of its events; `data`
// points at the fork's struct (cef_cmux.h), valid only during the call. fn
// NULL removes the handler: Chromium's own UI shows again and the old
// handler's open requests end.
//
// <input type=color> (with --enable-blink-features=CmuxEmbedderColorChooser).
// Colors are 0xAARRGGBB. Answer with choose (any number of times: live
// updates) and close with end.
typedef enum {
  // A chooser opened for browser_id with the input's color; data is the
  // fork's cmux_color_chooser_t (its <datalist> suggestions).
  CMUX_SHIM_COLOR_CHOOSER_OPEN = 0,
  // The page set the input's value while open: show color (data NULL).
  CMUX_SHIM_COLOR_CHOOSER_SET_COLOR = 1,
  // The page side ended the chooser: close it. Not after
  // cmux_shim_color_chooser_end.
  CMUX_SHIM_COLOR_CHOOSER_END = 2,
} cmux_shim_color_chooser_event_t;
CMUX_SHIM_EXPORT int cmux_shim_set_color_chooser_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, unsigned int color, const void* data),
    void* context);
CMUX_SHIM_EXPORT int cmux_shim_color_chooser_choose(int64_t token, unsigned int color);
CMUX_SHIM_EXPORT int cmux_shim_color_chooser_end(int64_t token);
// Web Bluetooth, WebUSB, WebHID and Web Serial choosers. action is the fork's
// CMUX_DEVICE_CHOOSER_* (0 select, 1 cancel, 2 close, 3 rescan); choices are
// the selected rows' indices (one unless the chooser allows several). Returns
// 0 for an index below 0 or past INT_MAX, as the fork does for one past its
// rows.
typedef enum {
  // A chooser opened for browser_id, or its rows or state changed (same
  // token): data is the fork's whole cmux_device_chooser_t each time.
  CMUX_SHIM_DEVICE_CHOOSER_UPDATE = 0,
  // Chromium closed it (data NULL). Not after cmux's own answer.
  CMUX_SHIM_DEVICE_CHOOSER_CLOSE = 1,
} cmux_shim_device_chooser_event_t;
typedef struct {
  int64_t index;
} cmux_shim_device_choice;
CMUX_SHIM_EXPORT int cmux_shim_set_device_chooser_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, const void* data), void* context);
CMUX_SHIM_EXPORT int cmux_shim_device_chooser_answer(int64_t token, int action, const cmux_shim_device_choice* choices,
                                                     int choice_count);
// The screen-share picker of getDisplayMedia() and chrome.desktopCapture.
// source_type is one CMUX_DESKTOP_MEDIA_* bit (1 screen, 2 window, 4 tab,
// 8 current tab), or 0 to cancel; native_id is the CGDirectDisplayID (screen)
// or CGWindowID (window); tab_browser_id is the shared tab (tab; else 0).
// audio 1 shares audio when the page asked for it. Answer once.
typedef enum {
  // A picker opened for browser_id; data is the fork's
  // cmux_desktop_media_request_t (source types, preference, audio).
  CMUX_SHIM_DESKTOP_MEDIA_OPEN = 0,
  // Chromium dropped the request (data NULL). Not after cmux's answer.
  CMUX_SHIM_DESKTOP_MEDIA_CLOSE = 1,
} cmux_shim_desktop_media_event_t;
CMUX_SHIM_EXPORT int cmux_shim_set_desktop_media_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, const void* data), void* context);
CMUX_SHIM_EXPORT int cmux_shim_desktop_media_answer(int64_t token, int source_type, int64_t native_id,
                                                    int tab_browser_id, int audio);
// Pointer lock and keyboard lock: the app decides, hides and frees its own
// cursor and forwards the raw movement. Escape exits with by_user 1 (Chrome's
// 1.25 s cooldown for that page). detail: for KEYBOARD_LOCK_REQUESTED 1 when
// the lock also takes Escape (the app still exits on a held Escape, as Chrome
// does); for POINTER_LOCK_REQUESTED 1 when the page asked for unadjusted
// movement (requestPointerLock({unadjustedMovement: true}), the fork's next
// train; 0 before it); 0 otherwise.
typedef enum {
  // Answer with cmux_shim_browser_pointer_lock_answer.
  CMUX_SHIM_POINTER_LOCK_REQUESTED = 0,
  // The page's pointer lock ended: show and free the cursor.
  CMUX_SHIM_POINTER_UNLOCKED = 1,
  // Answer with cmux_shim_browser_keyboard_lock_answer.
  CMUX_SHIM_KEYBOARD_LOCK_REQUESTED = 2,
  // The keyboard lock ended: route reserved keys as usual again.
  CMUX_SHIM_KEYBOARD_UNLOCKED = 3,
} cmux_shim_lock_event_t;
CMUX_SHIM_EXPORT int cmux_shim_set_lock_handler(void (*fn)(void* context, int event, int browser_id, int detail),
                                                void* context);
CMUX_SHIM_EXPORT int cmux_shim_browser_pointer_lock_answer(int browser_id, int allowed);
CMUX_SHIM_EXPORT int cmux_shim_browser_keyboard_lock_answer(int browser_id, int allowed);
CMUX_SHIM_EXPORT int cmux_shim_browser_exit_pointer_lock(int browser_id, int by_user);
CMUX_SHIM_EXPORT int cmux_shim_browser_exit_keyboard_lock(int browser_id);
// Movement while the page holds the pointer lock: (dx, dy) in DIP as NSEvent
// deltaX/deltaY; modifiers are cef_event_flags_t with the held mouse buttons'
// bits (a drag while locked). Clicks go through the usual mouse calls.
CMUX_SHIM_EXPORT int cmux_shim_browser_send_locked_mouse_move(int browser_id, double dx, double dy, int modifiers);
// Places a detached page on display display_id (a CGDirectDisplayID): its
// window's frame origin is (screen_x, screen_y), the app's page view origin in
// AppKit screen points; the page takes that display's scale, color space and
// refresh rate. display_id 0 follows the parent view's window again.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_page_display(int browser_id, unsigned int display_id, double screen_x,
                                                        double screen_y);
// What the app shows of a detached page (cmux_browser_set_page_visibility),
// as Chrome's WebContentsViewCocoa gives its WebContents its visibility
// (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm). It applies to
// browser_id's Chromium window, every tab of it.
typedef enum {
  // Shown: the page draws.
  CMUX_SHIM_PAGE_VISIBLE = 0,
  // Not shown (its pane or workspace hidden, its view out of a window, its
  // window minimized, the app hidden): visibilityState "hidden", no frames.
  CMUX_SHIM_PAGE_HIDDEN = 1,
  // On screen but covered: Chromium's Visibility::OCCLUDED, one second later
  // as Chrome coalesces occlusion.
  CMUX_SHIM_PAGE_OCCLUDED = 2,
} cmux_shim_page_visibility_t;
// visibility is a cmux_shim_page_visibility_t. The fork takes it only while
// the page window is detached and makes the page visible again when it stops
// being detached. Returns 1, or 0 for a page that is not detached, an unknown
// value, or a fork without the call. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_browser_set_page_visibility(int browser_id, int visibility);
// Page state per history entry: entry `index`'s encoded page state (freed
// with cmux_shim_free; NULL for an unknown browser or index); a watch that
// calls fn(context, browser_id, index) when an entry commits or its page state
// changes (fn NULL removes it); and a restore of entries into a browser
// created with an empty URL that has not navigated, loading entry `current`.
// Entry strings are UTF-8 with explicit lengths; page_state_length 0 for none.
// Restore returns 1, 0 for an unknown browser, -1 when it has committed
// entries, -2 when a navigation could not be dropped, -3 for bad entries.
CMUX_SHIM_EXPORT char* cmux_shim_tab_entry_page_state(int browser_id, int index);
CMUX_SHIM_EXPORT int cmux_shim_tab_page_state_watch(int browser_id,
                                                    void (*fn)(void* context, int browser_id, int index),
                                                    void* context);
typedef struct {
  const char* url;
  size_t url_length;
  const char* title;
  size_t title_length;
  const char* page_state;
  size_t page_state_length;
} cmux_shim_restore_entry;
CMUX_SHIM_EXPORT int cmux_shim_tab_restore_entries(int browser_id, const cmux_shim_restore_entry* entries, int count,
                                                   int current);
// Fork API 31 (task p01-process-170): a detached page's IME. The four ops
// the page view's NSTextInputClient makes (Chrome's RenderWidgetHostViewCocoa
// calls on its RenderWidgetHostNSViewHost) are the shim's optional exports
// cmux_shim_browser_ime_set_composition, _commit_text, _finish_composing and
// _cancel_composition (plans/cmux-next/chromium-host-ops.json
// optional_exports, task p04-input-064's kIme layout: UTF-16LE text, 16-byte
// clauses); shim_helper_host.mm runs them on the fork's cmux_browser_ime_*.
//
// Watches the page's composition bounds for firstRectForCharacterRange:.
// `bounds` points at the fork's cmux_composition_bounds_t (include/cef_cmux.h:
// size, kind 1 range changed or 2 cancelled (discard the marked text), the
// composition range, one rect x, y, width, height per character in the page
// view's points, top left origin), valid only during the call. fn NULL stops
// the watch. Returns 0 when the fork is older than API 31.
CMUX_SHIM_EXPORT int cmux_shim_browser_composition_bounds_watch(int browser_id,
                                                                void (*fn)(void* context, int browser_id,
                                                                           const void* bounds),
                                                                void* context);
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
// CefInitialize with external_message_pump (schedule asks for
// cmux_shim_do_work); with schedule NULL there is no external pump and the
// caller runs CefRunMessageLoop (the Chromium Host). CONTEXT_INITIALIZED
// arrives before this returns. Returns 1 on success.
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
// Delayed pump work as absolute run times (schedule_delayed, with the ctx of
// cmux_shim_initialize) instead of whole milliseconds through schedule. Call
// before cmux_shim_initialize, in process only. Returns 1 when the fork has
// cmux_set_on_schedule_delayed (p14-energy-046), 0 otherwise: delayed work
// then stays on schedule. NULL goes back to schedule.
CMUX_SHIM_EXPORT int cmux_shim_set_schedule_delayed(cmux_shim_schedule_delayed_fn schedule_delayed);
// Energy Saver on (enabled 1) or off in Chromium (fork cmux_cef_set_energy_saver,
// p14-energy-029): frame sinks at 30 Hz, except pages of exempt_scheme
// (NULL = none) and sinks with input in the last second; wake-ups aligned to
// 32 ms; battery saver mode in every child process. Main thread, after
// cmux_shim_initialize. Returns 1 when the fork took it, 0 when the fork
// lacks the call (nothing changes).
CMUX_SHIM_EXPORT int cmux_shim_set_energy_saver(int enabled, const char* exempt_scheme);

// Creates a Chrome-style browser whose Chromium window tracks parent_view
// (NSView*). profile_cache_path selects a request context (NULL = global).
// AFTER_CREATED with `request` follows. Returns 1 if creation started.
CMUX_SHIM_EXPORT int cmux_shim_create_window(int request,
                            void* parent_view,
                            int width,
                            int height,
                            const char* url,
                            const char* profile_cache_path);
// The same window whose first tab is a renderer-less placeholder (fork
// CMUX_EXTRA_INFO_NO_RENDERER, p13-webui-017): no renderer process and no
// navigation, as Chrome makes restored tabs (browser_tabrestore.cc). Tabs
// added with cmux_shim_tab_add get a renderer when they load. AFTER_CREATED
// with `request` follows. Returns 1 if creation started, 0 when
// cmux_shim_placeholder_supported() is 0.
CMUX_SHIM_EXPORT int cmux_shim_create_placeholder_window(int request,
                            void* parent_view,
                            int width,
                            int height,
                            const char* profile_cache_path);
// 1 when the fork makes renderer-less placeholders (it exports
// cmux_tab_renderer_state; the fork train numbers it, p13-webui-086).
CMUX_SHIM_EXPORT int cmux_shim_placeholder_supported(void);
// Fork tab API; 0 on failure.
CMUX_SHIM_EXPORT int cmux_shim_tab_add(int window_browser_id, const char* url, int index, int activate);
// A user-owned copy of `browser_id`, added in the background to the window
// of `window_browser_id` at `index` (-1 = end) (cmux_tab_duplicate, fork
// API 16): same profile, back/forward history and a sessionStorage
// snapshot, its own BrowsingInstance, no opener, password filling on.
// OnAfterCreated runs before it returns. The copy's browser id, or 0 (also
// when the fork lacks the call).
CMUX_SHIM_EXPORT int cmux_shim_tab_duplicate(int browser_id, int window_browser_id, int index);
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
// Main thread, after the page left a Command or Control key down unhandled
// (CefKeyboardHandler::OnKeyEvent: no preventDefault). Return 1 when the host
// ran a shortcut it held back for the page (cmux Find after a page without
// its own); Chromium's own handling of the key then stops. Without a handler
// the key goes on to Chromium.
CMUX_SHIM_EXPORT void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn handler);
CMUX_SHIM_EXPORT void cmux_shim_set_zoom_level(int browser_id, double level);
// CefBrowserHost::SetAccessibilityState: 1 builds the page's accessibility tree (an assistive
// client asked for the app's), 0 turns it off.
CMUX_SHIM_EXPORT void cmux_shim_set_accessibility(int browser_id, int enabled);
// File > Print… (CefBrowserHost::Print): Chromium's print preview over the
// page, as the page's own window.print(). Returns 0 when the browser is gone.
CMUX_SHIM_EXPORT int cmux_shim_print(int browser_id);
// FIND_RESULT events carry `find_id`.
CMUX_SHIM_EXPORT void cmux_shim_find(int browser_id, int find_id, const char* text, int forward, int match_case, int find_next);
CMUX_SHIM_EXPORT void cmux_shim_stop_finding(int browser_id, int clear_selection);
// Closes the browser without asking: a beforeunload question is answered
// Leave (quit, a replaced page, a tab the daemon removed).
CMUX_SHIM_EXPORT void cmux_shim_close(int browser_id);
// A person's close (CefBrowserHost::TryCloseBrowser): returns 1 when the
// browser closes now without a question (or is gone), 0 when its
// beforeunload runs first. After 0 the page may ask (BEFORE_UNLOAD_DIALOG);
// BEFORE_CLOSE follows only if the close goes on, and nothing follows when
// the person stays. Calling it again while it waits is ignored by Chromium.
CMUX_SHIM_EXPORT int cmux_shim_try_close(int browser_id);
// Answers BEFORE_UNLOAD_DIALOG `token` (accept = 1: Leave or Reload).
// Returns 0 when the token is unknown or already answered.
CMUX_SHIM_EXPORT int cmux_shim_before_unload_reply(int token, int accept);
// DevTools protocol message ids. Raw sends (cmux_shim_devtools_send) and
// shim-internal calls (cmux_shim_devtools_call, the DevTools calls of a CEF
// tab) share ONE id space per browser. Raw sends use ids >= 2^30
// (1073741824) up to INT32_MAX; shim-internal calls use ids below 2^30,
// which the shim assigns.
//
// Runs a DevTools method in process; DEVTOOLS_RESULT carries the returned id
// (always below 2^30). Returns 0 when the browser is gone, params_json is not
// a JSON object, or the browser used up its internal ids.
CMUX_SHIM_EXPORT int cmux_shim_devtools_call(int browser_id, const char* method, const char* params_json);
// enabled != 0: DevTools protocol events of browser_id go to the host as
// CMUX_SHIM_DEVTOOLS_EVENT (raw JSON); 0 stops them. Events flow only for
// domains the host turned on (with cmux_shim_devtools_send or
// cmux_shim_devtools_call). Closing the browser stops them.
CMUX_SHIM_EXPORT void cmux_shim_devtools_watch_events(int browser_id, int enabled);
// Sends one raw DevTools protocol message (CefBrowserHost::
// SendDevToolsMessage): a JSON object with its own integer "id" >= 2^30
// (see the id rule above), "method", optional "params" and optional
// "sessionId". Its reply comes back as CMUX_SHIM_DEVTOOLS_EVENT. Returns 1
// when sent, 0 when the browser is gone, -1 when refused (not a JSON object,
// "id" missing, not an integer or below 2^30, or Chromium refused it).
CMUX_SHIM_EXPORT int cmux_shim_devtools_send(int browser_id, const char* message_json);

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
// Shows browser_id's DevTools on one panel or drawer view of its frontend
// ("network", "timeline", "heap-profiler", "rendering"; letters, digits
// and '-' only): opens DevTools when closed and selects the panel once its
// frontend has loaded (DevToolsAPI.showPanel). Returns 0 when browser_id is
// gone or panel is not a valid id.
CMUX_SHIM_EXPORT int cmux_shim_devtools_show_panel(int browser_id, const char* panel);

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
// DevTools device mode (fork API 24): the device's screen area the DevTools of
// browser_id (the inspected page) asks for, DIPs from the DevTools view's
// top-left corner. Returns 0 while device mode is off or on an older fork.
CMUX_SHIM_EXPORT int cmux_shim_devtools_inspected_bounds(int browser_id, int* x, int* y, int* width, int* height);
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
// chooses where each window request goes; without one the shim decides
// with the policy of cmux_shim_set_window_request_policy and reports each
// decision as CMUX_SHIM_WINDOW_REQUEST_RESULT. No-op on older forks.
CMUX_SHIM_EXPORT void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler);
// The policy the shim decides window requests with while no
// window_request_fn is installed (the Chromium Host, where cmux cannot
// answer inside Chromium's navigation), by the rule CEFWindowPolicy follows
// in process (CEFShim/src/window_request_policy.h). Until the first call
// no window has a store, so nothing opens in Chromium.
typedef enum {
  CMUX_SHIM_WINDOW_INSERT = 1,              // Chromium adds the tab to the anchor's window
  CMUX_SHIM_WINDOW_OPEN_IN_NEW_TAB = 2,     // no window of the store: cmux opens the URL
  CMUX_SHIM_WINDOW_LOAD_IN_SOURCE = 3,      // the requesting tab loads the URL
  CMUX_SHIM_WINDOW_DOWNLOAD_IN_SOURCE = 4,  // the requesting tab downloads the URL
  CMUX_SHIM_WINDOW_OFF_THE_RECORD = 5,      // cmux opens the URL in an incognito window
  CMUX_SHIM_WINDOW_REFUSE_NO_WINDOW = 6,    // an off-the-record store with no window: nothing opens
} cmux_shim_window_outcome_t;
// BrowserNewTabDisposition.
typedef enum {
  CMUX_SHIM_NEW_TAB_FOREGROUND = 0,
  CMUX_SHIM_NEW_TAB_BACKGROUND = 1,
  CMUX_SHIM_NEW_TAB_LINK_PLACEMENT = 2,
  CMUX_SHIM_NEW_TAB_POPUP = 3,
  CMUX_SHIM_NEW_TAB_NEW_WINDOW = 4,
} cmux_shim_new_tab_t;
// BrowserLinkAction: what a modified link click does.
typedef enum {
  CMUX_SHIM_LINK_CURRENT_TAB = 0,
  CMUX_SHIM_LINK_BACKGROUND_TAB = 1,
  CMUX_SHIM_LINK_FOREGROUND_TAB = 2,
  CMUX_SHIM_LINK_PLACEMENT = 3,
  CMUX_SHIM_LINK_NEW_WINDOW = 4,
  CMUX_SHIM_LINK_DOWNLOAD = 5,
} cmux_shim_link_action_t;
// BrowserLinkGesture.
typedef enum {
  CMUX_SHIM_GESTURE_PLAIN = 0,
  CMUX_SHIM_GESTURE_CMD = 1,
  CMUX_SHIM_GESTURE_CMD_SHIFT = 2,
  CMUX_SHIM_GESTURE_SHIFT = 3,
  CMUX_SHIM_GESTURE_OPTION = 4,
  CMUX_SHIM_GESTURE_MIDDLE = 5,
  CMUX_SHIM_GESTURE_MIDDLE_SHIFT = 6,
} cmux_shim_link_gesture_t;
// cmux_shim_window_policy_window.flags bits.
typedef enum {
  CMUX_SHIM_WINDOW_CANDIDATE = 1,             // a live pane window a request may go to (no popup panel, no spare)
  CMUX_SHIM_WINDOW_LAST_SHOWN = 2,            // the pane that showed a Chromium tab most recently
  CMUX_SHIM_WINDOW_VISIBLE = 4,               // the pane is on screen
  CMUX_SHIM_WINDOW_OFF_THE_RECORD_STORE = 8,  // the store is in memory only
} cmux_shim_window_flag_t;
// One pane window, by one of its tabs (the anchor). A popup panel names the
// anchor of its opener's pane (its requests go to that window), else 0.
// Swift writes the rows at these offsets: anchor_browser_id 0,
// opener_browser_id 8, flags 16, store 24, store_length 32 (40 bytes).
typedef struct {
  int64_t anchor_browser_id;
  int64_t opener_browser_id;
  int64_t flags;      // cmux_shim_window_flag_t bits
  const char* store;  // the pane's store as cmux compares it (CEFRuntime.storeKey)
  size_t store_length;
} cmux_shim_window_policy_window;
// The last left or middle mouse-up on a page: Chromium's dispositions do not
// carry the click's modifiers. uptime_ms is NSEvent.timestamp in ms
// (CLOCK_UPTIME_RAW). Offsets: browser_id 0, gesture 8, uptime_ms 16 (24 bytes).
typedef struct {
  int64_t browser_id;
  int64_t gesture;  // cmux_shim_link_gesture_t
  int64_t uptime_ms;
} cmux_shim_window_policy_click;
// windows sorted by anchor; profile_root = the normalized directory of
// cmux's persistent Profile-* stores; the five actions are cmux.json
// browser.links.* (cmux_shim_link_action_t). Replaces the previous policy.
CMUX_SHIM_EXPORT void cmux_shim_set_window_request_policy(const cmux_shim_window_policy_window* windows,
                                                          int window_count,
                                                          const cmux_shim_window_policy_click* clicks,
                                                          int click_count,
                                                          const char* profile_root,
                                                          int cmd_click,
                                                          int cmd_shift_click,
                                                          int shift_click,
                                                          int option_click,
                                                          int middle_click);
// Browsers (windows) Chromium created outside cmux and never showed since
// start (fork API 8); -1 on older forks.
CMUX_SHIM_EXPORT int cmux_shim_foreign_browser_count(void);

// Downloads (CefBrowserHost::StartDownload, CefDownloadHandler). Starts a
// download of url with browser_id's request context; DOWNLOAD_STARTED
// follows. Only http, https, data and blob URLs (never file:). Returns 0 when
// the browser is gone or the scheme is refused.
CMUX_SHIM_EXPORT int cmux_shim_download_url(int browser_id, const char* url);
// Answers DOWNLOAD_STARTED (download_id = its token): the download goes to
// path (no Chromium dialog); NULL or "" cancels it. Returns 0 when the
// download is not waiting.
CMUX_SHIM_EXPORT int cmux_shim_download_continue(int download_id, const char* path);
// command: 0 cancel, 1 pause, 2 resume (CefDownloadItemCallback). A cancel
// before the download's first update is held and applied then. Returns 0
// when the download is unknown or has finished, or for pause/resume before
// its first update.
CMUX_SHIM_EXPORT int cmux_shim_download_control(int download_id, int command);
// Answers PERMISSION_PROMPT (prompt_token = its token): result 1 allows,
// 2 denies (Chromium remembers both for the origin); any other value drops
// it unanswered (no dismissal is recorded; Chromium ends it with the page).
// Returns 0 when the prompt is not waiting.
CMUX_SHIM_EXPORT int cmux_shim_permission_continue(int prompt_token, int result);

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
// Stores value for url (0 = CEF_CONTENT_SETTING_VALUE_DEFAULT clears it);
// url "" sets the profile default (not for an incognito context). Returns 1
// when handed to CEF.
CMUX_SHIM_EXPORT int cmux_shim_set_content_setting(int browser_id, const char* url, const char* type, int value);
// Visits every cookie of the browser's request context. REPLY with `reply`
// follows, s1 = [{"name","domain","path"}]. Returns 0 when not started.
CMUX_SHIM_EXPORT int cmux_shim_visit_cookies(int browser_id, int reply);
// Deletes the host and domain cookies of url named name (every name when
// name is NULL or ""). REPLY with `reply` follows, a = deleted count.
CMUX_SHIM_EXPORT int cmux_shim_delete_cookies(int browser_id, int reply, const char* url, const char* name);
// Downloads the favicon at url through the browser's own request context
// (CefBrowserHost::DownloadImage as a favicon: the tab's cookies and
// profile), at most max_size pixels square. REPLY with `reply` follows:
// a = HTTP status (0 when the fetch failed), s1 = base64 PNG at 1x, or "".
// Returns 0 when the browser is gone, url is empty or max_size <= 0.
CMUX_SHIM_EXPORT int cmux_shim_download_favicon(int browser_id, int reply, const char* url, int max_size);
// Browser import: writes cookies into the request context of
// profile_cache_path (a persistent profile; an off-the-record key returns 0),
// creating the context when no tab opened it yet. json = [{"url","name",
// "value","domain","path","secure","httponly","same_site" (cef_cookie_same_site_t),
// "has_expires","expires","creation","last_access" (decimal strings,
// microseconds since 1601)}]. REPLY with `reply` and browser 0 follows once
// every cookie was handled: a = written, s1 = {"written","rejected"}.
// Returns 0 when nothing was started (bad path or JSON).
CMUX_SHIM_EXPORT int cmux_shim_import_cookies(const char* profile_cache_path, int reply, const char* json);
// Clear Browsing Data: deletes the cookies of profile_cache_path (a
// persistent profile; an off-the-record key returns 0) created at or after
// `since` (microseconds since 1601; 0 deletes every cookie), creating the
// context when no tab opened it yet. REPLY with `reply` and browser 0
// follows: a = cookies deleted. Returns 0 when nothing was started.
CMUX_SHIM_EXPORT int cmux_shim_clear_cookies(const char* profile_cache_path, int reply, int64_t since);
// Browser import: saved passwords into the Chromium password store of
// profile_cache_path (a persistent profile; an off-the-record key returns 0),
// the store autofill reads, encrypted with cmux's own Keychain key. Every
// field is UTF-8 with an explicit length (no terminator needed). The shim
// copies the entries before it returns, so the caller zeroes its buffers at
// once; the shim zeroes its copies when the store has taken them. Values are
// never logged. REPLY with `reply` and browser 0 follows: s1 = {"added",
// "duplicate","conflict","rejected"} (counts), plus "conflicts" (the indices
// of the conflicting entries) on API 20. Returns 0 when nothing was started
// (bad path, or the fork lacks cmux_password_import: API 15).
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
// Answers a PASSWORD_PROMPT: action 0 save, 1 update, 2 never for the site,
// 3 dismiss (cmux_password_prompt_action_t). `username` NULL keeps the
// submitted one. Returns 0 for a gone or answered prompt, or a fork without
// the prompt handler (API 20).
CMUX_SHIM_EXPORT int cmux_shim_password_prompt_answer(int prompt_id, int action, const char* username);
// Chromium suggests generated passwords without a Google account (fork API
// 20; Chromium's default needs sync). Still only where saving and filling
// are on. Returns 0 when the fork lacks it. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_set_password_generation_enabled(int enabled);
// 1 when an import reply lists the conflicting rows ("conflicts": indices
// into the entries) and those can be replaced (API 20).
CMUX_SHIM_EXPORT int cmux_shim_password_replace_available(void);
// Saves each entry's password over the saved one for its sign-in, the
// person's explicit choice for a conflict; never adds a sign-in. Replies
// {"updated","missing","rejected"} like cmux_shim_import_passwords does.
CMUX_SHIM_EXPORT int cmux_shim_replace_passwords(const char* profile_cache_path, int reply,
                                                 const cmux_shim_password_entry* entries, int count);
// Turns Chromium's password filling on or off in one tab. An agent-driven
// tab has it off: a page script could otherwise read a filled password
// after an automated click (plans/cmux-next/browser.md, "Secure sign-in").
// Returns 0 when the fork lacks cmux_tab_set_password_fill (API 15).
CMUX_SHIM_EXPORT int cmux_shim_set_password_fill(int browser_id, int enabled);
// Profile (Touch ID) passkeys of profile_cache_path (fork API 18,
// cmux_profile_passkeys_list / cmux_profile_passkey_delete; the Passwords
// page, plans/cmux-next/passwords.md 1.4). Metadata only, never key
// material. 1 when this fork has both calls.
CMUX_SHIM_EXPORT int cmux_shim_passkeys_available(void);
// REPLY with `reply` and browser 0 follows once the profile is initialized:
// a = 1 and s1 = the fork's JSON array [{"rp_id","credential_id" (base64url),
// "user_name","user_display_name"}], or a = 0 and s1 empty when the keychain
// could not be read. Returns 0 when nothing was started (bad path, an
// off-the-record key, or the fork lacks the call).
CMUX_SHIM_EXPORT int cmux_shim_passkeys_list(const char* profile_cache_path, int reply);
// Deletes one profile passkey by its credential id (base64url, as listed).
// REPLY with `reply` and browser 0 follows: a = 1 deleted, 0 not. Returns 0
// when nothing was started (as above, or an empty id).
CMUX_SHIM_EXPORT int cmux_shim_passkey_delete(const char* profile_cache_path, const char* credential_id, int reply);
// Password manager core (fork API 18: cmux_password_list, _remove,
// _exception_remove, _set_username, _reveal, _export; the Passwords page,
// plans/cmux-next/passwords.md 1.4). profile_cache_path is a persistent
// profile (an off-the-record key returns 0). Ids are the store's decimal
// primary keys, as listed. Each call returns 0 when nothing was started (bad
// input, or the fork lacks the call); otherwise exactly one REPLY (browser 0,
// request `reply`) follows on the main thread once the profile is
// initialized. Passwords never travel in a REPLY, a CEF value or a log line.
// 1 when this fork has all six calls.
CMUX_SHIM_EXPORT int cmux_shim_password_core_available(void);
// REPLY: a = 1 and s1 = the fork's JSON {"passwords":[{"id","site","url",
// "username","created","last_used" (ms since 1970, 0 = never),"times_used",
// "weak","reused"}],"exceptions":[{"id","site"}]} (metadata only), or a = 0.
CMUX_SHIM_EXPORT int cmux_shim_password_list(const char* profile_cache_path, int reply);
// Removes saved sign-ins by id. REPLY: a = removed count, or -1.
CMUX_SHIM_EXPORT int cmux_shim_password_remove(const char* profile_cache_path, const char* const* ids, int count, int reply);
// Removes one never-save site. REPLY: a = 1 removed, 0 not found, -1 failed.
CMUX_SHIM_EXPORT int cmux_shim_password_exception_remove(const char* profile_cache_path, const char* id, int reply);
// Changes one sign-in's username (UTF-8, may be empty). REPLY: a = 1 changed
// (or equal), 0 not found, -2 another sign-in of the site has it, -1 failed.
CMUX_SHIM_EXPORT int cmux_shim_password_set_username(const char* profile_cache_path, const char* id, const char* username,
                                                     int reply);
// One password for the native reveal sheet or the pasteboard, after the app
// authenticated the device owner. NOT a REPLY: `done` runs exactly once on
// the main thread with the UTF-8 bytes (not terminated) in a shim buffer that
// is valid only during the call and zeroed after it; NULL and 0 when the id
// is not found or the store failed. The app copies the bytes into SecretBytes
// inside `done`. Returns 0 (and never calls `done`) when nothing was started.
typedef void (*cmux_shim_password_reveal_fn)(void* ctx, const char* password, size_t length);
CMUX_SHIM_EXPORT int cmux_shim_password_reveal(const char* profile_cache_path, const char* id,
                                               cmux_shim_password_reveal_fn done, void* ctx);
// Writes every saved sign-in as Chrome's password CSV to the absolute
// file_path (the fork writes a 0600 temp file and renames it; a symlink is
// replaced, never followed). REPLY: a = sign-ins written, or -1.
CMUX_SHIM_EXPORT int cmux_shim_password_export(const char* profile_cache_path, const char* file_path, int reply);
// The visible entry's SSL status as JSON {"secure","certStatus",
// "contentStatus","sslVersion","url","chain":[base64 DER, leaf first]}, or
// NULL. Free with cmux_shim_free_owned.
CMUX_SHIM_EXPORT char* cmux_shim_ssl_status(int browser_id);
// Turns certificate warnings on again (Page Info "Turn on warnings"): clears
// every certificate error decision the user made in the browser's request
// context (CefRequestContext::ClearCertificateExceptions; CEF has no
// per-host call), then closes the context's connections (CloseAllConnections,
// as Chrome does) so the next load verifies the server again. REPLY with
// `reply` follows once both finished, a = 1. Returns 0 when not started.
CMUX_SHIM_EXPORT int cmux_shim_clear_certificate_exceptions(int browser_id, int reply);
// Proceed on the host's certificate warning page. Chromium fails a main-frame
// load with a certificate error (the host shows its warning) unless this was
// called for the browser, `host` and error `code` first: that error then
// continues (Chromium remembers it for the profile), or, with
// `chromium_decides`, goes to Chromium's own interstitial, which knows
// whether HSTS allows proceeding. Returns 0 when the browser is gone.
CMUX_SHIM_EXPORT int cmux_shim_certificate_proceed(int browser_id, const char* host, int code, int chromium_decides);
CMUX_SHIM_EXPORT void cmux_shim_free_owned(char* s);

// Renderer processes of a tab (resource hover cards). Writes at most
// `capacity` distinct renderer client ids (Chromium's RenderProcessHost id,
// the `--renderer-client-id=` switch of that renderer's helper process)
// that host a frame of browser_id: the main frame and every out-of-process
// iframe. Returns how many it wrote; 0 when the browser is gone.
CMUX_SHIM_EXPORT int cmux_shim_renderer_client_ids(int browser_id, int* out, int capacity);
// Every frame of every browser the shim holds, by browser and renderer
// (memory per hidden workspace, p09-observability-061): entry i says that
// browser_ids[i] has frame_counts[i] frames (the main frame and every
// iframe) in renderer client_ids[i] (as above). Covering every browser
// (tabs, popups, popup windows, spares, DevTools) gives each renderer's
// whole frame count. Stock CEF API only (CefBrowser::GetFrameIdentifiers);
// the app finds each renderer's pid from its helper's --renderer-client-id.
// Writes at most `capacity` entries and returns how many there are, which
// can be more; 0 in host mode.
CMUX_SHIM_EXPORT int cmux_shim_renderer_frames(int* browser_ids, int* client_ids, int* frame_counts, int capacity);
// The pid of the renderer process that hosts browser_id's main frame
// (p14-energy-124, the fork's cmux_cef_browser_renderer_pid); same-site
// tabs can share it. 0 while there is none (no renderer yet, gone, a
// renderer-less placeholder), for an unknown browser, on a fork without
// the call, and in host mode (the renderers are the host's children).
CMUX_SHIM_EXPORT int cmux_shim_renderer_pid(int browser_id);
// Remote localhost (plans/cmux-next/remote-localhost.md). Call before the
// first window with profile_cache_path each launch: that request context
// sends every request (loopback included) to the app's proxy at
// 127.0.0.1:port, which accepts only this app's processes. Returns 1 when
// stored.
CMUX_SHIM_EXPORT int cmux_shim_set_context_proxy(const char* profile_cache_path, int port);
// A browser profile's own proxy (#24432): profile_cache_path's request
// context uses exactly `server` ("http|https|socks5://host:port", one server,
// no credentials), bypassing the hosts of bypass_list (";"-separated, may be
// empty), with WebRTC UDP kept inside the proxy. A dead proxy fails closed:
// Chromium never falls back to direct. An empty server clears it (system
// proxy settings again). Applies to a context made earlier this launch now
// and to a later one when it initializes. Returns 1 when stored, 0 for an
// invalid server or a remote machine's context.
CMUX_SHIM_EXPORT int cmux_shim_set_context_proxy_server(const char* profile_cache_path, const char* server, const char* bypass_list);
// 2 applied to the request context, 1 pending (not initialized yet),
// 0 none, -1 Chromium refused the preference.
CMUX_SHIM_EXPORT int cmux_shim_context_proxy_state(const char* profile_cache_path);
// Drops the shim's request context for profile_cache_path. A key that starts
// with "cmux-otr:" names an off-the-record context (an empty cache path: a
// unique in-memory profile); Chromium destroys that profile, with all of its
// data, once no browser uses it.
CMUX_SHIM_EXPORT void cmux_shim_release_context(const char* profile_cache_path);
// Main-frame navigation guard of browser_id. mode is a bit set.
// Bits 0-1, the store (http(s) only): 0 unrestricted, 1 must stay loopback
// (a remote machine's store), 2 must not be loopback (a normal store in a
// remote workspace). A violation is cancelled and reported as
// NAVIGATION_REROUTE.
// Bit 2 (4), agent-driven tab: a main-frame navigation (redirects and
// history steps included) to a Chromium page is cancelled before commit,
// with no event; the tab stays on its page. Chromium pages: the schemes
// chrome, chrome-extension, chrome-untrusted, chrome-search, devtools,
// chrome-devtools and view-source; about: other than blank and srcdoc;
// blob: and filesystem: of those. The same rule as AgentURLPolicy.swift
// (plans/cmux-next/passwords.md, section 2).
CMUX_SHIM_EXPORT void cmux_shim_set_navigation_guard(int browser_id, int mode);
// The callback of a sign-in session (ASWebAuthenticationSession) that runs in
// browser_id: a custom scheme, or an https host and path (auth_callback_policy.h).
// A main-frame navigation (redirects included) to it is cancelled before it
// loads and reported as AUTH_CALLBACK. All empty or NULL clears it.
CMUX_SHIM_EXPORT void cmux_shim_set_auth_callback(int browser_id, const char* scheme, const char* https_host,
                                                  const char* https_path);

// Profile preferences (UI thread). Only these names are allowed:
// credentials_enable_service, credentials_enable_autosignin,
// autofill.profile_enabled, autofill.credit_card_enabled,
// password_manager.biometric_authentication_filling. A profile is known
// once its request context initialized this launch (a tab of that profile
// opened, or a cookie import created it); cmux_shim_release_context forgets
// it and its watches.
//
// JSON {"value": true|false|null, "modifiable": true|false} (value null when
// the preference is missing or not a boolean), freed with
// cmux_shim_free_owned; NULL for an unknown profile or a name not allowed.
CMUX_SHIM_EXPORT char* cmux_shim_pref_get(const char* profile_cache_path, const char* pref_name);
// 1 set; 0 not modifiable or name not allowed; -1 refused (unknown profile,
// or Chromium failed to set it).
CMUX_SHIM_EXPORT int cmux_shim_pref_set_bool(const char* profile_cache_path, const char* pref_name, int value);
// enabled != 0: CMUX_SHIM_PREF_CHANGED for every change of pref_name in the
// profile; 0 stops it. Returns 1 when done (also for a repeat), 0 for an
// unknown profile (enable only), a name not allowed, or a failed
// registration. Shutdown releases every watch.
CMUX_SHIM_EXPORT int cmux_shim_pref_watch(const char* profile_cache_path, const char* pref_name, int enabled);

// The chrome.bookmarks bridge (fork API 22, cmux_bookmarks_sync): makes
// Chromium's Bookmarks bar and Other bookmarks of the profile equal to
// tree_json ({"nodes": [...]}, pre-order). 1 applied; 0 the model is not
// loaded yet (CMUX_SHIM_BOOKMARKS_EVENT "loaded" follows); -1 refused, also
// when the engine has no bridge.
CMUX_SHIM_EXPORT int cmux_shim_bookmarks_sync(const char* profile_cache_path, const char* tree_json);

// cmux-page:// pages served from a folder. The scheme
// is registered at startup in every process (standard, secure,
// CORS-enabled, fetch-enabled). This call serves cmux-page://<id>/ from
// resource_root for every profile, also profiles opened later; a repeat
// replaces the folder and policy of that id. id is lowercased and must be
// [a-z0-9.-] (for example cmux.settings, cmux.history, cmux.apps,
// cmux.agent); the page origin is cmux-page://<id>. Reserved ids ("cmux"
// and every "cmux." id, PageID.isReserved in CmuxNextPages) are refused
// here: only cmux_shim_page_scheme_add_first_party serves them. Responses: GET only
// (else 405); the URL path resolves below resource_root (real paths,
// compared component-wise; ".." and symlink escapes are 404); "/" serves
// index.html; only .html .js .mjs .css .json .svg .wasm .woff .woff2 .ttf
// .otf, anything else 404. Every response has Content-Security-Policy = csp
// (NULL = "default-src 'self'") and X-Content-Type-Options: nosniff.
// Returns 1 when added, 0 for a bad or reserved id or a root that is not a
// directory.
CMUX_SHIM_EXPORT int cmux_shim_page_scheme_add(const char* id, const char* resource_root, const char* csp);
// The same for a reserved id only (0 for any other id): the app's
// first-party registration, which passes the page's bundled resource root
// after checking it against the first-party table (FirstPartyPageSchemes).
CMUX_SHIM_EXPORT int cmux_shim_page_scheme_add_first_party(const char* id, const char* resource_root, const char* csp);
// The same, and the page host answers every path whose first component
// (percent-decoded) is one of dynamic_prefixes (newline-separated, e.g.
// "__patch\nasset"); the folder never serves such a path. A request from a
// page in a browser emits CMUX_SHIM_PAGE_RESOURCE; any other is a 404.
// entry is the file "/" serves (NULL or empty = index.html; a plain file
// name, as diff-page.html for pages that share one build folder).
CMUX_SHIM_EXPORT int cmux_shim_page_scheme_add_first_party_dynamic(const char* id, const char* resource_root,
                                                                   const char* csp, const char* dynamic_prefixes,
                                                                   const char* entry);
// The page host's answer to CMUX_SHIM_PAGE_RESOURCE `token`: status (200,
// 404), mime (NULL = application/octet-stream) and length bytes of body,
// copied. The page's CSP and the other page headers are added. Any thread.
// Returns 1 when the request was waiting, 0 when it ended or was answered.
CMUX_SHIM_EXPORT int cmux_shim_page_resource_respond(int token, int status, const char* mime, const void* body,
                                                     size_t length);
// cmux's vote in Chromium's memory pressure aggregator (fork
// cmux_memory_pressure_vote, p07-memory-051): one voter next to Chromium's
// own platform voter (content/browser/browser_main_loop.cc
// CreateMemoryPressureMonitor); Chromium's listeners get the highest vote.
// level: 0 none (withdraws cmux's vote), 1 moderate, 2 critical. The fork
// calls MemoryPressureVoter::SetVote(level, /*notify_listeners=*/false), so
// Chromium's listeners run only when the aggregate level changes, and a
// kernel event that the platform voter also reports does not run them twice.
// Inside the call run only the sync listeners (async ones are posted tasks
// that run in later cmux_shim_do_work calls); in host library mode the call
// is one post to the Chromium Host. Main thread, after cmux_shim_initialize.
// Returns 1 when the fork took the vote, 0 when the fork lacks the call,
// for a level out of range, or once quit began (nothing changes).
CMUX_SHIM_EXPORT int cmux_shim_memory_pressure_vote(int level);
// 1: page cursors come to the host as CMUX_SHIM_CURSOR and tooltips as
// CMUX_SHIM_TOOLTIP, and Chromium sets no NSCursor and shows no tooltip of
// its own (the Chromium Host, whose page windows never show: the page view in
// cmux shows both). 0 (the default): Chromium shows them over its page
// window. UI thread.
CMUX_SHIM_EXPORT void cmux_shim_set_cursor_events(int enabled);
// Fork API 37 (cmux_tab_set_visibility; cmux p06-scheduler-212): the app
// gives browser_id's WebContents the visibility of its tab in cmux's
// visibility tree (window, workspace, pane, selected tab), as Chrome's tab
// strip hides a background tab (WebContentsImpl::UpdateWebContentsVisibility,
// content/public/browser/visibility.h). The value caps what the page window
// and its view ask for (the lower of the two applies), so Blink's hidden-page
// throttling and document.visibilityState follow the tab in the call's turn.
typedef enum {
  // No cap: the page window and its view decide (the default).
  CMUX_SHIM_TAB_VISIBILITY_VIEW = 0,
  CMUX_SHIM_TAB_VISIBILITY_VISIBLE = 1,
  // Occluded: the page draws no frames (Chrome's covered window).
  CMUX_SHIM_TAB_VISIBILITY_OCCLUDED = 2,
  // Hidden: the page is hidden (document.visibilityState 'hidden').
  CMUX_SHIM_TAB_VISIBILITY_HIDDEN = 3,
} cmux_shim_tab_visibility_t;
// A capture of the tab while cmux shows it nowhere, as
// WebContents::IncrementCapturerCount(stay_hidden): a screenshot, a
// screencast, the phone's browser host, screen share.
typedef enum {
  CMUX_SHIM_TAB_CAPTURE_NONE = 0,
  // The page keeps painting and stays hidden to script (kHiddenButPainting).
  CMUX_SHIM_TAB_CAPTURE_HIDDEN = 1,
  // The page paints and reads visible (a capturer that does not stay hidden).
  CMUX_SHIM_TAB_CAPTURE_VISIBLE = 2,
} cmux_shim_tab_capture_t;
// visibility is a cmux_shim_tab_visibility_t, capture a
// cmux_shim_tab_capture_t; the fork holds one capture per browser and
// replaces it on each call. Returns 1, or 0 for an unknown value or browser
// or a fork without the call. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_tab_set_visibility(int browser_id, int visibility, int capture);
// 1 when the fork loads built-in extensions at a profile's first tab
// (cmux_ext_load_command_line_async, p13-webui-055); ask before
// cmux_shim_initialize decides --load-extension.
CMUX_SHIM_EXPORT int cmux_shim_ext_load_later_supported(void);
// Loads the unpacked extension at `path` into the persistent profile of
// profile_cache_path as --load-extension does (command-line location, not
// loaded again at the next start), with the folder read off the UI thread;
// creates the context when no tab opened it yet. Replies once with
// CMUX_SHIM_REPLY (`reply`, a = 1: installed, its background page through its
// first load; 0: failed), never inside this call. Main thread, after
// cmux_shim_initialize. Returns 1 when the load started, 0 for an
// off-the-record key, an empty path or a fork without the call (no reply).
CMUX_SHIM_EXPORT int cmux_shim_ext_load_command_line(const char* profile_cache_path, int reply, const char* path);
// The page push channel (fork API 39, cmux_tab_page_push; p13-webui-079): `text` (UTF-8) to the
// receiver the browser's cmux-page document registered with cmuxPageListen, as data: no script runs
// for it and nothing answers. Pushes keep their order with each other and with the frame's scripts,
// and the renderer keeps them until the receiver registers or a frozen page runs again. Returns 1
// when sent, 0 for NULL text, an unknown browser, a page whose document is not a cmux-page one, or
// a fork without the call. UI thread.
CMUX_SHIM_EXPORT int cmux_shim_tab_page_push(int browser_id, const char* text);
// <select> popups (fork API 31's cmux_browser_set_popup_menu_handler, task
// p01-process-171). 1: every browser's popups, now and later, come to the
// host as CMUX_SHIM_POPUP_MENU, and Chromium shows no NSMenu of its own (the
// Chromium Host, which is never the active app: cmux shows the menu). 0 (the
// default): Chromium shows its own menu. Nothing changes without the fork
// call. UI thread.
CMUX_SHIM_EXPORT void cmux_shim_set_popup_menus(int enabled);
// Answers a CMUX_SHIM_POPUP_MENU of browser_id once: index = the chosen
// item, -1 when the menu closed with no choice (the page gets a change event
// for a choice, as with Chrome's menu). An item the page cannot take (a
// group label, a separator, a disabled option) closes the popup as -1 does.
// An answered or hidden token does nothing. UI thread.
CMUX_SHIM_EXPORT void cmux_shim_browser_popup_menu_reply(int browser_id, int64_t token, int index);

// Chromium tracing through stock CEF (include/cef_trace.h, CEFShim/src/shim_tracing.mm; task
// p09-observability-050). These are not cmux_shim_* exports, so the Chromium Host wire does not
// generate them: the host calls them for its TRACE_START and TRACE_STOP frames. Call begin and end
// on any thread after cmux_shim_initialize: each posts its work to the browser UI thread and
// returns 1, then its callback runs exactly once. It runs on the UI thread, also with a failure
// value that Chromium gives on another thread (the shim posts it back), except while CEF shuts
// down: then the failure value can come on any thread. A return of 0 means nothing was posted (CEF
// is not running, or a bad argument) and the callback never runs.
typedef void (*cmux_cef_trace_started_fn)(void* ctx, int ok);
typedef void (*cmux_cef_trace_written_fn)(void* ctx, const char* path);
// Starts recording in every Chromium process. categories is Chromium's category filter
// ("toplevel,cc,viz,gpu,input,benchmark,disabled-by-default-..."); NULL or "" uses CEF's default.
// CEF's API has no buffer size, so Chromium's record-until-full default applies.
// started: ok = 1 when every process records, 0 when CEF refused (a recording already runs).
CMUX_SHIM_EXPORT int cmux_cef_begin_tracing(const char* categories, cmux_cef_trace_started_fn started, void* ctx);
// Stops recording and writes the trace to path, an absolute path that ends in ".json" (0 for any
// other path). The file is Chromium's legacy JSON trace format: CEF's public API has only the JSON
// file endpoint (TracingController::CreateFileEndpoint), no Perfetto protobuf output.
// written: path when Chromium finished the recording, NULL when no recording ran or Chromium could
// not move its temporary file into place. The path does not prove the file: Chromium reports it also
// when it could not create the file (no directory, no write access) and ignores write errors (a full
// disk gives a cut file), so stat and parse it off the main thread before reporting success. After
// NULL, CEF can refuse every later begin until the app relaunches (its collecting_trace_data_ stays
// set). The string is valid only during the call.
CMUX_SHIM_EXPORT int cmux_cef_end_tracing(const char* path, cmux_cef_trace_written_fn written, void* ctx);
// Chromium's trace clock now, in microseconds (CefNowFromSystemTraceTime: base::TimeTicks, which
// is mach_absolute_time on macOS, the CLOCK_UPTIME_RAW clock). Any thread, after cmux_shim_load.
// The trace's "ts" values use this clock; sample it next to the caller's clock for the offset.
CMUX_SHIM_EXPORT int64_t cmux_cef_now_trace_us(void);

// The time slice of the next cmux_shim_do_work only, in microseconds (fork
// cmux_set_message_loop_time_slice, p03-rendering-116): that pass runs ready
// work for at most this long, clamped to 100 us and to the
// --cmux-pump-time-slice-us slice; 0 or less: the switch's slice. Main thread,
// in process only. Returns 1 when the fork has the call, 0 otherwise (every
// pass keeps the switch's slice).
CMUX_SHIM_EXPORT int cmux_shim_set_pump_time_slice(int64_t slice_us);

#ifdef __cplusplus
}
#endif

#endif  // CMUX_CEF_SHIM_H_
