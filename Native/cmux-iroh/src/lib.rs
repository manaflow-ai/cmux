//! Minimal blocking C FFI over iroh for the cmux mobile transport.
//!
//! Graduated from `experiments/iroh-swift-ffi-spike` (see
//! `plans/feat-ios-iroh/DESIGN.md`). The surface is deliberately small: one
//! blocking C call per `CmxByteTransport` operation (bind, id, route JSON,
//! online, accept, connect, recv, send, close), called from Swift off the main
//! thread; a shared tokio runtime lives in here. The dialer opens the stream
//! and speaks first, matching the existing mobile protocol where the phone
//! sends the first RPC frame (QUIC `accept_bi` only resolves once the opener
//! has sent bytes).
//!
//! Differences from the spike, per the design doc:
//! - `bind` takes a caller-provided 32-byte Ed25519 secret key. Key custody
//!   lives in Swift (Keychain); Rust never mints a key the caller does not
//!   immediately receive. `cmux_iroh_secret_key_generate` returns fresh key
//!   material to the caller, and `cmux_iroh_secret_key_endpoint_id` derives
//!   the public `EndpointId` without binding.
//! - Every fallible call reports a stable [`CmuxIrohErrorKind`] alongside the
//!   human-readable message so Swift can classify failures (for example into
//!   `CmxConnectFailureKind`) without parsing strings.
//!
//! The C header is hand-maintained at
//! `Packages/Shared/CmuxIrohFFI/Sources/CmuxIrohFFI/include/cmux_iroh_ffi.h` (the
//! `SwiftPM` package that wraps the staticlib and exposes the `CmuxIrohFFI`
//! module) and must stay in sync with this file.

use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    future::Future,
    io,
    net::SocketAddr,
    os::raw::c_int,
    ptr,
    str::FromStr,
    sync::{
        Arc, Mutex as StdMutex, OnceLock, PoisonError,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr,
    endpoint::{
        Connection, ConnectionError, ReadError, RecvStream, SendStream, WriteError, presets,
    },
};
use tokio::{runtime::Runtime, sync::Mutex as TokioMutex};

/// ALPN for the cmux mobile-host protocol lane.
const ALPN: &[u8] = b"dev.cmux.mobile.terminal/0";

/// Length in bytes of an iroh (Ed25519) secret key as passed across the FFI.
pub const CMUX_IROH_SECRET_KEY_LEN: usize = 32;

/// Stable error classification across the FFI boundary.
///
/// The numeric values are ABI: they are mirrored in `cmux_iroh_ffi.h` and
/// consumed by Swift. Add new kinds at the end; never renumber.
#[repr(i32)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CmuxIrohErrorKind {
    /// No error. `err_kind` out-params are reset to this on every call.
    None = 0,
    /// The caller passed an invalid argument (null pointer, wrong key length,
    /// malformed endpoint id / relay URL / direct address).
    InvalidArgument = 1,
    /// Binding the local endpoint failed.
    BindFailed = 2,
    /// The operation did not complete within the caller's timeout.
    Timeout = 3,
    /// Dialing / accepting a connection (or opening its first stream) failed.
    ConnectFailed = 4,
    /// The local endpoint is closed; no further accepts are possible.
    EndpointClosed = 5,
    /// The established connection was lost.
    ConnectionLost = 6,
    /// A stream read/write failed without losing the connection.
    StreamFailed = 7,
    /// Internal failure inside the FFI layer (for example the shared tokio
    /// runtime could not be built).
    Internal = 8,
}

struct FfiError {
    kind: CmuxIrohErrorKind,
    message: String,
}

impl FfiError {
    fn new(kind: CmuxIrohErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

fn runtime() -> Result<&'static Runtime, FfiError> {
    static RUNTIME: OnceLock<io::Result<Runtime>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
        })
        .as_ref()
        .map_err(|error| {
            FfiError::new(
                CmuxIrohErrorKind::Internal,
                format!("tokio runtime failed to build: {error}"),
            )
        })
}

/// Bounds `future` by `timeout_ms` when nonzero; `0` means wait indefinitely
/// (the close calls are the sanctioned way to unblock an indefinite wait).
async fn with_optional_timeout<T>(
    timeout_ms: u64,
    what: &str,
    future: impl Future<Output = T>,
) -> Result<T, FfiError> {
    if timeout_ms == 0 {
        Ok(future.await)
    } else {
        tokio::time::timeout(Duration::from_millis(timeout_ms), future)
            .await
            .map_err(|_| FfiError::new(CmuxIrohErrorKind::Timeout, format!("{what} timed out")))
    }
}

/// Writes `message` into the caller-provided error buffer, truncating to fit.
fn set_error_message(err_buf: *mut c_char, err_cap: usize, message: &str) {
    if err_buf.is_null() || err_cap == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let len = bytes.len().min(err_cap - 1);
    // SAFETY: the caller guarantees `err_buf` points at at least `err_cap`
    // writable bytes; we write at most `err_cap - 1` bytes plus a NUL.
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), err_buf.cast::<u8>(), len);
        *err_buf.add(len) = 0;
    }
}

/// Resets the error out-params at the start of a call.
fn clear_error(err_kind: *mut i32, err_buf: *mut c_char, err_cap: usize) {
    if !err_kind.is_null() {
        // SAFETY: the caller guarantees `err_kind`, when non-null, points at a
        // writable i32.
        unsafe {
            *err_kind = CmuxIrohErrorKind::None as i32;
        }
    }
    set_error_message(err_buf, err_cap, "");
}

/// Reports `error` through the error out-params.
fn report_error(err_kind: *mut i32, err_buf: *mut c_char, err_cap: usize, error: &FfiError) {
    if !err_kind.is_null() {
        // SAFETY: the caller guarantees `err_kind`, when non-null, points at a
        // writable i32.
        unsafe {
            *err_kind = error.kind as i32;
        }
    }
    set_error_message(err_buf, err_cap, &error.message);
}

fn string_to_c(string: String) -> *mut c_char {
    match CString::new(string) {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn c_to_str<'a>(raw: *const c_char) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees non-null `raw` points at a NUL-terminated
    // C string that outlives this call.
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}

fn parse_secret_key(secret_key: *const u8, secret_key_len: usize) -> Result<SecretKey, FfiError> {
    if secret_key.is_null() {
        return Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            "secret key is null; pass a 32-byte Ed25519 secret key (see cmux_iroh_secret_key_generate)",
        ));
    }
    if secret_key_len != CMUX_IROH_SECRET_KEY_LEN {
        return Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            format!(
                "secret key must be exactly {CMUX_IROH_SECRET_KEY_LEN} bytes, got {secret_key_len}"
            ),
        ));
    }
    // SAFETY: non-null `secret_key` with caller-guaranteed length
    // `secret_key_len`, validated above to be exactly 32.
    let bytes = unsafe { std::slice::from_raw_parts(secret_key, CMUX_IROH_SECRET_KEY_LEN) };
    let mut key = [0u8; CMUX_IROH_SECRET_KEY_LEN];
    key.copy_from_slice(bytes);
    Ok(SecretKey::from_bytes(&key))
}

