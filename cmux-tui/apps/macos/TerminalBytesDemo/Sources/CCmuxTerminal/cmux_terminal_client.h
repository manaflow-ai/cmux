#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxTerminalClient CmuxTerminalClient;
typedef void (*CmuxTerminalClientUpdateCallback)(void *context);

CmuxTerminalClient *cmux_terminal_client_connect(
    const char *invitation_uri,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity);
CmuxTerminalClient *cmux_terminal_client_connect_with_timeout(
    const char *invitation_uri,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
bool cmux_terminal_client_attach(
    CmuxTerminalClient *client,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity);
void cmux_terminal_client_detach(CmuxTerminalClient *client);
void cmux_terminal_client_set_update_callback(
    const CmuxTerminalClient *client,
    CmuxTerminalClientUpdateCallback callback,
    void *context);
void cmux_terminal_client_disconnect(CmuxTerminalClient *client);
bool cmux_terminal_client_send(
    CmuxTerminalClient *client, const uint8_t *bytes, size_t length);
bool cmux_terminal_client_send_key(
    CmuxTerminalClient *client, const char *chord, bool repeat);
bool cmux_terminal_client_paste(
    CmuxTerminalClient *client, const uint8_t *bytes, size_t length);
bool cmux_terminal_client_resize(CmuxTerminalClient *client, uint16_t cols, uint16_t rows);
size_t cmux_terminal_client_copy_frame(
    const CmuxTerminalClient *client, char *buffer, size_t capacity);
size_t cmux_terminal_client_copy_diagnostics(
    const CmuxTerminalClient *client, char *buffer, size_t capacity);
bool cmux_terminal_client_has_exited(const CmuxTerminalClient *client);

#ifdef __cplusplus
}
#endif
