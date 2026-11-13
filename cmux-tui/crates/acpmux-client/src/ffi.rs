//! Pointer/length C ABI for the no-I/O client core.
//!
//! The caller owns one handle, drives it from one thread, and frees every
//! returned buffer with [`acpmux_client_bytes_free`]. No Rust panic crosses
//! the ABI boundary.

use crate::wire::{Page, Sub};
use crate::{Change, Client};
use serde_json::{Value, json};
use std::ffi::c_void;

/// ABI version. Bump this when a type or function changes.
pub const ACPMUX_CLIENT_ABI_VERSION: u32 = 2;
/// The call succeeded.
pub const ACPMUX_CLIENT_OK: i32 = 0;
/// A required pointer was null.
pub const ACPMUX_CLIENT_ERR_NULL: i32 = -1;
/// Input JSON was invalid or a request was rejected.
pub const ACPMUX_CLIENT_ERR_INVALID: i32 = -2;
/// The requested operation is not known by this ABI.
pub const ACPMUX_CLIENT_ERR_UNKNOWN: i32 = -3;
/// A panic was caught inside the ABI boundary.
pub const ACPMUX_CLIENT_ERR_PANIC: i32 = -4;

#[repr(C)]
pub struct Bytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl Bytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast(), len }
    }
}

fn guarded(f: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(ACPMUX_CLIENT_ERR_PANIC)
}

unsafe fn input<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], i32> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(ACPMUX_CLIENT_ERR_NULL);
    }
    // SAFETY: the caller promises `len` readable bytes at `ptr` for this call.
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn output(out: *mut Bytes, bytes: Vec<u8>) -> i32 {
    if out.is_null() {
        return ACPMUX_CLIENT_ERR_NULL;
    }
    // SAFETY: every caller checks `out`; the C caller owns the written value.
    unsafe { *out = Bytes::from_vec(bytes) };
    ACPMUX_CLIENT_OK
}

fn handle_mut<'a>(handle: *mut c_void) -> Result<&'a mut Client<Value>, i32> {
    if handle.is_null() {
        return Err(ACPMUX_CLIENT_ERR_NULL);
    }
    // SAFETY: the caller owns the handle and serializes calls.
    Ok(unsafe { &mut *handle.cast::<Client<Value>>() })
}

fn request_bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], i32> {
    // SAFETY: forwarded pointer/length contract.
    unsafe { input(ptr, len) }
}

fn change_json(change: Change<Value>) -> Result<Value, serde_json::Error> {
    match change {
        Change::Window(window) => serde_json::to_value(window),
        Change::Page(page) => serde_json::to_value(json!({ "kind": "page", "page": page })),
        Change::FolderWindow(window) => serde_json::to_value(window),
        Change::FolderPage(page) => Ok(json!({"kind":"folderPage","page":page})),
        Change::Folder { sid, seq, row, replay } => {
            Ok(json!({"kind":"folder","sid":sid,"seq":seq,"row":row,"replay":replay}))
        }
        Change::FolderGone { sid, seq, origin, folder, replay } => Ok(
            json!({"kind":"folderGone","sid":sid,"seq":seq,"origin":origin,"folder":folder,"replay":replay}),
        ),
        Change::Summary { sid, seq, summary, replay } => {
            Ok(json!({"kind":"summary","sid":sid,"seq":seq,"summary":summary,"replay":replay}))
        }
        Change::Left { sid, seq, summary, replay } => {
            Ok(json!({"kind":"left","sid":sid,"seq":seq,"summary":summary,"replay":replay}))
        }
        Change::Gone { sid, seq, origin, chat_id, why, replay } => Ok(
            json!({"kind":"gone","sid":sid,"seq":seq,"origin":origin,"chatId":chat_id,"why":why,"replay":replay}),
        ),
        Change::Origin { sid, seq, origin, replay } => {
            Ok(json!({"kind":"origin","sid":sid,"seq":seq,"origin":origin,"replay":replay}))
        }
        Change::Queue { sid, seq, bytes, replay } => {
            Ok(json!({"kind":"queue","sid":sid,"seq":seq,"bytes":bytes,"replay":replay}))
        }
        Change::ResumeEnd { sid, cursor } => {
            Ok(json!({"kind":"resumeEnd","sid":sid,"cursor":cursor.0}))
        }
        Change::Unconfirmed { sid } => Ok(json!({"kind":"unconfirmed","sid":sid})),
        Change::Whole { sid, cursor } => Ok(json!({"kind":"whole","sid":sid,"cursor":cursor.0})),
        Change::Dropped { sid, cursor, new_sid } => {
            Ok(json!({"kind":"dropped","sid":sid,"cursor":cursor.map(|c| c.0),"newSid":new_sid}))
        }
        Change::Error { method, sid, id, code } => {
            Ok(json!({"kind":"error","method":method,"sid":sid,"id":id,"code":code}))
        }
        Change::Fallback(bytes) => Ok(json!({"kind":"fallback","bytes":bytes})),
    }
}

