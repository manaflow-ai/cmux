// C ABI between CmuxNextBrowser (Swift) and libcmux_cef_shim.dylib (C++ over
// the CEF wrapper of the pinned artifact, scripts/cmux-next/cef-manifest.json).
//
// The Swift side never includes this header: it resolves these functions with
// dlsym after it dlopens the shim on the first CEF tab, and mirrors the types
// in CEFShimLibrary.swift. Bump CMUX_CEF_SHIM_ABI on any change and update
// both sides together.
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

#define CMUX_CEF_SHIM_ABI 5

#define CMUX_SHIM_EXPORT __attribute__((visibility("default")))

typedef enum {
  CMUX_SHIM_CONTEXT_INITIALIZED = 1,
  // browser_id created; request = token passed to create_window (0 when
  // Chromium created the tab itself); a = Chromium window id.
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
} cmux_shim_event_kind_t;


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


CMUX_SHIM_EXPORT int cmux_shim_abi_version(void);

// Loads the framework (dlopen) and binds the fork API. Returns 1 on success;
// on failure writes a message into err.
CMUX_SHIM_EXPORT int cmux_shim_load(const char* framework_binary, char* err, size_t err_len);
// cmux_cef_api_version() of the fork, or 0 for stock CEF.
CMUX_SHIM_EXPORT int cmux_shim_fork_api_version(void);
// Turns on extensions.ui.developer_mode in every profile the shim creates.
// Chromium disables unpacked (--load-extension) extensions without it.
// Development and verification only; call before cmux_shim_initialize.
CMUX_SHIM_EXPORT void cmux_shim_set_extension_developer_mode(int enabled);
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
CMUX_SHIM_EXPORT int cmux_shim_tab_window_id(int browser_id);

CMUX_SHIM_EXPORT void cmux_shim_load_url(int browser_id, const char* url);
CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_go_forward(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_reload(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_stop(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_set_focus(int browser_id, int focus);
CMUX_SHIM_EXPORT void cmux_shim_set_zoom_level(int browser_id, double level);
// FIND_RESULT events carry `find_id`.
CMUX_SHIM_EXPORT void cmux_shim_find(int browser_id, int find_id, const char* text, int forward, int match_case, int find_next);
CMUX_SHIM_EXPORT void cmux_shim_stop_finding(int browser_id, int clear_selection);
CMUX_SHIM_EXPORT void cmux_shim_show_devtools(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_close(int browser_id);
// Runs a DevTools method in process; DEVTOOLS_RESULT carries the returned id.
// Returns 0 when the browser is gone or params_json is not a JSON object.
CMUX_SHIM_EXPORT int cmux_shim_devtools_call(int browser_id, const char* method, const char* params_json);

// Extension actions (fork API v1). Returned strings are freed with
// cmux_shim_free.
CMUX_SHIM_EXPORT char* cmux_shim_ext_actions(int browser_id, int icon_px);
CMUX_SHIM_EXPORT int cmux_shim_ext_action_run(int browser_id, const char* extension_id, int x, int width);
CMUX_SHIM_EXPORT void cmux_shim_ext_action_hide_popup(int browser_id, const char* extension_id);
CMUX_SHIM_EXPORT void cmux_shim_ext_action_context_menu(int browser_id, const char* extension_id, int screen_x, int screen_y);
CMUX_SHIM_EXPORT void cmux_shim_free(char* s);

// Extension management and commands (fork API v3; 0/NULL on older forks).
CMUX_SHIM_EXPORT char* cmux_shim_ext_list(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_set_enabled(int browser_id, const char* extension_id, int enabled);
CMUX_SHIM_EXPORT int cmux_shim_ext_uninstall(int browser_id, const char* extension_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_set_pinned(int browser_id, const char* extension_id, int pinned);
CMUX_SHIM_EXPORT int cmux_shim_ext_open_options(int browser_id, const char* extension_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_load_unpacked(int browser_id, const char* path);
CMUX_SHIM_EXPORT char* cmux_shim_ext_commands(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_ext_command_run(int browser_id, const char* extension_id, const char* command);
CMUX_SHIM_EXPORT int cmux_shim_tab_move_to_window(int browser_id, int window_browser_id, int index);
// Ends a CONTEXT_MENU: command_id < 0 cancels.
CMUX_SHIM_EXPORT void cmux_shim_context_menu_done(int token, int command_id, int event_flags);

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
// The visible entry's SSL status as JSON {"secure","certStatus",
// "contentStatus","sslVersion","url","chain":[base64 DER, leaf first]}, or
// NULL. Free with cmux_shim_free_owned.
CMUX_SHIM_EXPORT char* cmux_shim_ssl_status(int browser_id);
CMUX_SHIM_EXPORT void cmux_shim_free_owned(char* s);

#ifdef __cplusplus
}
#endif

#endif  // CMUX_CEF_SHIM_H_
