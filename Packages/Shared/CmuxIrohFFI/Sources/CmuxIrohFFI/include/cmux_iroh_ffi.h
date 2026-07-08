// Minimal blocking C FFI over iroh for the cmux mobile transport.
// See native/cmux-iroh/src/lib.rs for semantics. All calls block; call off
// the main thread. Hand-maintained: keep in sync with lib.rs.

#ifndef CMUX_IROH_FFI_H
#define CMUX_IROH_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles. The pointer values are keys into a process-global registry,
// never real addresses: in-flight blocking calls hold their own reference to
// the underlying object, so closing a handle from another thread can never
// free memory a blocked call still uses (it wakes blocked calls instead).
// Calls on a closed/unknown handle report CMUX_IROH_ERROR_INVALID_ARGUMENT;
// close on a closed/unknown handle is a no-op.
typedef struct CmuxIrohEndpoint CmuxIrohEndpoint;
typedef struct CmuxIrohConnection CmuxIrohConnection;

// Length in bytes of an iroh (Ed25519) secret key.
#define CMUX_IROH_SECRET_KEY_LEN 32

// Stable error classification, written to the `err_kind` out-param of every
// fallible call (when non-null). Values are ABI: new kinds are appended,
// never renumbered. Mirrors CmuxIrohErrorKind in lib.rs.
typedef enum CmuxIrohErrorKind {
    CMUX_IROH_ERROR_NONE = 0,
    CMUX_IROH_ERROR_INVALID_ARGUMENT = 1,
    CMUX_IROH_ERROR_BIND_FAILED = 2,
    CMUX_IROH_ERROR_TIMEOUT = 3,
    CMUX_IROH_ERROR_CONNECT_FAILED = 4,
    CMUX_IROH_ERROR_ENDPOINT_CLOSED = 5,
    CMUX_IROH_ERROR_CONNECTION_LOST = 6,
    CMUX_IROH_ERROR_STREAM_FAILED = 7,
    CMUX_IROH_ERROR_INTERNAL = 8,
} CmuxIrohErrorKind;

// Generates a fresh Ed25519 secret key into the caller's buffer (Keychain
// custody lives with the caller; the library keeps no copy). Returns 0 on
// success, -1 if out_key is null or out_key_cap < CMUX_IROH_SECRET_KEY_LEN.
int cmux_iroh_secret_key_generate(uint8_t *out_key, size_t out_key_cap);

// Derives the z-base-32 EndpointId (public key) for a secret key without
// binding. Returns a heap string to free with cmux_iroh_string_free, or null
// if the key is null/not 32 bytes.
char *cmux_iroh_secret_key_endpoint_id(
    const uint8_t *secret_key,
    size_t secret_key_len);

