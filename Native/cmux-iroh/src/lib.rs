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
//! `Packages/CmuxIrohFFI/Sources/CmuxIrohFFI/include/cmux_iroh_ffi.h` (the
//! `SwiftPM` package that wraps the staticlib and exposes the `CmuxIrohFFI`
//! module) and must stay in sync with this file.

use std::{
    ffi::{CStr, CString, c_char},
    io,
    net::SocketAddr,
    os::raw::c_int,
    ptr,
    str::FromStr,
    sync::OnceLock,
    time::Duration,
};

use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr,
    endpoint::{
        Connection, ConnectionError, ReadError, RecvStream, SendStream, WriteError, presets,
    },
};
use tokio::{runtime::Runtime, sync::Mutex};

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

pub struct CmuxIrohEndpoint {
    endpoint: Endpoint,
}

pub struct CmuxIrohConnection {
    connection: Connection,
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
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
        Ok(endpoint) => Box::into_raw(Box::new(CmuxIrohEndpoint { endpoint })),
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
/// Free with `cmux_iroh_string_free`. Null if `endpoint` is null.
///
/// # Safety
///
/// `endpoint`, when non-null, must be a live pointer returned by
/// `cmux_iroh_endpoint_bind` that has not been closed.
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn cmux_iroh_endpoint_id(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    // SAFETY: caller guarantees `endpoint` is null or live.
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        return ptr::null_mut();
    };
    string_to_c(endpoint.endpoint.id().to_string())
}

/// Returns a `CmxAttachRoute`-shaped JSON object for this endpoint
/// (id, direct addrs, relay URL). Free with `cmux_iroh_string_free`.
///
/// # Safety
///
/// `endpoint`, when non-null, must be a live pointer returned by
/// `cmux_iroh_endpoint_bind` that has not been closed.
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn cmux_iroh_endpoint_route_json(
    endpoint: *const CmuxIrohEndpoint,
) -> *mut c_char {
    // SAFETY: caller guarantees `endpoint` is null or live.
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
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
///
/// # Safety
///
/// - `endpoint`, when non-null, must be live (see `cmux_iroh_endpoint_bind`).
/// - Error out-params as on `cmux_iroh_endpoint_bind`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_endpoint_online(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    clear_error(err_kind, err_buf, err_cap);
    // SAFETY: caller guarantees `endpoint` is null or live.
    let result = match unsafe { endpoint.as_ref() } {
        Some(endpoint) => online_impl(endpoint, timeout_ms),
        None => Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            "null endpoint",
        )),
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn online_impl(endpoint: &CmuxIrohEndpoint, timeout_ms: u64) -> Result<(), FfiError> {
    runtime()?
        .block_on(async {
            tokio::time::timeout(
                Duration::from_millis(timeout_ms.max(1)),
                endpoint.endpoint.online(),
            )
            .await
        })
        .map_err(|_| {
            FfiError::new(
                CmuxIrohErrorKind::Timeout,
                "timed out waiting for relay connection",
            )
        })
}

/// Accepts one incoming connection and its first bidirectional stream.
/// Blocks up to `timeout_ms`. Returns null on failure/timeout.
///
/// # Safety
///
/// - `endpoint`, when non-null, must be live (see `cmux_iroh_endpoint_bind`).
/// - Error out-params as on `cmux_iroh_endpoint_bind`.
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
    // SAFETY: caller guarantees `endpoint` is null or live.
    let result = match unsafe { endpoint.as_ref() } {
        Some(endpoint) => accept_impl(endpoint, timeout_ms),
        None => Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            "null endpoint",
        )),
    };
    finish_connection(result, err_kind, err_buf, err_cap)
}

fn accept_impl(
    endpoint: &CmuxIrohEndpoint,
    timeout_ms: u64,
) -> Result<(Connection, SendStream, RecvStream), FfiError> {
    runtime()?.block_on(async {
        tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), async {
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
        .await
        .map_err(|_| FfiError::new(CmuxIrohErrorKind::Timeout, "accept timed out"))?
    })
}

/// Dials `endpoint_id` (optionally with relay URL / direct addr hints) and
/// opens one bidirectional stream. With no hints, n0 discovery resolves the
/// id. Returns null on failure/timeout.
///
/// # Safety
///
/// - `endpoint`, when non-null, must be live (see `cmux_iroh_endpoint_bind`).
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
    // SAFETY: caller guarantees `endpoint` is null or live.
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        return Err(FfiError::new(
            CmuxIrohErrorKind::InvalidArgument,
            "null endpoint",
        ));
    };
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
                continue;
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
        tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), async {
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
        .await
        .map_err(|_| FfiError::new(CmuxIrohErrorKind::Timeout, "connect timed out"))?
    })
}

