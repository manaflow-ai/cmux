//! Pointer/length C ABI for the no-I/O client core.
//!
//! The caller owns one handle, drives it from one thread, and frees every
//! returned buffer with [`acpmux_client_bytes_free`]. No Rust panic crosses
//! the ABI boundary.

use crate::chat::{ChatBlobRequest, ChatChange, ChatPageRequest, ChatSubRequest};
use crate::page::{
    CloseRequest, DriverError, InvalidCode, ListDriver, MAX_REQUEST_BYTES, NextRequest,
    OpenRequest, PageRequest,
};
use crate::wire::{FolderPageResult, FolderWindow, ListKey, Page, Sub};
use crate::{Change, Client};
use serde_json::{Value, json};
use std::ffi::c_void;

/// JSON shapes emitted by the C ABI for folder list changes.
///
/// Folder windows retain their existing top-level fields and add a
/// discriminator so an empty folder window cannot be mistaken for an empty
/// summary window. The other shapes retain the established `folderPage`,
/// `folder`, and `folderGone` payloads.
#[derive(Clone, Debug, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FolderChangeJson {
    #[serde(rename = "folderWindow")]
    FolderWindow {
        #[serde(flatten)]
        window: FolderWindow,
    },
    #[serde(rename = "folderPage")]
    FolderPage { page: FolderPageResult },
    #[serde(rename = "folder")]
    Folder { sid: String, seq: u64, row: crate::wire::FolderRow, replay: bool },
    #[serde(rename = "folderGone")]
    FolderGone { sid: String, seq: u64, origin: String, folder: String, replay: bool },
}

/// ABI version. Bump this when a type or function changes. 4: the page-list driver ABI.
pub const ACPMUX_CLIENT_ABI_VERSION: u32 = 4;
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
/// The page operation is busy with another batch or question.
pub const ACPMUX_PAGE_ERR_BUSY: i32 = -5;
/// A page operation exceeded a bounded list limit.
pub const ACPMUX_PAGE_ERR_LIMIT: i32 = -6;
/// The page operation named no open sid or question.
pub const ACPMUX_PAGE_ERR_SID: i32 = -7;
/// The page operation was refused by its page contract.
pub const ACPMUX_PAGE_ERR_REQUEST: i32 = -8;

fn page_error(error: DriverError) -> i32 {
    match error {
        DriverError::Busy => ACPMUX_PAGE_ERR_BUSY,
        DriverError::Limit(_) => ACPMUX_PAGE_ERR_LIMIT,
        DriverError::MissingQuestion => ACPMUX_PAGE_ERR_SID,
        DriverError::Invalid(InvalidCode::Sid) => ACPMUX_PAGE_ERR_SID,
        DriverError::Invalid(
            InvalidCode::Request | InvalidCode::Page | InvalidCode::Unsupported,
        ) => ACPMUX_PAGE_ERR_REQUEST,
        DriverError::Invalid(InvalidCode::Protocol(_)) => ACPMUX_CLIENT_ERR_INVALID,
    }
}

pub fn page_error_text(status: i32) -> Option<&'static str> {
    match status {
        ACPMUX_PAGE_ERR_BUSY => Some("list.busy"),
        ACPMUX_PAGE_ERR_LIMIT => Some("list.limit"),
        ACPMUX_PAGE_ERR_SID => Some("list.sid"),
        ACPMUX_PAGE_ERR_REQUEST => Some("list.request"),
        _ => None,
    }
}

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

/// # Safety
/// `ptr..ptr+len` must be readable for the duration of the call, or `len` must be zero.
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

/// Writes `bytes` to `*out` as a buffer the C caller frees with
/// [`acpmux_client_bytes_free`]; a NULL `out` is refused.
///
/// # Safety
/// `out` is NULL or aligned and valid for a write of one `Bytes`. The value
/// already there is overwritten, not freed.
unsafe fn output(out: *mut Bytes, bytes: Vec<u8>) -> i32 {
    if out.is_null() {
        return ACPMUX_CLIENT_ERR_NULL;
    }
    // SAFETY: checked non-NULL; aligned and writable by this function's contract.
    unsafe { *out = Bytes::from_vec(bytes) };
    ACPMUX_CLIENT_OK
}