/// Opaque endpoint handle. The pointer value is a key into a process-global
/// registry, never a real address: in-flight blocking calls hold their own
/// `Arc` to the underlying endpoint, so `cmux_iroh_endpoint_close` from
/// another thread can never free memory a blocked call still uses (it instead
/// wakes blocked accepts). Calls on a closed/unknown handle report
/// `InvalidArgument`.
pub struct CmuxIrohEndpoint {
    _opaque: [u8; 0],
}

/// Opaque connection handle; same registry-key model as [`CmuxIrohEndpoint`].
pub struct CmuxIrohConnection {
    _opaque: [u8; 0],
}

struct EndpointInner {
    endpoint: Endpoint,
}

struct ConnectionInner {
    connection: Connection,
    send: TokioMutex<SendStream>,
    recv: TokioMutex<RecvStream>,
    /// Set when a send timed out: an unknown prefix of the caller's bytes is
    /// in flight, so close must abandon the stream instead of finishing it
    /// (a FIN would present the truncated write as a clean end of stream).
    send_poisoned: AtomicBool,
}

/// Application close code for a clean close; the peer's `recv` maps it to
/// end of stream.
const CLOSE_CODE_CLEAN: u32 = 0;

/// Application close code when close abandons a poisoned (timed-out) send.
/// Nonzero so the peer's `recv` reports `ConnectionLost` instead of mapping
/// the close to a clean end of stream and accepting a truncated write.
const CLOSE_CODE_SEND_ABORTED: u32 = 1;

fn next_handle_id() -> usize {
    // Start at 1 so a handle value never collides with null.
    static NEXT: AtomicUsize = AtomicUsize::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

fn endpoint_registry() -> &'static StdMutex<HashMap<usize, Arc<EndpointInner>>> {
    static REGISTRY: OnceLock<StdMutex<HashMap<usize, Arc<EndpointInner>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| StdMutex::new(HashMap::new()))
}

fn connection_registry() -> &'static StdMutex<HashMap<usize, Arc<ConnectionInner>>> {
    static REGISTRY: OnceLock<StdMutex<HashMap<usize, Arc<ConnectionInner>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| StdMutex::new(HashMap::new()))
}

fn register_endpoint(inner: EndpointInner) -> *mut CmuxIrohEndpoint {
    let id = next_handle_id();
    endpoint_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(id, Arc::new(inner));
    id as *mut CmuxIrohEndpoint
}

fn lookup_endpoint(handle: *const CmuxIrohEndpoint) -> Result<Arc<EndpointInner>, FfiError> {
    endpoint_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&(handle as usize))
        .cloned()
        .ok_or_else(|| {
            FfiError::new(
                CmuxIrohErrorKind::InvalidArgument,
                "unknown or closed endpoint handle",
            )
        })
}

fn take_endpoint(handle: *mut CmuxIrohEndpoint) -> Option<Arc<EndpointInner>> {
    endpoint_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .remove(&(handle as usize))
}

fn register_connection(inner: ConnectionInner) -> *mut CmuxIrohConnection {
    let id = next_handle_id();
    connection_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(id, Arc::new(inner));
    id as *mut CmuxIrohConnection
}

fn lookup_connection(handle: *const CmuxIrohConnection) -> Result<Arc<ConnectionInner>, FfiError> {
    connection_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&(handle as usize))
        .cloned()
        .ok_or_else(|| {
            FfiError::new(
                CmuxIrohErrorKind::InvalidArgument,
                "unknown or closed connection handle",
            )
        })
}

fn take_connection(handle: *mut CmuxIrohConnection) -> Option<Arc<ConnectionInner>> {
    connection_registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .remove(&(handle as usize))
}

/// Generates a fresh Ed25519 secret key into the caller's buffer.
///
/// The caller owns the key material (Keychain custody in Swift); this library
/// keeps no copy. Returns 0 on success, -1 if `out_key` is null or
/// `out_key_cap` is smaller than `CMUX_IROH_SECRET_KEY_LEN`.
///
/// # Safety
///
/// `out_key`, when non-null, must point at at least `out_key_cap` writable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_secret_key_generate(
    out_key: *mut u8,
    out_key_cap: usize,
) -> c_int {
    if out_key.is_null() || out_key_cap < CMUX_IROH_SECRET_KEY_LEN {
        return -1;
    }
    let key = SecretKey::generate().to_bytes();
    // SAFETY: `out_key` is non-null and the caller guarantees at least
    // `out_key_cap` >= 32 writable bytes.
    unsafe {
        ptr::copy_nonoverlapping(key.as_ptr(), out_key, CMUX_IROH_SECRET_KEY_LEN);
    }
    0
}

/// Derives the z-base-32 `EndpointId` (public key) for a secret key without
/// binding an endpoint. Returns a heap string to free with
/// `cmux_iroh_string_free`, or null if the key is invalid.
///
/// # Safety
///
/// `secret_key`, when non-null, must point at `secret_key_len` readable bytes.
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn cmux_iroh_secret_key_endpoint_id(
    secret_key: *const u8,
    secret_key_len: usize,
) -> *mut c_char {
    match parse_secret_key(secret_key, secret_key_len) {
        Ok(key) => string_to_c(key.public().to_string()),
        Err(_) => ptr::null_mut(),
    }
}

/// Binds an iroh endpoint using the default n0 preset (relays + discovery)
/// and the caller-provided secret key.
///
/// Returns null on failure with the cause in the error out-params.
///
/// # Safety
///
/// - `secret_key` must point at `secret_key_len` readable bytes.
/// - `err_kind`, when non-null, must point at a writable `int32_t`.
/// - `err_buf`, when non-null, must point at `err_cap` writable bytes.
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn cmux_iroh_endpoint_bind(
    secret_key: *const u8,
    secret_key_len: usize,
    enable_relay: bool,
    accept_connections: bool,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohEndpoint {
    clear_error(err_kind, err_buf, err_cap);
    let result = bind_impl(secret_key, secret_key_len, enable_relay, accept_connections);
    match result {
        Ok(endpoint) => register_endpoint(EndpointInner { endpoint }),
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            ptr::null_mut()
        }
    }
}

fn bind_impl(
    secret_key: *const u8,
    secret_key_len: usize,
    enable_relay: bool,
    accept_connections: bool,
) -> Result<Endpoint, FfiError> {
    let key = parse_secret_key(secret_key, secret_key_len)?;
    runtime()?
        .block_on(async move {
            let mut builder =
                Endpoint::builder(presets::N0)
                    .secret_key(key)
                    .relay_mode(if enable_relay {
                        RelayMode::Default
                    } else {
                        RelayMode::Disabled
                    });
            if accept_connections {
                builder = builder.alpns(vec![ALPN.to_vec()]);
            }
            builder.bind().await
        })
        .map_err(|error| {
            FfiError::new(
                CmuxIrohErrorKind::BindFailed,
                format!("bind failed: {error:#}"),
            )
        })
}

