// C interface between Swift and the dynamically loaded CEF framework.
//
// The shim owns every direct CEF C-API interaction: framework loading,
// initialization with an external message pump, per-pane chrome-style
// browser windows, navigation, and DevTools protocol messaging. Swift sees
// opaque handles and plain C callbacks; no CEF types cross this boundary.
//
// Threading: every function must be called on the main thread, and every
// callback is delivered on the main thread (CEF's UI thread is the process
// main thread in external-message-pump mode).
#ifndef CMUX_CEF_SHIM_H_
#define CMUX_CEF_SHIM_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmux_cef_browser cmux_cef_browser_t;

/// Host-provided callbacks for one browser. `context` is echoed unchanged.
typedef struct {
  void *context;
  /// The browser finished creating; `ns_window` is the NSWindow* hosting it.
  void (*on_created)(void *context, void *ns_window);
  /// The browser is gone; release any references to the handle afterwards.
  void (*on_closed)(void *context);
  void (*on_title_changed)(void *context, const char *title);
  void (*on_address_changed)(void *context, const char *url);
  void (*on_loading_state_changed)(void *context, int is_loading,
                                   int can_go_back, int can_go_forward);
  /// One complete DevTools protocol message (method result or event), UTF-8 JSON.
  void (*on_dev_tools_message)(void *context, const void *bytes, size_t length);
} cmux_cef_browser_callbacks_t;

/// Global initialization options.
typedef struct {
  /// Absolute path to the cmux-owned CEF cache root. Required.
  const char *root_cache_path;
  /// Newline-separated absolute paths of unpacked extension directories, or NULL.
  const char *extension_directories;
  /// Loopback CDP listener port, or 0 to disable the external endpoint.
  int remote_debugging_port;
  /// Directory containing "Chromium Embedded Framework.framework", or NULL to
  /// use the main bundle's Frameworks directory.
  const char *framework_directory;
  /// Absolute path for the CEF debug log, or NULL.
  const char *log_file_path;
} cmux_cef_init_options_t;

/// Loads the CEF framework's code without initializing CEF. Chromium's
/// allocator shim installs itself from static initializers at load time and
/// must own the malloc zone before the process allocates in earnest, so call
/// this as the process's first act. Returns 1 when the framework is loaded.
/// Passing NULL uses the main bundle's Frameworks directory.
int cmux_cef_preload_framework(const char *framework_directory);

/// Initializes CEF (loading the framework first when preload was skipped).
/// Returns 1 on success. Safe to call once per process; subsequent calls
/// return the first result.
int cmux_cef_initialize(const cmux_cef_init_options_t *options);

/// Returns 1 once cmux_cef_initialize has succeeded.
int cmux_cef_is_initialized(void);

/// Returns the loopback CDP port captured by the successful process-wide
/// initialization, or 0 when the external endpoint is disabled.
int cmux_cef_remote_debugging_port(void);

/// Registers the host's message-pump scheduler. CEF asks the host to call
/// cmux_cef_do_work after `delay_ms` (0 means as soon as possible). The
/// callback may be invoked from any thread.
void cmux_cef_set_schedule_work_callback(void (*schedule)(int64_t delay_ms));

/// Performs one iteration of CEF message-loop work. Main thread only.
void cmux_cef_do_work(void);

/// Creates a chrome-style browser in its own frameless CEF window. The
/// returned handle is owned by the caller; release with
/// cmux_cef_browser_release after on_closed. Returns NULL on failure.
/// `cache_path` must be equal to or below the root cache path, or NULL for
/// the global context.
cmux_cef_browser_t *cmux_cef_browser_create(
    const char *url,
    const char *cache_path,
    const cmux_cef_browser_callbacks_t *callbacks);

/// Requests asynchronous close; on_closed fires when torn down.
void cmux_cef_browser_close(cmux_cef_browser_t *browser);

/// Releases the caller's reference.
void cmux_cef_browser_release(cmux_cef_browser_t *browser);

void cmux_cef_browser_load_url(cmux_cef_browser_t *browser, const char *url);
void cmux_cef_browser_go_back(cmux_cef_browser_t *browser);
void cmux_cef_browser_go_forward(cmux_cef_browser_t *browser);
void cmux_cef_browser_reload(cmux_cef_browser_t *browser);
void cmux_cef_browser_stop(cmux_cef_browser_t *browser);

/// Sends one DevTools protocol command (UTF-8 JSON with "id", "method",
/// optional "params"). Responses arrive via on_dev_tools_message. Returns 1
/// when submitted.
int cmux_cef_browser_send_dev_tools_message(cmux_cef_browser_t *browser,
                                            const void *json,
                                            size_t length);

#ifdef __cplusplus
}
#endif

#endif  // CMUX_CEF_SHIM_H_
