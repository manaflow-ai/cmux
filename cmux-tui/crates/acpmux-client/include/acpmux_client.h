/* C ABI for acpmux-client. Generated declarations are kept small and stable. */
#ifndef ACPMUX_CLIENT_H
#define ACPMUX_CLIENT_H
#include <stddef.h>
#include <stdint.h>
typedef struct acpmux_client_bytes { uint8_t *ptr; size_t len; } acpmux_client_bytes;
uint32_t acpmux_client_abi_version(void);
void *acpmux_client_new(void);
int32_t acpmux_client_connected(void *handle);
int32_t acpmux_client_disconnected(void *handle);
int32_t acpmux_client_received(void *handle, const uint8_t *ptr, size_t len, size_t *consumed);
int32_t acpmux_client_take_send(void *handle, acpmux_client_bytes *out);
int32_t acpmux_client_next_change(void *handle, acpmux_client_bytes *out);
void acpmux_client_bytes_free(acpmux_client_bytes bytes);
void acpmux_client_free(void *handle);
#endif