/// Returns the endpoint's `EndpointId` (z-base-32) as a heap string.
/// Free with `cmux_iroh_string_free`. Null if the handle is null, unknown, or
/// closed.
#[unsafe(no_mangle)]
#[must_use]
pub extern "C" fn cmux_iroh_endpoint_id(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    let Ok(endpoint) = lookup_endpoint(endpoint) else {
        return ptr::null_mut();
    };
    string_to_c(endpoint.endpoint.id().to_string())
}

/// Returns a `CmxAttachRoute`-shaped JSON object for this endpoint
/// (id, direct addrs, relay URL). Free with `cmux_iroh_string_free`. Null if
/// the handle is null, unknown, or closed.
#[unsafe(no_mangle)]
#[must_use]
pub extern "C" fn cmux_iroh_endpoint_route_json(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    let Ok(endpoint) = lookup_endpoint(endpoint) else {
        return ptr::null_mut();
    };
    let addr = endpoint.endpoint.addr();
    let direct_addrs = addr
        .ip_addrs()
        .map(std::string::ToString::to_string)
        .collect::<Vec<_>>();
    let relay_url = addr
        .relay_urls()
        .next()
        .map(std::string::ToString::to_string);
    // `CmxAttachTicket.preferredRoute` sorts ascending and lower wins, so iroh
    // must sit below the Mac's primary Tailscale route (priority 10) to be the
    // default; 5 also stays above debugLoopback (0) so DEBUG/simulator runs
    // keep preferring the loopback mock host.
    let route = serde_json::json!({
        "id": "iroh",
        "kind": "iroh",
        "endpoint": {
            "type": "peer",
            "id": endpoint.endpoint.id().to_string(),
            "direct_addrs": direct_addrs,
            "relay_url": relay_url,
        },
        "priority": 5,
    });
    string_to_c(route.to_string())
}

/// Waits until the endpoint has a home relay connection (so dial-by-id from
/// elsewhere can reach it). 0 on success, -1 on failure/timeout.
/// `timeout_ms == 0` waits indefinitely (close unblocks it).
///
/// # Safety
///
/// Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_endpoint_online(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    clear_error(err_kind, err_buf, err_cap);
    let result = lookup_endpoint(endpoint).and_then(|endpoint| online_impl(&endpoint, timeout_ms));
    match result {
        Ok(()) => 0,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn online_impl(endpoint: &EndpointInner, timeout_ms: u64) -> Result<(), FfiError> {
    runtime()?.block_on(with_optional_timeout(
        timeout_ms,
        "waiting for relay connection",
        endpoint.endpoint.online(),
    ))
}

/// Accepts one incoming connection and its first bidirectional stream.
/// Blocks up to `timeout_ms`; `timeout_ms == 0` blocks indefinitely. Returns
/// null on failure/timeout. `cmux_iroh_endpoint_close` from another thread
/// wakes a blocked accept, which then reports `EndpointClosed`.
///
/// # Safety
///
/// Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn cmux_iroh_endpoint_accept(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    clear_error(err_kind, err_buf, err_cap);
    let result = lookup_endpoint(endpoint).and_then(|endpoint| accept_impl(&endpoint, timeout_ms));
    finish_connection(result, err_kind, err_buf, err_cap)
}

fn accept_impl(
    endpoint: &EndpointInner,
    timeout_ms: u64,
) -> Result<(Connection, SendStream, RecvStream), FfiError> {
    runtime()?.block_on(async {
        with_optional_timeout(timeout_ms, "accept", async {
            let incoming = endpoint.endpoint.accept().await.ok_or_else(|| {
                FfiError::new(CmuxIrohErrorKind::EndpointClosed, "endpoint closed")
            })?;
            let connection = incoming.await.map_err(|error| {
                FfiError::new(
                    CmuxIrohErrorKind::ConnectFailed,
                    format!("incoming connection failed: {error:#}"),
                )
            })?;
            let (send, recv) = connection.accept_bi().await.map_err(|error| {
                FfiError::new(
                    CmuxIrohErrorKind::ConnectFailed,
                    format!("accept_bi failed: {error:#}"),
                )
            })?;
            Ok((connection, send, recv))
        })
        .await?
    })
}

/// Dials `endpoint_id` (optionally with relay URL / direct addr hints) and
/// opens one bidirectional stream. With no hints, n0 discovery resolves the
/// id. Returns null on failure/timeout; `timeout_ms == 0` blocks
/// indefinitely (close unblocks it).
///
/// # Safety
///
/// - `endpoint_id` and `relay_url`, when non-null, must be NUL-terminated C
///   strings.
/// - `direct_addrs`, when non-null, must point at `direct_addr_count`
///   NUL-terminated C strings.
/// - Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
#[must_use]
#[allow(
    clippy::too_many_arguments,
    reason = "C ABI surface; grouping into structs would complicate the Swift call sites"
)]
pub unsafe extern "C" fn cmux_iroh_endpoint_connect(
    endpoint: *mut CmuxIrohEndpoint,
    endpoint_id: *const c_char,
    relay_url: *const c_char,
    direct_addrs: *const *const c_char,
    direct_addr_count: usize,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    clear_error(err_kind, err_buf, err_cap);
    // SAFETY: forwarded caller contract for `endpoint` and the string params.
    let result = unsafe {
        connect_impl(
            endpoint,
            endpoint_id,
            relay_url,
            direct_addrs,
            direct_addr_count,
            timeout_ms,
        )
    };
    finish_connection(result, err_kind, err_buf, err_cap)
}