/// The client behind `handle`; `ACPMUX_CLIENT_ERR_NULL` for NULL.
///
/// # Safety
/// `handle` is NULL or came from [`acpmux_client_new`] or
/// [`acpmux_client_new_with_surfaces`] and has not been freed, so it is aligned and
/// points to a live client. Nothing else reads or writes that client while the
/// returned `&mut` lives, and `'a` ends before the handle is freed.
unsafe fn handle_mut<'a>(handle: *mut c_void) -> Result<&'a mut Client<Value>, i32> {
    if handle.is_null() {
        return Err(ACPMUX_CLIENT_ERR_NULL);
    }
    // SAFETY: checked non-NULL; live, aligned and unaliased for `'a` by this function's contract.
    Ok(unsafe { &mut *handle.cast::<Client<Value>>() })
}

/// The page driver behind `handle`; `ACPMUX_CLIENT_ERR_NULL` for NULL.
///
/// # Safety
/// `handle` is NULL or came from [`acpmux_page_driver_new`] and has not been freed,
/// so it is aligned and points to a live driver. Nothing else reads or writes that
/// driver while the returned `&mut` lives, and `'a` ends before the handle is freed.
unsafe fn page_driver_mut<'a>(handle: *mut c_void) -> Result<&'a mut ListDriver, i32> {
    if handle.is_null() {
        return Err(ACPMUX_CLIENT_ERR_NULL);
    }
    // SAFETY: checked non-NULL; live, aligned and unaliased for `'a` by this function's contract.
    Ok(unsafe { &mut *handle.cast::<ListDriver>() })
}

/// Borrows the `len` request bytes at `ptr`; NULL is refused unless `len` is 0.
///
/// # Safety
/// `len` is 0, or `ptr..ptr+len` is readable and not written for `'a`.
unsafe fn request_bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], i32> {
    // SAFETY: this function's contract is `input`'s, passed on.
    unsafe { input(ptr, len) }
}

#[derive(serde::Deserialize)]
struct MirrorRequest {
    sub: Sub,
    #[serde(default)]
    held: Vec<ListKey>,
    #[serde(default)]
    whole: bool,
}

#[derive(serde::Deserialize)]
struct KeysRequest {
    sid: String,
    #[serde(default)]
    keys: Vec<ListKey>,
}

fn change_json(change: Change<Value>) -> Result<Value, serde_json::Error> {
    match change {
        Change::Window(window) => serde_json::to_value(window),
        Change::Page(page) => serde_json::to_value(json!({ "kind": "page", "page": page })),
        Change::FolderWindow(window) => {
            serde_json::to_value(FolderChangeJson::FolderWindow { window })
        }
        Change::FolderPage(page) => serde_json::to_value(FolderChangeJson::FolderPage { page }),
        Change::Folder { sid, seq, row, replay } => {
            serde_json::to_value(FolderChangeJson::Folder { sid, seq, row, replay })
        }
        Change::FolderGone { sid, seq, origin, folder, replay } => {
            serde_json::to_value(FolderChangeJson::FolderGone { sid, seq, origin, folder, replay })
        }
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
        Change::Chat(change) => serde_json::to_value(change),
    }
}

/// A change's bytes. A chat change is written from its rows' bytes as they arrived, never through
/// a `Value`; a blob change is its JSON, a newline, then the bytes.
fn change_bytes(change: Change<Value>) -> Result<Vec<u8>, serde_json::Error> {
    let change = match change {
        Change::Chat(change) => change,
        other => return serde_json::to_vec(&change_json(other)?),
    };
    let mut out = serde_json::to_vec(&change)?;
    if let ChatChange::Blob { bytes, .. } = &change {
        out.reserve(1 + bytes.len());
        out.push(b'\n');
        out.extend_from_slice(bytes);
    }
    Ok(out)
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

/// Allocates a client whose upgrade names the surfaces in a JSON array, such as
/// `["list","chat"]`; null when the input is not one. One handle carries list and chat subs.
/// A daemon with any named surface off answers the upgrade as v1, so a host names only the
/// surfaces it uses.
///
/// # Safety
/// `ptr..ptr+len` is readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_new_with_surfaces(
    ptr: *const u8,
    len: usize,
) -> *mut c_void {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // SAFETY: `ptr` holds `len` readable bytes, by this function's contract.
        let surfaces = unsafe { request_bytes(ptr, len) }
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Vec<String>>(bytes).ok());
        surfaces.map_or(std::ptr::null_mut(), |surfaces| {
            Box::into_raw(Box::new(Client::<Value>::new(surfaces))).cast()
        })
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a handle returned by [`acpmux_client_new`] or [`acpmux_client_new_with_surfaces`].
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
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        unsafe { handle_mut(handle) }.map_or_else(
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
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        unsafe { handle_mut(handle) }.map_or_else(
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
        // SAFETY: `ptr` holds `len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(ptr, len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
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
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
        unsafe { output(out, client.take_send().unwrap_or_default()) }
    })
}

