#ifndef OWL_FRESH_RUNTIME_SHIM_H
#define OWL_FRESH_RUNTIME_SHIM_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OwlShimSession OwlShimSession;
typedef struct { int kind; uint32_t context_id; int32_t host_pid; bool loading; const char *url; const char *title; const char *message; } OwlShimEvent;
typedef void (*OwlShimCallback)(const OwlShimEvent *, void *);
int owl_shim_open(const char *dylib_path);
void owl_shim_close(void);
int owl_shim_global_init(void);
OwlShimSession *owl_shim_session_create(const char *shell, const char *initial_url, const char *profile, OwlShimCallback callback, void *user_data);
void owl_shim_session_destroy(OwlShimSession *session);
int32_t owl_shim_session_host_pid(OwlShimSession *session);
int owl_shim_bind_all(OwlShimSession *session);
int owl_shim_navigate(OwlShimSession *session, const char *url);
int owl_shim_resize(OwlShimSession *session, uint32_t width, uint32_t height, float scale);
int owl_shim_focus(OwlShimSession *session, bool focused);
int owl_shim_mouse(OwlShimSession *session, uint32_t kind, float x, float y, uint32_t button, uint32_t click_count, float dx, float dy, uint32_t modifiers);
int owl_shim_key(OwlShimSession *session, bool down, uint32_t key_code, const char *text, uint32_t modifiers);
int owl_shim_eval(OwlShimSession *session, const char *script, char **result_json);
int owl_shim_surface_json(OwlShimSession *session, char **result_json);
int owl_shim_capture_surface_json(OwlShimSession *session, char **result_json);
void owl_shim_free(void *buffer);
void owl_shim_poll(uint32_t timeout_ms);
#ifdef __cplusplus
}
#endif
#endif