/// # Safety
///
/// Same contract as [`cmux_iroh_endpoint_connect`].
unsafe fn connect_impl(
    endpoint: *mut CmuxIrohEndpoint,
    endpoint_id: *const c_char,
    relay_url: *const c_char,
    direct_addrs: *const *const c_char,
    direct_addr_count: usize,
    timeout_ms: u64,
) -> Result<(Connection, SendStream, RecvStream), FfiError> {
    let endpoint = lookup_endpoint(endpoint)?;
    let Some(id_str) = c_to_str(endpoint_id) else {
        return Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            "null or invalid endpoint id",
        ));
    };
    let id = EndpointId::from_str(id_str).map_err(|error| {
        FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            format!("invalid endpoint id: {error:#}"),
        )
    })?;

    let mut addrs: Vec<TransportAddr> = Vec::new();
    if !direct_addrs.is_null() {
        for index in 0..direct_addr_count {
            // SAFETY: caller guarantees `direct_addrs` points at
            // `direct_addr_count` entries.
            let raw = unsafe { *direct_addrs.add(index) };
            let Some(addr_str) = c_to_str(raw) else {
                return Err(FfiError::new(
                    CmuxIrohErrorKind::InvalidArgument,
                    format!("direct addr {index} is null or not valid UTF-8"),
                ));
            };
            let addr = SocketAddr::from_str(addr_str).map_err(|error| {
                FfiError::new(
                    CmuxIrohErrorKind::InvalidArgument,
                    format!("invalid direct addr {addr_str}: {error:#}"),
                )
            })?;
            addrs.push(TransportAddr::Ip(addr));
        }
    }
    if let Some(relay_str) = c_to_str(relay_url) {
        let url = RelayUrl::from_str(relay_str).map_err(|error| {
            FfiError::new(
                CmuxIrohErrorKind::InvalidArgument,
                format!("invalid relay url: {error:#}"),
            )
        })?;
        addrs.push(TransportAddr::Relay(url));
    }
    let addr = if addrs.is_empty() {
        EndpointAddr::from(id)
    } else {
        EndpointAddr::from_parts(id, addrs)
    };

    runtime()?.block_on(async {
        with_optional_timeout(timeout_ms, "connect", async {
            let connection = endpoint
                .endpoint
                .connect(addr, ALPN)
                .await
                .map_err(|error| {
                    FfiError::new(
                        CmuxIrohErrorKind::ConnectFailed,
                        format!("connect failed: {error:#}"),
                    )
                })?;
            let (send, recv) = connection.open_bi().await.map_err(|error| {
                FfiError::new(
                    CmuxIrohErrorKind::ConnectFailed,
                    format!("open_bi failed: {error:#}"),
                )
            })?;
            Ok((connection, send, recv))
        })
        .await?
    })
}

/// Receives up to `cap` bytes. Returns bytes read (>0), 0 on clean end of
/// stream, or -1 on error.
///
/// `timeout_ms == 0` blocks until data, end of stream, or a connection error.
/// A nonzero timeout bounds the wait and reports `Timeout` on expiry; no data
/// is lost (the QUIC read is cancel-safe), so the caller can retry. Bounded
/// receives are how a caller regains control to cancel or close.
///
/// # Safety
///
/// - `connection`, when non-null, must be a live pointer returned by
///   `cmux_iroh_endpoint_accept`/`cmux_iroh_endpoint_connect` that has not
///   been closed.
/// - `buf`, when non-null, must point at `cap` writable bytes.
/// - Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_connection_recv(
    connection: *mut CmuxIrohConnection,
    buf: *mut u8,
    cap: usize,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> isize {
    clear_error(err_kind, err_buf, err_cap);
    let connection = match lookup_connection(connection) {
        Ok(connection) => connection,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            return -1;
        }
    };
    if buf.is_null() || cap == 0 {
        report_error(
            err_kind,
            err_buf,
            err_cap,
            &FfiError::new(
                CmuxIrohErrorKind::InvalidArgument,
                "null or empty receive buffer",
            ),
        );
        return -1;
    }
    // SAFETY: `buf` is non-null and the caller guarantees `cap` writable bytes.
    let slice = unsafe { std::slice::from_raw_parts_mut(buf, cap) };
    match recv_impl(&connection, slice, timeout_ms) {
        Ok(read) => isize::try_from(read).unwrap_or(isize::MAX),
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn recv_impl(
    connection: &ConnectionInner,
    buf: &mut [u8],
    timeout_ms: u64,
) -> Result<usize, FfiError> {
    let result = runtime()?.block_on(async {
        let mut recv = connection.recv.lock().await;
        // RecvStream::read is cancel-safe: dropping the future on timeout
        // consumes no data, so a bounded receive can simply be retried.
        with_optional_timeout(timeout_ms, "recv", recv.read(buf)).await
    })?;
    match result {
        Ok(Some(read)) => Ok(read),
        Ok(None) => Ok(0),
        // A clean peer close (application error code 0) is end-of-stream,
        // not an error: QUIC CONNECTION_CLOSE can race the stream FIN.
        Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(close)))
            if u64::from(close.error_code) == 0 =>
        {
            Ok(0)
        }
        Err(ReadError::ConnectionLost(error)) => Err(FfiError::new(
            CmuxIrohErrorKind::ConnectionLost,
            format!("recv failed: connection lost: {error:#}"),
        )),
        Err(error) => Err(FfiError::new(
            CmuxIrohErrorKind::StreamFailed,
            format!("recv failed: {error:#}"),
        )),
    }
}