/// Takes one typed change encoded as JSON; an empty buffer means no change.
///
/// # Safety
/// `handle` and `out` are owned pointers; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_next_change(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
        let Some(change) = client.next_change() else { return unsafe { output(out, Vec::new()) } };
        match change_bytes(change) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(bytes) => unsafe { output(out, bytes) },
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
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let sub = match serde_json::from_slice::<Sub>(bytes) {
            Ok(sub) => sub,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        match client.subscribe(sub) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(sid) => unsafe {
                output(out, serde_json::to_vec(&json!({"sid":sid})).unwrap_or_default())
            },
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Subscribes a mirror from `{ "sub": ..., "held": [...], "whole": bool }`.
/// The caller owns the returned sid buffer and frees it with
/// [`acpmux_client_bytes_free`].
///
/// # Safety
/// `handle`, `request`, and `out` must satisfy the pointer and length contract
/// for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_subscribe_mirror(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<MirrorRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        match client.subscribe_mirror(request.sub, request.held, request.whole) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(sid) => unsafe {
                output(out, serde_json::to_vec(&json!({"sid": sid})).unwrap_or_default())
            },
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Adds mirror wanted keys from `{ "sid": ..., "keys": [...] }`.
///
/// # Safety
/// `handle` and `request` must satisfy the pointer and length contract for the
/// duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_want(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<KeysRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        client
            .want(&request.sid, request.keys)
            .map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
    })
}

/// Removes mirror wanted keys from `{ "sid": ..., "keys": [...] }`.
///
/// # Safety
/// `handle` and `request` must satisfy the pointer and length contract for the
/// duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_unwant(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<KeysRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        client
            .unwant(&request.sid, request.keys)
            .map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
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
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let value = match serde_json::from_slice::<Value>(bytes) {
            Ok(value) => value,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        let sid = value.as_str().or_else(|| value.get("sid").and_then(Value::as_str));
        let Some(sid) = sid else { return ACPMUX_CLIENT_ERR_INVALID };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
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
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let page = match serde_json::from_slice::<Page>(bytes) {
            Ok(page) => page,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        client.page(page).map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
    })
}

/// Subscribes a chat from `{ "sid", "chat", "anchor"?, "window"? }` (`anchor` is `"end"` or
/// `{ "rowId", "side" }`) and returns `{ "sid" }`. Unsubscribe it with
/// [`acpmux_client_unsubscribe`].
///
/// # Safety
/// `handle`, `out` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_subscribe_chat(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let Ok(request) = serde_json::from_slice::<ChatSubRequest>(bytes) else {
            return ACPMUX_CLIENT_ERR_INVALID;
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        match client.subscribe_chat(request) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(sid) => unsafe {
                output(out, serde_json::to_vec(&json!({"sid": sid})).unwrap_or_default())
            },
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Asks a chat sub for a page from `{ "sid", "before" | "after", "fold"? | "turns"?,
/// "maxBytes"? }`. The core fills the stream and the edition.
///
/// # Safety
/// `handle` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_chat_page(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let Ok(request) = serde_json::from_slice::<ChatPageRequest>(bytes) else {
            return ACPMUX_CLIENT_ERR_INVALID;
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        client.chat_page(request).map_or(ACPMUX_CLIENT_ERR_INVALID, |_| ACPMUX_CLIENT_OK)
    })
}