// Binds an iroh endpoint with the caller-provided 32-byte secret key and a
// choice of relay map:
//   - enable_relay == false: no relay (LAN/direct only).
//   - enable_relay == true, relay_url null/empty: the default n0 relay fleet
//     (cmux-hosted iroh).
//   - enable_relay == true, relay_url set: a custom single-relay map (the
//     user's own iroh-relay). A malformed relay_url fails with InvalidArgument.
// relay_url, when non-null, must be a NUL-terminated C string. Returns null on
// failure with the cause in the error out-params.
CmuxIrohEndpoint *cmux_iroh_endpoint_bind(
    const uint8_t *secret_key,
    size_t secret_key_len,
    bool enable_relay,
    const char *relay_url,
    bool accept_connections,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Binds an endpoint with relays enabled as requested but with all local IP
// transports removed. Pair with cmux_iroh_endpoint_connect_relay_only for
// DEBUG/simulator relay-path verification; the default bind/connect APIs keep
// direct+relay behavior.
CmuxIrohEndpoint *cmux_iroh_endpoint_bind_relay_only(
    const uint8_t *secret_key,
    size_t secret_key_len,
    bool enable_relay,
    const char *relay_url,
    bool accept_connections,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Returns the endpoint's EndpointId (z-base-32) as a heap string.
// Free with cmux_iroh_string_free.
char *cmux_iroh_endpoint_id(const CmuxIrohEndpoint *endpoint);

// Returns a CmxAttachRoute-shaped JSON object for this endpoint (id, direct
// addrs, relay URL). Free with cmux_iroh_string_free.
char *cmux_iroh_endpoint_route_json(const CmuxIrohEndpoint *endpoint);

// Waits until the endpoint has a home relay connection. 0 on success, -1 on
// failure/timeout. timeout_ms == 0 waits indefinitely (close unblocks it).
int cmux_iroh_endpoint_online(
    CmuxIrohEndpoint *endpoint,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Accepts one incoming connection and its first bidirectional stream.
// Blocks up to timeout_ms; timeout_ms == 0 blocks indefinitely. Returns null
// on failure/timeout. cmux_iroh_endpoint_close from another thread wakes a
// blocked accept, which then reports CMUX_IROH_ERROR_ENDPOINT_CLOSED.
CmuxIrohConnection *cmux_iroh_endpoint_accept(
    CmuxIrohEndpoint *endpoint,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Dials endpoint_id (optionally with relay URL / direct addr hints) and opens
// one bidirectional stream. With no hints, n0 discovery resolves the id.
// timeout_ms == 0 blocks indefinitely (close unblocks it). Null or invalid
// direct_addrs entries fail fast as CMUX_IROH_ERROR_INVALID_ARGUMENT.
CmuxIrohConnection *cmux_iroh_endpoint_connect(
    CmuxIrohEndpoint *endpoint,
    const char *endpoint_id,
    const char *relay_url,
    const char *const *direct_addrs,
    size_t direct_addr_count,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Dials endpoint_id using relay_url only, ignoring direct_addrs. relay_url is
// required; an id-only dial would fall back to discovery and could learn direct
// addresses. Use with cmux_iroh_endpoint_bind_relay_only on the local dialer
// endpoint to prevent later LAN/loopback path creation.
CmuxIrohConnection *cmux_iroh_endpoint_connect_relay_only(
    CmuxIrohEndpoint *endpoint,
    const char *endpoint_id,
    const char *relay_url,
    const char *const *direct_addrs,
    size_t direct_addr_count,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Returns the current iroh transport path type for a live connection:
// 0 = none/unknown, 1 = relay, 2 = direct IP, 3 = mixed relay+direct paths
// with no selected application-data path. Derived from iroh's live path
// snapshot and does not block.
int cmux_iroh_connection_type(
    const CmuxIrohConnection *connection,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Receives up to cap bytes. Returns bytes read (>0), 0 on clean end of
// stream, or -1 on error. timeout_ms == 0 blocks indefinitely; a nonzero
// timeout reports CMUX_IROH_ERROR_TIMEOUT on expiry and loses no data (the
// read is cancel-safe), so the caller can retry.
intptr_t cmux_iroh_connection_recv(
    CmuxIrohConnection *connection,
    uint8_t *buf,
    size_t cap,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Sends len bytes. Returns 0 on success, -1 on error. timeout_ms == 0 blocks
// until QUIC flow control accepts the bytes; a nonzero timeout reports
// CMUX_IROH_ERROR_TIMEOUT on expiry. After a send timeout an unknown prefix
// of the bytes is in flight, so the only safe continuation is
// cmux_iroh_connection_close, which then abandons the stream (no FIN) so the
// truncated write cannot read as a clean end of stream on the peer.
int cmux_iroh_connection_send(
    CmuxIrohConnection *connection,
    const uint8_t *bytes,
    size_t len,
    uint64_t timeout_ms,
    int32_t *err_kind,
    char *err_buf,
    size_t err_cap);

// Closes the connection and releases its handle. Idempotent; safe to call
// concurrently with in-flight recv/send on the same handle (they are forced
// to return, reporting CMUX_IROH_ERROR_CONNECTION_LOST). Bounded even when a
// send is stalled on flow control (the graceful drain is skipped and the
// QUIC close forces the stalled write to return). After a timed-out send the
// stream is abandoned (no FIN) and the connection closes with a nonzero
// application error code, so the peer's recv reports
// CMUX_IROH_ERROR_CONNECTION_LOST instead of a clean end of stream.
void cmux_iroh_connection_close(CmuxIrohConnection *connection);

// Closes the endpoint and releases its handle. Idempotent; safe to call
// concurrently with in-flight calls on the same handle. The sanctioned way
// to stop an accept loop: a blocked accept wakes and reports
// CMUX_IROH_ERROR_ENDPOINT_CLOSED.
void cmux_iroh_endpoint_close(CmuxIrohEndpoint *endpoint);

// Frees a string returned by this library. Null is a no-op.
void cmux_iroh_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif // CMUX_IROH_FFI_H