/// Sends `len` bytes. Returns 0 on success, -1 on error.
///
/// `timeout_ms == 0` blocks until the bytes are accepted by QUIC flow control.
/// A nonzero timeout bounds the wait (a peer that stops reading stalls flow
/// control indefinitely otherwise) and reports `Timeout` on expiry. A timed
/// out send leaves the stream with an unknown number of bytes written, so the
/// only safe continuation is `cmux_iroh_connection_close`, which then
/// abandons the stream (no FIN) instead of finishing it so the truncated
/// write cannot read as a clean end of stream.
///
/// # Safety
///
/// - `connection`, when non-null, must be live (see
///   `cmux_iroh_connection_recv`).
/// - `bytes`, when non-null, must point at `len` readable bytes.
/// - Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_connection_send(
    connection: *mut CmuxIrohConnection,
    bytes: *const u8,
    len: usize,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    clear_error(err_kind, err_buf, err_cap);
    let connection = match lookup_connection(connection) {
        Ok(connection) => connection,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            return -1;
        }
    };
    if len == 0 {
        return 0;
    }
    if bytes.is_null() {
        report_error(
            err_kind,
            err_buf,
            err_cap,
            &FfiError::new(CmuxIrohErrorKind::InvalidArgument, "null send buffer"),
        );
        return -1;
    }
    // SAFETY: `bytes` is non-null and the caller guarantees `len` readable
    // bytes.
    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    match send_impl(&connection, slice, timeout_ms) {
        Ok(()) => 0,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn send_impl(connection: &ConnectionInner, bytes: &[u8], timeout_ms: u64) -> Result<(), FfiError> {
    let result = runtime()?.block_on(async {
        let mut send = connection.send.lock().await;
        // write_all is NOT cancel-safe: on timeout an unknown prefix of
        // `bytes` is in flight. Poison the stream so close abandons it
        // instead of finishing it (the doc comment requires callers to close
        // after a send timeout).
        let result = with_optional_timeout(timeout_ms, "send", send.write_all(bytes)).await;
        if matches!(
            &result,
            Err(error) if error.kind == CmuxIrohErrorKind::Timeout
        ) {
            connection.send_poisoned.store(true, Ordering::Relaxed);
        }
        result
    })?;
    result.map_err(|error| match error {
        WriteError::ConnectionLost(_) => FfiError::new(
            CmuxIrohErrorKind::ConnectionLost,
            format!("send failed: connection lost: {error:#}"),
        ),
        _ => FfiError::new(
            CmuxIrohErrorKind::StreamFailed,
            format!("send failed: {error:#}"),
        ),
    })
}

/// Closes the connection and frees its handle. Null is a no-op.
///
/// Graceful close: `finish()` only queues the FIN plus any buffered stream
/// data, while `Connection::close` is immediate and abandons buffered data.
/// Closing right after finishing could therefore drop a final frame that
/// `send()` already reported as accepted. `stopped()` resolves once the peer
/// acknowledges receipt of all finished stream data, so wait for it (bounded,
/// so a vanished peer cannot wedge close) before closing the connection.
///
/// Close is itself bounded: acquiring the send stream waits at most 5s, so a
/// send stalled on flow control (only possible when the caller passed
/// `timeout_ms == 0`) cannot wedge close. In that case the graceful drain is
/// skipped and `Connection::close` fires immediately, which also forces the
/// stalled `write_all` to return `ConnectionLost`.
///
/// After a timed-out send the stream carries a truncated write, so close
/// abandons the stream (no FIN) and closes the connection with
/// [`CLOSE_CODE_SEND_ABORTED`]; the peer's `recv` then reports
/// `ConnectionLost` instead of presenting the prefix as a clean end of
/// stream.
///
/// Safe to call concurrently with in-flight recv/send on the same handle:
/// handles are registry keys and in-flight calls hold their own reference, so
/// close never frees memory another call is using. The forced QUIC close
/// errors blocked recv/send out (`ConnectionLost`). Idempotent: closing an
/// unknown or already-closed handle is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_close(connection: *mut CmuxIrohConnection) {
    let Some(connection) = take_connection(connection) else {
        return;
    };
    let Ok(runtime) = runtime() else {
        return;
    };
    runtime.block_on(async {
        // After a timed-out send the stream carries a truncated write, so the
        // graceful FIN+drain would present it to the peer as a clean end of
        // stream; abandon the stream and close with a nonzero application
        // error so the peer reads an abort, not EOF.
        let poisoned = connection.send_poisoned.load(Ordering::Relaxed);
        if !poisoned
            && let Ok(mut send) =
                tokio::time::timeout(Duration::from_secs(5), connection.send.lock()).await
            && send.finish().is_ok()
        {
            let _ = tokio::time::timeout(Duration::from_secs(5), send.stopped()).await;
        }
        let code = if poisoned {
            CLOSE_CODE_SEND_ABORTED
        } else {
            CLOSE_CODE_CLEAN
        };
        connection.connection.close(code.into(), b"close");
    });
}

/// Closes the endpoint and releases its handle. Null is a no-op.
///
/// Safe to call concurrently with in-flight calls on the same handle (registry
/// keys, see [`CmuxIrohEndpoint`]); a blocked `cmux_iroh_endpoint_accept` is
/// woken and reports `EndpointClosed`, which makes close the sanctioned way to
/// stop an accept loop. Idempotent: closing an unknown or already-closed
/// handle is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_close(endpoint: *mut CmuxIrohEndpoint) {
    let Some(endpoint) = take_endpoint(endpoint) else {
        return;
    };
    let Ok(runtime) = runtime() else {
        return;
    };
    runtime.block_on(async {
        endpoint.endpoint.close().await;
    });
}

/// Frees a string returned by this library. Null is a no-op.
///
/// # Safety
///
/// `string`, when non-null, must be a pointer returned by this library that
/// has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_string_free(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    // SAFETY: caller passes ownership of a string this library allocated via
    // `CString::into_raw`.
    drop(unsafe { CString::from_raw(string) });
}

fn finish_connection(
    result: Result<(Connection, SendStream, RecvStream), FfiError>,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    match result {
        Ok((connection, send, recv)) => register_connection(ConnectionInner {
            connection,
            send: TokioMutex::new(send),
            recv: TokioMutex::new(recv),
            send_poisoned: AtomicBool::new(false),
        }),
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            ptr::null_mut()
        }
    }
}

#[cfg(test)]
mod ffi_seam_tests {
    // Behavior tests for the C FFI seam, driven through the extern "C" functions
    // exactly as a Swift caller would use them (raw pointers, error buffers,
    // error kinds). The loopback test keeps relays disabled so it exercises only
    // local UDP paths and stays hermetic.

    use std::ffi::{CStr, CString};
    use std::os::raw::c_char;
    use std::ptr;

    use super::*;

    const ERR_CAP: usize = 512;

    struct ErrOut {
        kind: i32,
        buf: [c_char; ERR_CAP],
    }

    impl ErrOut {
        fn new() -> Self {
            Self {
                kind: -1,
                buf: [0; ERR_CAP],
            }
        }

        fn kind(&self) -> i32 {
            self.kind
        }

        fn message(&self) -> String {
            let cstr = unsafe { CStr::from_ptr(self.buf.as_ptr()) };
            cstr.to_string_lossy().into_owned()
        }
    }

    fn generate_key() -> [u8; CMUX_IROH_SECRET_KEY_LEN] {
        let mut key = [0u8; CMUX_IROH_SECRET_KEY_LEN];
        let rc = unsafe { cmux_iroh_secret_key_generate(key.as_mut_ptr(), key.len()) };
        assert_eq!(rc, 0, "secret key generation should succeed");
        key
    }

    fn take_string(raw: *mut c_char) -> String {
        assert!(!raw.is_null(), "expected a string from the FFI");
        let value = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        unsafe { cmux_iroh_string_free(raw) };
        value
    }