/// Returns this ABI's version.
#[unsafe(no_mangle)]
pub extern "C" fn acpmux_client_abi_version() -> u32 {
    ACPMUX_CLIENT_ABI_VERSION
}

/// Allocates a list-surface client.
#[unsafe(no_mangle)]
pub extern "C" fn acpmux_client_new() -> *mut c_void {
    Box::into_raw(Box::new(Client::<Value>::new(["list"]))).cast()
}

/// Frees a handle returned by [`acpmux_client_new`].
///
/// # Safety
/// `handle` is null or was returned by this library and is consumed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_free(handle: *mut c_void) {
    if !handle.is_null() {
        // SAFETY: ownership and provenance are the documented ABI contract.
        drop(unsafe { Box::from_raw(handle.cast::<Client<Value>>()) });
    }
}

/// Marks the transport connected.
///
/// # Safety
/// `handle` is null or an owned handle, and calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_connected(handle: *mut c_void) -> i32 {
    guarded(|| {
        handle_mut(handle).map_or_else(
            |e| e,
            |client| {
                client.connected();
                ACPMUX_CLIENT_OK
            },
        )
    })
}

/// Marks the transport disconnected while retaining subscriptions.
///
/// # Safety
/// `handle` is null or an owned handle, and calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_disconnected(handle: *mut c_void) -> i32 {
    guarded(|| {
        handle_mut(handle).map_or_else(
            |e| e,
            |client| {
                client.disconnected();
                ACPMUX_CLIENT_OK
            },
        )
    })
}

/// Feeds bytes and writes the number consumed to `consumed`.
///
/// # Safety
/// `handle` and `consumed` are writable owned pointers; `ptr..ptr+len` is
/// readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_received(
    handle: *mut c_void,
    ptr: *const u8,
    len: usize,
    consumed: *mut usize,
) -> i32 {
    guarded(|| {
        if consumed.is_null() {
            return ACPMUX_CLIENT_ERR_NULL;
        }
        let bytes = match request_bytes(ptr, len) {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        let amount = client.received(bytes);
        // SAFETY: checked non-null and caller owns the output slot.
        unsafe { *consumed = amount };
        ACPMUX_CLIENT_OK
    })
}

/// Takes one queued outbound frame.
///
/// # Safety
/// `handle` and `out` are owned pointers; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_take_send(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        output(out, client.take_send().unwrap_or_default())
    })
}

/// Takes one typed change encoded as JSON; an empty buffer means no change.
///
/// # Safety
/// `handle` and `out` are owned pointers; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_next_change(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        let Some(change) = client.next_change() else { return output(out, Vec::new()) };
        let value = match change_json(change) {
            Ok(value) => value,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        match serde_json::to_vec(&value) {
            Ok(bytes) => output(out, bytes),
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Subscribes from a JSON `Sub` request and returns the sid as JSON bytes.
///
/// # Safety
/// `handle`, `out` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_subscribe(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        let bytes = match request_bytes(request, request_len) {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let sub = match serde_json::from_slice::<Sub>(bytes) {
            Ok(sub) => sub,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        match client.subscribe(sub) {
            Ok(sid) => output(out, serde_json::to_vec(&json!({"sid":sid})).unwrap_or_default()),
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Unsubscribes the sid in a JSON string or `{ "sid": ... }` object.
///
/// # Safety
/// `handle` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_unsubscribe(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        let bytes = match request_bytes(request, request_len) {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let value = match serde_json::from_slice::<Value>(bytes) {
            Ok(value) => value,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        let sid = value.as_str().or_else(|| value.get("sid").and_then(Value::as_str));
        let Some(sid) = sid else { return ACPMUX_CLIENT_ERR_INVALID };
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        client.unsubscribe(sid).map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
    })
}

/// Queues a page request encoded as JSON.
///
/// # Safety
/// `handle` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_page(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        let bytes = match request_bytes(request, request_len) {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let page = match serde_json::from_slice::<Page>(bytes) {
            Ok(page) => page,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        let client = match handle_mut(handle) {
            Ok(client) => client,
            Err(error) => return error,
        };
        client.page(page).map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
    })
}

/// Frees a buffer previously returned by this ABI.
///
/// # Safety
/// `bytes` came from this library and is freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_bytes_free(bytes: Bytes) {
    if !bytes.ptr.is_null() {
        // SAFETY: pointer and length came from `Bytes::from_vec`.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
    }
}