/// Asks a chat sub for a range of a row's body or a waiting prompt's text, from
/// `{ "sid", "rowId" | "prompt", "start"?, "len", "from"? }`, and returns `{ "id" }`, which the
/// `chatBlob` change names.
///
/// # Safety
/// `handle`, `out` and the input slice obey the pointer/length contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_chat_blob(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let Ok(request) = serde_json::from_slice::<ChatBlobRequest>(bytes) else {
            return ACPMUX_CLIENT_ERR_INVALID;
        };
        // SAFETY: `handle` is NULL or a live client the caller owns and calls from one thread,
        // by this function's contract, so this is the only reference to it.
        let client = match unsafe { handle_mut(handle) } {
            Ok(client) => client,
            Err(error) => return error,
        };
        match client.chat_blob(request) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(id) => unsafe {
                output(out, serde_json::to_vec(&json!({"id": id})).unwrap_or_default())
            },
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
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

/// Allocates the page session-list driver. It owns a list-surface client handle and emits only
/// page events; the existing `acpmux_client_*` ABI remains available for other list callers.
#[unsafe(no_mangle)]
pub extern "C" fn acpmux_page_driver_new() -> *mut c_void {
    Box::into_raw(Box::new(ListDriver::new())).cast()
}

/// Frees a page session-list driver.
///
/// # Safety
/// `handle` is null or was returned by `acpmux_page_driver_new` and is consumed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_free(handle: *mut c_void) {
    if !handle.is_null() {
        // SAFETY: ownership and provenance are the documented ABI contract.
        drop(unsafe { Box::from_raw(handle.cast::<ListDriver>()) });
    }
}

/// Marks the page-list transport connected.
///
/// # Safety
/// `handle` is null or a live page-driver handle owned by the caller; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_connected(handle: *mut c_void) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        unsafe { page_driver_mut(handle) }.map_or_else(
            |error| error,
            |driver| {
                driver.connected();
                ACPMUX_CLIENT_OK
            },
        )
    })
}

/// Marks the page-list transport disconnected while retaining rows and wanted keys.
///
/// # Safety
/// `handle` is null or a live page-driver handle owned by the caller; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_disconnected(handle: *mut c_void) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        unsafe { page_driver_mut(handle) }.map_or_else(
            |error| error,
            |driver| {
                driver.disconnected();
                ACPMUX_CLIENT_OK
            },
        )
    })
}

/// Sets whether the page is visible. A hidden page takes no changes from its handle.
///
/// # Safety
/// `handle` is null or a live page-driver handle owned by the caller; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_visible(handle: *mut c_void, shown: bool) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        unsafe { page_driver_mut(handle) }.map_or_else(
            |error| error,
            |driver| {
                driver.set_visible(shown);
                ACPMUX_CLIENT_OK
            },
        )
    })
}

/// Feeds daemon bytes to the page-list driver and writes the consumed count.
///
/// # Safety
/// `handle` and `consumed` are owned writable pointers; `ptr..ptr+len` is readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_received(
    handle: *mut c_void,
    ptr: *const u8,
    len: usize,
    consumed: *mut usize,
) -> i32 {
    guarded(|| {
        if consumed.is_null() {
            return ACPMUX_CLIENT_ERR_NULL;
        }
        // SAFETY: `ptr` holds `len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(ptr, len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        // SAFETY: checked non-null and caller owns the output slot.
        unsafe { *consumed = driver.received(bytes) };
        ACPMUX_CLIENT_OK
    })
}

/// Takes one outbound daemon frame from the page-list driver.
///
/// # Safety
/// `handle` and `out` are owned pointers; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_take_send(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
        unsafe { output(out, driver.take_send().unwrap_or_default()) }
    })
}

/// Takes one page event batch. The returned batch remains held until `acpmux_page_driver_taken`.
///
/// # Safety
/// `handle` and `out` are owned pointers; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_next_event(
    handle: *mut c_void,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        let batch = match driver.next_batch() {
            Ok(Some(batch)) => batch,
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(None) => return unsafe { output(out, Vec::new()) },
            Err(error) => return page_error(error),
        };
        match batch.json() {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(bytes) => unsafe { output(out, bytes) },
            Err(_) => ACPMUX_CLIENT_ERR_INVALID,
        }
    })
}