/// Receives up to `cap` bytes. Returns bytes read (>0), 0 on clean end of
/// stream, or -1 on error.
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
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> isize {
    clear_error(err_kind, err_buf, err_cap);
    // SAFETY: caller guarantees `connection` is null or live.
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        report_error(
            err_kind,
            err_buf,
            err_cap,
            &FfiError::new(CmuxIrohErrorKind::InvalidArgument, "null connection"),
        );
        return -1;
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
    match recv_impl(connection, slice) {
        Ok(read) => isize::try_from(read).unwrap_or(isize::MAX),
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn recv_impl(connection: &CmuxIrohConnection, buf: &mut [u8]) -> Result<usize, FfiError> {
    let result = runtime()?.block_on(async {
        let mut recv = connection.recv.lock().await;
        recv.read(buf).await
    });
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
    err_kind: *mut i32,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    clear_error(err_kind, err_buf, err_cap);
    // SAFETY: caller guarantees `connection` is null or live.
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        report_error(
            err_kind,
            err_buf,
            err_cap,
            &FfiError::new(CmuxIrohErrorKind::InvalidArgument, "null connection"),
        );
        return -1;
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
    match send_impl(connection, slice) {
        Ok(()) => 0,
        Err(error) => {
            report_error(err_kind, err_buf, err_cap, &error);
            -1
        }
    }
}

fn send_impl(connection: &CmuxIrohConnection, bytes: &[u8]) -> Result<(), FfiError> {
    let result = runtime()?.block_on(async {
        let mut send = connection.send.lock().await;
        send.write_all(bytes).await
    });
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
/// # Safety
///
/// `connection`, when non-null, must be a live pointer returned by this
/// library; it must not be used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_connection_close(connection: *mut CmuxIrohConnection) {
    if connection.is_null() {
        return;
    }
    // SAFETY: caller passes ownership of a live connection pointer.
    let connection = unsafe { Box::from_raw(connection) };
    let Ok(runtime) = runtime() else {
        return;
    };
    runtime.block_on(async {
        let mut send = connection.send.lock().await;
        if send.finish().is_ok() {
            let _ = tokio::time::timeout(Duration::from_secs(5), send.stopped()).await;
        }
        drop(send);
        connection.connection.close(0u32.into(), b"close");
    });
}

/// Closes the endpoint and frees its handle. Null is a no-op.
///
/// # Safety
///
/// `endpoint`, when non-null, must be a live pointer returned by
/// `cmux_iroh_endpoint_bind`; it must not be used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_endpoint_close(endpoint: *mut CmuxIrohEndpoint) {
    if endpoint.is_null() {
        return;
    }
    // SAFETY: caller passes ownership of a live endpoint pointer.
    let endpoint = unsafe { Box::from_raw(endpoint) };
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
        Ok((connection, send, recv)) => Box::into_raw(Box::new(CmuxIrohConnection {
            connection,
            send: Mutex::new(send),
            recv: Mutex::new(recv),
        })),
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
        let bound = take_string(unsafe { cmux_iroh_endpoint_id(endpoint) });
        assert_eq!(
            bound, derived,
            "bound endpoint must use the caller-provided key"
        );

        let route = take_string(unsafe { cmux_iroh_endpoint_route_json(endpoint) });
        let parsed: serde_json::Value = serde_json::from_str(&route).expect("route JSON parses");
        assert_eq!(parsed["kind"], "iroh");
        assert_eq!(parsed["endpoint"]["type"], "peer");
        assert_eq!(parsed["endpoint"]["id"], derived.as_str());

        unsafe { cmux_iroh_endpoint_close(endpoint) };
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

        unsafe { cmux_iroh_endpoint_close(endpoint) };
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one deliberate end-to-end scenario: bind two endpoints, dial, roundtrip, clean close"
    )]
    fn loopback_connect_roundtrip_and_clean_close() {
        let listener_key = generate_key();
        let dialer_key = generate_key();

        let listener = bind(&listener_key, true);
        let dialer = bind(&dialer_key, false);

        let listener_id = take_string(unsafe { cmux_iroh_endpoint_id(listener) });
        let route = take_string(unsafe { cmux_iroh_endpoint_route_json(listener) });
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

            // Echo one message back.
            let mut buf = [0u8; 64];
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
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
                    &raw mut err.kind,
                    err.buf.as_mut_ptr(),
                    ERR_CAP,
                )
            };
            assert_eq!(rc, 0, "echo send should succeed: {}", err.message());

            // The dialer closes first; recv should then report clean end of
            // stream (0), not an error.
            let mut err = ErrOut::new();
            let read = unsafe {
                cmux_iroh_connection_recv(
                    connection,
                    buf.as_mut_ptr(),
                    buf.len(),
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

            unsafe { cmux_iroh_connection_close(connection) };
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

        let payload = b"cmux iroh ffi seam roundtrip";
        let mut err = ErrOut::new();
        let rc = unsafe {
            cmux_iroh_connection_send(
                connection,
                payload.as_ptr(),
                payload.len(),
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

        unsafe { cmux_iroh_connection_close(connection) };
        accept_thread.join().expect("accept thread joins cleanly");

        unsafe { cmux_iroh_endpoint_close(dialer) };
        unsafe { cmux_iroh_endpoint_close(listener) };
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
                &raw mut err.kind,
                err.buf.as_mut_ptr(),
                ERR_CAP,
            )
        };
        assert_eq!(rc, -1);
        assert_eq!(err.kind(), CmuxIrohErrorKind::InvalidArgument as i32);
    }

    /// Raw endpoint pointer that may cross threads: the underlying iroh endpoint
    /// is internally synchronized and the FFI contract already requires callers
    /// (Swift actors) to serialize per-handle usage sensibly.
    struct ListenerPtr(*mut CmuxIrohEndpoint);
    unsafe impl Send for ListenerPtr {}
}
