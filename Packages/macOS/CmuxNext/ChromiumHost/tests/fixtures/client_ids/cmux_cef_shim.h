// A fixture shim header for host_client_ids_dispatch_test.cpp: the mint exports
// and one post of the real header (Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h),
// with the real event values, so gen-chromium-host-wire.py generates real host
// cases for them without the whole shim.
#define CMUX_SHIM_EXPORT __attribute__((visibility("default")))
typedef enum {
  CMUX_SHIM_CONTEXT_INITIALIZED = 1,
  CMUX_SHIM_AFTER_CREATED = 2,
  CMUX_SHIM_BEFORE_CLOSE = 3,
  CMUX_SHIM_TITLE = 5,
  CMUX_SHIM_DEVTOOLS_RESULT = 13,
  CMUX_SHIM_DEVTOOLS_OPENED = 21,
  CMUX_SHIM_DEVTOOLS_CLOSED = 22,
} cmux_shim_event_kind_t;
typedef void (*cmux_shim_event_fn)(void* ctx, int kind, int browser_id, int request, int64_t a, int64_t b,
                                   const char* s1, const char* s2);
CMUX_SHIM_EXPORT const char* cmux_shim_abi_id(void);
CMUX_SHIM_EXPORT int cmux_shim_initialize(void* ctx, cmux_shim_event_fn event);
CMUX_SHIM_EXPORT int cmux_shim_create_window(int request, const char* url);
CMUX_SHIM_EXPORT int cmux_shim_tab_add(int window_browser_id, const char* url, int index, int activate);
CMUX_SHIM_EXPORT int cmux_shim_tab_duplicate(int browser_id, int window_browser_id, int index);
CMUX_SHIM_EXPORT void cmux_shim_load_url(int browser_id, const char* url);
CMUX_SHIM_EXPORT int cmux_shim_devtools_call(int browser_id, const char* method, const char* params_json);
