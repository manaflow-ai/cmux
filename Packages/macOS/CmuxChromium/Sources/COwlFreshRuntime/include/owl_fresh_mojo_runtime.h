#ifndef FRESH_OWL_OWL_FRESH_MOJO_RUNTIME_H_
#define FRESH_OWL_OWL_FRESH_MOJO_RUNTIME_H_

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define OWL_FRESH_MOJO_EXPORT __attribute__((visibility("default")))
#else
#define OWL_FRESH_MOJO_EXPORT
#endif

typedef struct OwlFreshMojoSession OwlFreshMojoSession;

typedef enum OwlFreshMojoEventKind {
  kOwlFreshMojoEventLog = 1,
  kOwlFreshMojoEventReady = 2,
  kOwlFreshMojoEventCompositor = 3,
  kOwlFreshMojoEventNavigation = 4,
  kOwlFreshMojoEventDisconnected = 5,
  kOwlFreshMojoEventSurfaceTree = 6,
} OwlFreshMojoEventKind;

typedef struct OwlFreshMojoEvent {
  OwlFreshMojoEventKind kind;
  uint32_t context_id;
  int32_t host_pid;
  bool loading;
  const char* url;
  const char* title;
  const char* message;
} OwlFreshMojoEvent;

typedef void (*OwlFreshMojoEventCallback)(const OwlFreshMojoEvent* event,
                                          void* user_data);

OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_global_init(void);
OWL_FRESH_MOJO_EXPORT OwlFreshMojoSession* owl_fresh_mojo_session_create(
    const char* content_shell_path,
    const char* initial_url,
    const char* user_data_dir,
    OwlFreshMojoEventCallback callback,
    void* user_data);
OWL_FRESH_MOJO_EXPORT OwlFreshMojoSession*
owl_fresh_mojo_session_create_with_proxy(const char* content_shell_path,
                                         const char* initial_url,
                                         const char* user_data_dir,
                                         const char* proxy_server,
                                         OwlFreshMojoEventCallback callback,
                                         void* user_data);
OWL_FRESH_MOJO_EXPORT void owl_fresh_mojo_session_destroy(
    OwlFreshMojoSession* session);
OWL_FRESH_MOJO_EXPORT int32_t owl_fresh_mojo_session_host_pid(
    OwlFreshMojoSession* session);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_shell_execute_javascript(
    OwlFreshMojoSession* session,
    const char* script,
    char** result_json,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_set_client(
    OwlFreshMojoSession* session,
    uint64_t client_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_bind_profile(
    OwlFreshMojoSession* session,
    uint64_t profile_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_bind_web_view(
    OwlFreshMojoSession* session,
    uint64_t web_view_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_bind_input(
    OwlFreshMojoSession* session,
    uint64_t input_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_bind_surface_tree(
    OwlFreshMojoSession* session,
    uint64_t surface_tree_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int
owl_fresh_mojo_session_bind_native_surface_host(
    OwlFreshMojoSession* session,
    uint64_t native_surface_host_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_bind_devtools_host(
    OwlFreshMojoSession* session,
    uint64_t devtools_host_handle,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_session_flush(
    OwlFreshMojoSession* session,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_profile_get_path(
    OwlFreshMojoSession* session,
    char** path,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_web_view_navigate(
    OwlFreshMojoSession* session,
    const char* url,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_web_view_resize(
    OwlFreshMojoSession* session,
    uint32_t width,
    uint32_t height,
    float scale,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_web_view_set_focus(
    OwlFreshMojoSession* session,
    bool focused,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_input_send_mouse(
    OwlFreshMojoSession* session,
    uint32_t kind,
    float x,
    float y,
    uint32_t button,
    uint32_t click_count,
    float delta_x,
    float delta_y,
    uint32_t modifiers,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_input_send_key(
    OwlFreshMojoSession* session,
    bool key_down,
    uint32_t key_code,
    const char* text,
    uint32_t modifiers,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_surface_tree_capture_surface_json(
    OwlFreshMojoSession* session,
    char** result_json,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_surface_tree_get_json(
    OwlFreshMojoSession* session,
    char** result_json,
    char** error);
OWL_FRESH_MOJO_EXPORT int
owl_fresh_mojo_native_surface_accept_active_popup_menu_item(
    OwlFreshMojoSession* session,
    uint32_t index,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int
owl_fresh_mojo_native_surface_cancel_active_popup(OwlFreshMojoSession* session,
                                                  bool* ok,
                                                  char** error);
OWL_FRESH_MOJO_EXPORT int
owl_fresh_mojo_native_surface_select_active_file_picker_files_json(
    OwlFreshMojoSession* session,
    const char* paths_json,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int
owl_fresh_mojo_native_surface_cancel_active_file_picker(
    OwlFreshMojoSession* session,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_devtools_open(
    OwlFreshMojoSession* session,
    uint32_t mode,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_devtools_close(
    OwlFreshMojoSession* session,
    bool* ok,
    char** error);
OWL_FRESH_MOJO_EXPORT int owl_fresh_mojo_devtools_evaluate_javascript(
    OwlFreshMojoSession* session,
    const char* script,
    char** result_json,
    char** error);
OWL_FRESH_MOJO_EXPORT void owl_fresh_mojo_poll_events(uint32_t timeout_ms);
OWL_FRESH_MOJO_EXPORT void owl_fresh_mojo_free_buffer(void* buffer);

#ifdef __cplusplus
}
#endif

#endif  // FRESH_OWL_OWL_FRESH_MOJO_RUNTIME_H_