    fn bind(key: &[u8; CMUX_IROH_SECRET_KEY_LEN], accept: bool) -> *mut CmuxIrohEndpoint {
        let mut err = ErrOut::new();
        let endpoint = unsafe {
            cmux_iroh_endpoint_bind(
                key.as_ptr(),
                key.len(),
                false, // relay disabled: hermetic, local UDP only
                accept,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(
            !endpoint.is_null(),
            "bind should succeed (kind {}, message {:?})",
            err.kind(),
            err.message()
        );
        assert_eq!(err.kind(), CmuxIrohErrorKind::None as i32);
        endpoint
    }

    #[test]
    fn secret_key_generate_fills_buffer_and_is_random() {
        let first = generate_key();
        let second = generate_key();
        assert_ne!(first, [0u8; CMUX_IROH_SECRET_KEY_LEN]);
        assert_ne!(first, second, "two generated keys should differ");

        let rc =
            unsafe { cmux_iroh_secret_key_generate(ptr::null_mut(), CMUX_IROH_SECRET_KEY_LEN) };
        assert_eq!(rc, -1, "null buffer must be rejected");
        let mut short = [0u8; 16];
        let rc = unsafe { cmux_iroh_secret_key_generate(short.as_mut_ptr(), short.len()) };
        assert_eq!(rc, -1, "short buffer must be rejected");
    }

    #[test]
    fn secret_key_endpoint_id_is_deterministic() {
        let key = generate_key();
        let first =
            take_string(unsafe { cmux_iroh_secret_key_endpoint_id(key.as_ptr(), key.len()) });
        let second =
            take_string(unsafe { cmux_iroh_secret_key_endpoint_id(key.as_ptr(), key.len()) });
        assert_eq!(first, second, "same key must derive the same EndpointId");
        assert!(!first.is_empty());

        let raw =
            unsafe { cmux_iroh_secret_key_endpoint_id(ptr::null(), CMUX_IROH_SECRET_KEY_LEN) };
        assert!(raw.is_null(), "null key must be rejected");
        let raw = unsafe { cmux_iroh_secret_key_endpoint_id(key.as_ptr(), 16) };
        assert!(raw.is_null(), "wrong-length key must be rejected");
    }

    #[test]
    fn bind_rejects_missing_or_wrong_length_key() {
        let mut err = ErrOut::new();
        let endpoint = unsafe {
            cmux_iroh_endpoint_bind(
                ptr::null(),
                CMUX_IROH_SECRET_KEY_LEN,
                false,
                false,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(endpoint.is_null());
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
        assert!(err.message().contains("secret key"), "{}", err.message());

        let key = generate_key();
        let mut err = ErrOut::new();
        let endpoint = unsafe {
            cmux_iroh_endpoint_bind(
                key.as_ptr(),
                16,
                false,
                false,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(endpoint.is_null());
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
    }

    #[test]
    fn bind_uses_caller_key_for_endpoint_identity() {
        let key = generate_key();
        let derived =
            take_string(unsafe { cmux_iroh_secret_key_endpoint_id(key.as_ptr(), key.len()) });

        let endpoint = bind(&key, false);
        let bound = take_string(cmux_iroh_endpoint_id(endpoint));
        assert_eq!(
            bound, derived,
            "bound endpoint must use the caller-provided key"
        );

        let route = take_string(cmux_iroh_endpoint_route_json(endpoint));
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        assert_eq!(parsed["kind"], "iroh");
        assert_eq!(parsed["endpoint"]["type"], "peer");
        assert_eq!(parsed["endpoint"]["id"], derived.as_str());

        cmux_iroh_endpoint_close(endpoint);
    }

    #[test]
    fn connect_rejects_invalid_endpoint_id() {
        let key = generate_key();
        let endpoint = bind(&key, false);

        let bogus = CString::new("not-a-valid-endpoint-id").expect("cstring");
        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                endpoint,
                bogus.as_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                1_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(connection.is_null());
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);

        // A null entry inside direct_addrs is a caller bug, not a hint to
        // silently drop: it must fail fast as InvalidArgument.
        let valid_key = generate_key();
        let valid_id = take_string(unsafe {
            cmux_iroh_secret_key_endpoint_id(valid_key.as_ptr(), valid_key.len())
        });
        let id_cstr = CString::new(valid_id).expect("cstring");
        let addrs_with_null: [*const c_char; 1] = [ptr::null()];
        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                endpoint,
                id_cstr.as_ptr(),
                ptr::null(),
                addrs_with_null.as_ptr(),
                addrs_with_null.len(),
                1_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(connection.is_null());
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
        assert!(err.message().contains("direct addr"), "{}", err.message());

        cmux_iroh_endpoint_close(endpoint);
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one deliberate end-to-end scenario: bind two endpoints, dial, roundtrip, clean close"
    )]
    fn loopback_connect_roundtrip_and_clean_close() {
        const PAYLOAD: &[u8] = b"cmux iroh ffi seam roundtrip";

        let listener_key = generate_key();
        let dialer_key = generate_key();

        let listener = bind(&listener_key, true);
        let dialer = bind(&dialer_key, false);

        let listener_id = take_string(cmux_iroh_endpoint_id(listener));
        let route = take_string(cmux_iroh_endpoint_route_json(listener));
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        let direct_addrs: Vec<String> = parsed["endpoint"]["direct_addrs"]
            .as_array()
            .expect("direct_addrs is an array")
            .iter()
            .map(|value| value.as_str().expect("addr is a string").to_owned())
            .collect();
        assert!(
            !direct_addrs.is_empty(),
            "relay-less endpoint must expose direct addrs"
        );

        // Accept blocks, so run it on its own thread like Swift would.
        let listener_addr = ListenerPtr(listener);
        let accept_thread = std::thread::spawn(move || {
            let listener = listener_addr;
            let mut err = ErrOut::new();
            let connection = unsafe {
                cmux_iroh_endpoint_accept(
                    listener.0,
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert!(
                !connection.is_null(),
                "accept should succeed (kind {}, message {:?})",
                err.kind(),
                err.message()
            );

            // Echo the whole payload back. QUIC delivers a stream, not
            // messages: one recv may return any fragment of the payload, so
            // accumulate until the full length has been echoed (a single
            // read-then-echo here was a latent flake under suite load).
            let mut echoed_total = 0usize;
            while echoed_total < PAYLOAD.len() {
                let mut buf = [0u8; 64];
                let mut err = ErrOut::new();
                let read = unsafe {
                    cmux_iroh_connection_recv(
                        connection,
                        buf.as_mut_ptr(),
                        buf.len(),
                        30_000,
                        &raw mut err.kind,
                        err.buf.as_mut_ptr(),
                        ERR_CAP,
                    )
                };
                assert!(read > 0, "listener should receive bytes: {}", err.message());
                let read = usize::try_from(read).expect("positive read fits usize");
                let mut err = ErrOut::new();
                let rc = unsafe {
                    cmux_iroh_connection_send(
                        connection,
                        buf.as_ptr(),
                        read,
                        30_000,
                        &raw mut err.kind,
                        err.buf.as_mut_ptr(),
                        ERR_CAP,
                    )
                };
                assert_eq!(rc, 0, "echo send should succeed: {}", err.message());
                echoed_total += read;
            }
            assert_eq!(echoed_total, PAYLOAD.len(), "echoed exactly the payload");

            // The dialer closes first; recv should then report clean end of
            // stream (0), not an error.
            let mut eof_buf = [0u8; 64];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    eof_buf.as_mut_ptr(),
                    eof_buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(
                read,
                0,
                "peer close should read as EOF (kind {}, message {:?})",
                err.kind(),
                err.message()
            );

            cmux_iroh_connection_close(connection);
        });

        let id_cstr = CString::new(listener_id).expect("cstring");
        let addr_cstrs: Vec<CString> = direct_addrs
            .iter()
            .map(|addr| CString::new(addr.as_str()).expect("cstring"))
            .collect();
        let addr_ptrs: Vec<*const c_char> = addr_cstrs.iter().map(|addr| addr.as_ptr()).collect();

        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                dialer,
                id_cstr.as_ptr(),
                ptr::null(),
                addr_ptrs.as_ptr(),
                addr_ptrs.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(
            !connection.is_null(),
            "connect should succeed (kind {}, message {:?})",
            err.kind(),
            err.message()
        );
        assert_eq!(err.kind(), CmuxIrohErrorKind::None as i32);

        let payload = PAYLOAD;
        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                connection,
                payload.as_ptr(),
                payload.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, 0, "send should succeed: {}", err.message());

        let mut echoed = Vec::new();
        while echoed.len() < payload.len() {
            let mut buf = [0u8; 64];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert!(
                read > 0,
                "dialer should receive echo (kind {}, message {:?})",
                err.kind(),
                err.message()
            );
            let read = usize::try_from(read).expect("positive read fits usize");
            echoed.extend_from_slice(&buf[..read]);
        }
        assert_eq!(echoed, payload, "echoed bytes must match");

        cmux_iroh_connection_close(connection);
        accept_thread.join().expect("accept thread joins cleanly");

        cmux_iroh_endpoint_close(dialer);
        cmux_iroh_endpoint_close(listener);
    }

    #[test]
    fn recv_and_send_reject_null_connection() {
        let mut buf = [0u8; 8];
        let mut err = ErrOut::new();
        let read = unsafe {
            cmux_iroh_connection_recv(
                ptr::null_mut(),
                buf.as_mut_ptr(),
                buf.len(),
                0,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(read, -1);
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);

        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                ptr::null_mut(),
                buf.as_ptr(),
                buf.len(),
                0,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, -1);
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one deliberate scenario: silent peer, bounded recv times out twice, clean close"
    )]
    fn recv_with_timeout_reports_timeout_kind_and_is_retryable() {
        let listener_key = generate_key();
        let dialer_key = generate_key();
        let listener = bind(&listener_key, true);
        let dialer = bind(&dialer_key, false);

        let listener_id = take_string(cmux_iroh_endpoint_id(listener));
        let route = take_string(cmux_iroh_endpoint_route_json(listener));
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        let direct_addrs: Vec<String> = parsed["endpoint"]["direct_addrs"]
            .as_array()
            .expect("direct_addrs is an array")
            .iter()
            .map(|value| value.as_str().expect("addr is a string").to_owned())
            .collect();

        let listener_ptr = ListenerPtr(listener);
        let accept_thread = std::thread::spawn(move || {
            let listener = listener_ptr;
            let mut err = ErrOut::new();
            let connection = unsafe {
                cmux_iroh_endpoint_accept(
                    listener.0,
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert!(!connection.is_null(), "accept: {}", err.message());
            // Read the opener byte, then send nothing: the dialer's bounded
            // recv must time out. Wait for the dialer's close (EOF) before
            // closing so the timing is deterministic.
            let mut buf = [0u8; 8];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(read, 1, "listener reads the opener byte");
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(read, 0, "dialer close reads as EOF");
            cmux_iroh_connection_close(connection);
        });

        let id_cstr = CString::new(listener_id).expect("cstring");
        let addr_cstrs: Vec<CString> = direct_addrs
            .iter()
            .map(|addr| CString::new(addr.as_str()).expect("cstring"))
            .collect();
        let addr_ptrs: Vec<*const c_char> = addr_cstrs.iter().map(|addr| addr.as_ptr()).collect();
        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                dialer,
                id_cstr.as_ptr(),
                ptr::null(),
                addr_ptrs.as_ptr(),
                addr_ptrs.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(!connection.is_null(), "connect: {}", err.message());

        // Open the stream so the listener's accept_bi resolves.
        let opener = [0x42u8; 1];
        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                connection,
                opener.as_ptr(),
                opener.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, 0, "opener send: {}", err.message());

        // The listener sends nothing, so a bounded recv must report Timeout
        // (not EOF, not a stream error) and stay retryable.
        for _ in 0..2 {
            let mut buf = [0u8; 8];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    150,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(read, -1, "bounded recv with silent peer fails");
            assert_eq!(err.kind(), CmuxIrohErrorKind::Timeout as i32);
        }

        cmux_iroh_connection_close(connection);
        accept_thread.join().expect("accept thread joins cleanly");
        cmux_iroh_endpoint_close(dialer);
        cmux_iroh_endpoint_close(listener);
    }

    #[test]
    fn endpoint_close_unblocks_blocked_accept() {
        let key = generate_key();
        let listener = bind(&key, true);

        let (started_tx, started_rx) = std::sync::mpsc::channel::<()>();
        let listener_ptr = ListenerPtr(listener);
        let accept_thread = std::thread::spawn(move || {
            let listener = listener_ptr;
            started_tx.send(()).expect("signal accept start");
            let mut err = ErrOut::new();
            let connection = unsafe {
                cmux_iroh_endpoint_accept(
                    listener.0,
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            // Close either wakes the blocked accept (EndpointClosed) or, if it
            // won the race before accept started, invalidates the handle
            // (InvalidArgument). Both return promptly; a 30s join would mean
            // close failed to unblock accept.
            assert!(connection.is_null());
            assert!(
                err.kind() == CmuxIrohErrorKind::EndpointClosed as i32
                    || err.kind() == CmuxIrohErrorKind::InvalidArgument as i32,
                "unexpected kind {} ({})",
                err.kind(),
                err.message()
            );
        });

        started_rx.recv().expect("accept thread started");
        cmux_iroh_endpoint_close(listener);
        accept_thread.join().expect("accept thread joins promptly");

        // The handle is gone: further calls fail cleanly, double close no-ops.
        assert!(cmux_iroh_endpoint_id(listener).is_null());
        cmux_iroh_endpoint_close(listener);
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one deliberate scenario: blocked recv, concurrent same-handle close, prompt clean return"
    )]
    fn connection_close_during_blocked_recv_returns_promptly() {
        let listener_key = generate_key();
        let dialer_key = generate_key();
        let listener = bind(&listener_key, true);
        let dialer = bind(&dialer_key, false);

        let listener_id = take_string(cmux_iroh_endpoint_id(listener));
        let route = take_string(cmux_iroh_endpoint_route_json(listener));
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        let direct_addrs: Vec<String> = parsed["endpoint"]["direct_addrs"]
            .as_array()
            .expect("direct_addrs is an array")
            .iter()
            .map(|value| value.as_str().expect("addr is a string").to_owned())
            .collect();

        // Listener side: accept, read until EOF, then close. Reading the FIN
        // lets the dialer's graceful close drain resolve promptly.
        let listener_ptr = ListenerPtr(listener);
        let accept_thread = std::thread::spawn(move || {
            let listener = listener_ptr;
            let mut err = ErrOut::new();
            let connection = unsafe {
                cmux_iroh_endpoint_accept(
                    listener.0,
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert!(!connection.is_null(), "accept: {}", err.message());
            loop {
                let mut buf = [0u8; 16];
                let mut err = ErrOut::new();
                let read = unsafe {
                    cmux_iroh_connection_recv(
                        connection,
                        buf.as_mut_ptr(),
                        buf.len(),
                        30_000,
                        &raw mut err.kind,
                        err.buf.as_mut_ptr(),
                        ERR_CAP,
                    )
                };
                if read <= 0 {
                    break;
                }
            }
            cmux_iroh_connection_close(connection);
        });

        let id_cstr = CString::new(listener_id).expect("cstring");
        let addr_cstrs: Vec<CString> = direct_addrs
            .iter()
            .map(|addr| CString::new(addr.as_str()).expect("cstring"))
            .collect();
        let addr_ptrs: Vec<*const c_char> = addr_cstrs.iter().map(|addr| addr.as_ptr()).collect();
        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                dialer,
                id_cstr.as_ptr(),
                ptr::null(),
                addr_ptrs.as_ptr(),
                addr_ptrs.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(!connection.is_null(), "connect: {}", err.message());

        let opener = [0x42u8; 1];
        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                connection,
                opener.as_ptr(),
                opener.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, 0, "opener send: {}", err.message());

        // Block a recv with no timeout on the dialer handle, then close that
        // same handle from this thread. The registry keeps the connection
        // alive for the in-flight recv (no use-after-free) and the QUIC close
        // forces it to return.
        let (started_tx, started_rx) = std::sync::mpsc::channel::<()>();
        let conn_ptr = ConnPtr(connection);
        let recv_thread = std::thread::spawn(move || {
            let connection = conn_ptr;
            started_tx.send(()).expect("signal recv start");
            let mut buf = [0u8; 16];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection.0,
                    buf.as_mut_ptr(),
                    buf.len(),
                    0,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            // Local close surfaces as ConnectionLost; losing the race to the
            // registry removal surfaces as InvalidArgument; a FIN that beat
            // the close would surface as EOF. All are prompt, none are UB.
            assert!(
                read == 0
                    || (read == -1
                        && (err.kind() == CmuxIrohErrorKind::ConnectionLost as i32
                            || err.kind() == CmuxIrohErrorKind::InvalidArgument as i32)),
                "unexpected recv result {read} kind {} ({})",
                err.kind(),
                err.message()
            );
        });

        started_rx.recv().expect("recv thread started");
        cmux_iroh_connection_close(connection);
        recv_thread.join().expect("recv thread joins promptly");

        // Closed handle: further calls fail cleanly, double close no-ops.
        let mut buf = [0u8; 4];
        let mut err = ErrOut::new();
        let read = unsafe {
            cmux_iroh_connection_recv(
                connection,
                buf.as_mut_ptr(),
                buf.len(),
                100,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(read, -1);
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
        cmux_iroh_connection_close(connection);

        accept_thread.join().expect("accept thread joins");
        cmux_iroh_endpoint_close(dialer);
        cmux_iroh_endpoint_close(listener);
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one deliberate scenario: poisoned send, abort close, peer recv reports an error"
    )]
    fn close_after_poisoned_send_errors_peer_recv_instead_of_eof() {
        let listener_key = generate_key();
        let dialer_key = generate_key();
        let listener = bind(&listener_key, true);
        let dialer = bind(&dialer_key, false);

        let listener_id = take_string(cmux_iroh_endpoint_id(listener));
        let route = take_string(cmux_iroh_endpoint_route_json(listener));
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        let direct_addrs: Vec<String> = parsed["endpoint"]["direct_addrs"]
            .as_array()
            .expect("direct_addrs is an array")
            .iter()
            .map(|value| value.as_str().expect("addr is a string").to_owned())
            .collect();

        let (opener_read_tx, opener_read_rx) = std::sync::mpsc::channel::<()>();
        let listener_ptr = ListenerPtr(listener);
        let accept_thread = std::thread::spawn(move || {
            let listener = listener_ptr;
            let mut err = ErrOut::new();
            let connection = unsafe {
                cmux_iroh_endpoint_accept(
                    listener.0,
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert!(!connection.is_null(), "accept: {}", err.message());

            // Read the opener byte first so the dialer's abort close below
            // cannot race the delivery of in-flight stream data.
            let mut buf = [0u8; 16];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(read, 1, "opener recv: {}", err.message());
            opener_read_tx.send(()).expect("signal opener read");

            // The dialer closes after a poisoned send: that must surface as
            // an error, never as a clean end of stream (read == 0), or a
            // truncated write would read as a complete message.
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
                    30_000,
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(read, -1, "poisoned close must not read as clean EOF");
            assert_eq!(
                err.kind(),
                CmuxIrohErrorKind::ConnectionLost as i32,
                "kind {} ({})",
                err.kind(),
                err.message()
            );
            cmux_iroh_connection_close(connection);
        });

        let id_cstr = CString::new(listener_id).expect("cstring");
        let addr_cstrs: Vec<CString> = direct_addrs
            .iter()
            .map(|addr| CString::new(addr.as_str()).expect("cstring"))
            .collect();
        let addr_ptrs: Vec<*const c_char> = addr_cstrs.iter().map(|addr| addr.as_ptr()).collect();
        let mut err = ErrOut::new();
        let connection = unsafe {
            cmux_iroh_endpoint_connect(
                dialer,
                id_cstr.as_ptr(),
                ptr::null(),
                addr_ptrs.as_ptr(),
                addr_ptrs.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert!(!connection.is_null(), "connect: {}", err.message());

        let opener = [0x42u8; 1];
        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                connection,
                opener.as_ptr(),
                opener.len(),
                30_000,
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, 0, "opener send: {}", err.message());
        opener_read_rx.recv().expect("listener read opener");

        // Force the poisoned state directly: deterministically provoking a
        // real send timeout would need a peer wedged on flow control. The
        // flag is exactly what a timed-out send sets before returning.
        let Ok(inner) = lookup_connection(connection) else {
            panic!("live connection handle");
        };
        inner.send_poisoned.store(true, Ordering::Relaxed);
        drop(inner);
        cmux_iroh_connection_close(connection);

        accept_thread.join().expect("accept thread joins");
        cmux_iroh_endpoint_close(dialer);
        cmux_iroh_endpoint_close(listener);
    }

    /// Raw endpoint pointer that may cross threads: the underlying iroh endpoint
    /// is internally synchronized and the FFI contract already requires callers
    /// (Swift actors) to serialize per-handle usage sensibly.
    struct ListenerPtr(*mut CmuxIrohEndpoint);
    unsafe impl Send for ListenerPtr {}

    /// Raw connection handle crossing threads; same registry-key reasoning as
    /// [`ListenerPtr`].
    struct ConnPtr(*mut CmuxIrohConnection);
    unsafe impl Send for ConnPtr {}
}