/// Acknowledges one page event batch by its opaque number.
///
/// # Safety
/// `handle` is null or a live page-driver handle owned by the caller; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_taken(handle: *mut c_void, number: u64) -> i32 {
    guarded(|| {
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        unsafe { page_driver_mut(handle) }.map_or_else(
            |error| error,
            |driver| driver.taken(number).map_or_else(page_error, |_| ACPMUX_CLIENT_OK),
        )
    })
}

/// Opens a list subscription from a JSON `Sub` and returns `{ "sid": ... }`.
///
/// # Safety
/// `handle` and `out` are owned pointers; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_open(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<OpenRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        match driver.open(request) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(sid) => unsafe {
                output(out, serde_json::to_vec(&json!({"sid": sid})).unwrap_or_default())
            },
            Err(error) => page_error(error),
        }
    })
}

/// Closes a page list subscription from `{ "sid": ... }`.
///
/// # Safety
/// `handle` is null or a live page-driver handle; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_close(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<CloseRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        match request.id {
            Some(id) => driver
                .close_question(&request.sid, &id)
                .map_or_else(page_error, |_| ACPMUX_CLIENT_OK),
            None => driver.close(&request.sid).map_or_else(page_error, |_| ACPMUX_CLIENT_OK),
        }
    })
}

/// Adds wanted keys from `{ "sid": ..., "keys": [...] }`.
///
/// # Safety
/// `handle` is null or a live page-driver handle; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_want(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        if request_len > MAX_REQUEST_BYTES {
            return ACPMUX_PAGE_ERR_LIMIT;
        }
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<KeysRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        driver.want(&request.sid, request.keys).map_or_else(page_error, |_| ACPMUX_CLIENT_OK)
    })
}

/// Removes wanted keys from `{ "sid": ..., "keys": [...] }`.
///
/// # Safety
/// `handle` is null or a live page-driver handle; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_unwant(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        if request_len > MAX_REQUEST_BYTES {
            return ACPMUX_PAGE_ERR_LIMIT;
        }
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<KeysRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        driver.unwant(&request.sid, request.keys).map_or_else(page_error, |_| ACPMUX_CLIENT_OK)
    })
}

/// Starts a bounded page question from a `Page`, returning `{ "id": ... }`.
///
/// # Safety
/// `handle` and `out` are owned pointers; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_page(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut Bytes,
) -> i32 {
    guarded(|| {
        if request_len > MAX_REQUEST_BYTES {
            return ACPMUX_PAGE_ERR_LIMIT;
        }
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<PageRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        match driver.page(request) {
            // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
            Ok(id) => unsafe {
                output(out, serde_json::to_vec(&json!({"id": id})).unwrap_or_default())
            },
            Err(error) => page_error(error),
        }
    })
}

/// Requests the next page of `{ "id": ... }`; continuation remains in Rust.
///
/// # Safety
/// `handle` is null or a live page-driver handle; `request..request+request_len` is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_next(
    handle: *mut c_void,
    request: *const u8,
    request_len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: `request` holds `request_len` readable bytes, by this function's contract.
        let bytes = match unsafe { request_bytes(request, request_len) } {
            Ok(bytes) => bytes,
            Err(error) => return error,
        };
        let request = match serde_json::from_slice::<NextRequest>(bytes) {
            Ok(request) => request,
            Err(_) => return ACPMUX_CLIENT_ERR_INVALID,
        };
        // SAFETY: `handle` is NULL or a live page driver the caller owns and calls from one
        // thread, by this function's contract, so this is the only reference to it.
        let driver = match unsafe { page_driver_mut(handle) } {
            Ok(driver) => driver,
            Err(error) => return error,
        };
        driver.next(&request.sid, &request.id).map_or_else(page_error, |_| ACPMUX_CLIENT_OK)
    })
}

/// Returns the stable page error code text for a page status in `out`.
///
/// # Safety
/// `out` is an owned writable pointer; callers free its bytes with
/// `acpmux_client_bytes_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_page_driver_error_code(status: i32, out: *mut Bytes) -> i32 {
    let Some(code) = page_error_text(status) else {
        return ACPMUX_CLIENT_ERR_INVALID;
    };
    // SAFETY: `out` is NULL or a writable `Bytes` slot, by this function's contract.
    unsafe { output(out, code.as_bytes().to_vec()) }
}
