//! Small pointer/length C ABI over [`crate::Client`]. The caller owns all
//! buffers returned here and must free them with [`acpmux_client_bytes_free`].

use crate::{Change, Client};
use serde_json::{Value, json};
use std::ffi::c_void;

pub const ABI_VERSION: u32 = 1;

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
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(-4)
}

unsafe fn input(ptr: *const u8, len: usize) -> Result<&'static [u8], i32> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(-1);
    }
    // SAFETY: the C caller promises `len` readable bytes at `ptr` for this call.
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn output(out: *mut Bytes, bytes: Vec<u8>) -> i32 {
    if out.is_null() {
        return -1;
    }
    // SAFETY: the caller supplied writable storage for one Bytes value.
    unsafe {
        *out = Bytes::from_vec(bytes);
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn acpmux_client_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn acpmux_client_new() -> *mut c_void {
    Box::into_raw(Box::new(Client::<Value>::new(["list"]))) as *mut c_void
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_free(handle: *mut c_void) {
    if !handle.is_null() {
        // SAFETY: handle was returned by acpmux_client_new and is consumed once.
        drop(unsafe { Box::from_raw(handle.cast::<Client<Value>>()) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_connected(handle: *mut c_void) -> i32 {
    guarded(|| {
        if handle.is_null() {
            return -1;
        }
        // SAFETY: caller serializes access to the owned handle.
        unsafe {
            (*handle.cast::<Client<Value>>()).connected();
        }
        0
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_disconnected(handle: *mut c_void) -> i32 {
    guarded(|| {
        if handle.is_null() {
            return -1;
        }
        // SAFETY: caller serializes access to the owned handle.
        unsafe {
            (*handle.cast::<Client<Value>>()).disconnected();
        }
        0
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_received(
    handle: *mut c_void,
    ptr: *const u8,
    len: usize,
    consumed: *mut usize,
) -> i32 {
    guarded(|| {
        if handle.is_null() || consumed.is_null() {
            return -1;
        }
        // SAFETY: input validates the caller's pointer and length.
        let bytes = match unsafe { input(ptr, len) } {
            Ok(bytes) => bytes,
            Err(code) => return code,
        };
        // SAFETY: caller serializes access to the owned handle and consumed is writable.
        let n = unsafe { (*handle.cast::<Client<Value>>()).received(bytes) };
        unsafe {
            *consumed = n;
        }
        0
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_take_send(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        if handle.is_null() || out.is_null() {
            return -1;
        }
        // SAFETY: caller serializes access to the owned handle.
        let bytes = unsafe { (*handle.cast::<Client<Value>>()).take_send().unwrap_or_default() };
        output(out, bytes)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_next_change(handle: *mut c_void, out: *mut Bytes) -> i32 {
    guarded(|| {
        if handle.is_null() || out.is_null() {
            return -1;
        }
        // SAFETY: caller serializes access to the owned handle.
        let Some(change) = (unsafe { (*handle.cast::<Client<Value>>()).next_change() }) else {
            return output(out, Vec::new());
        };
        let value = match change {
            Change::Window(window) => serde_json::to_value(window),
            Change::Summary { sid, seq, summary } => {
                Ok(json!({"kind":"summary","sid":sid,"seq":seq,"summary":summary}))
            }
            Change::Gone { sid, seq, chat_id, why } => {
                Ok(json!({"kind":"gone","sid":sid,"seq":seq,"chatId":chat_id,"why":why}))
            }
            Change::Origin { sid, seq, origin } => {
                Ok(json!({"kind":"origin","sid":sid,"seq":seq,"origin":origin}))
            }
            Change::Queue { sid, seq, bytes } => {
                Ok(json!({"kind":"queue","sid":sid,"seq":seq,"bytes":bytes}))
            }
            Change::ResumeEnd { sid, cursor } => {
                Ok(json!({"kind":"resumeEnd","sid":sid,"cursor":cursor.0}))
            }
            Change::Unconfirmed { sid } => Ok(json!({"kind":"unconfirmed","sid":sid})),
            Change::Dropped { sid, cursor } => {
                Ok(json!({"kind":"dropped","sid":sid,"cursor":cursor.map(|c| c.0)}))
            }
            Change::Error { method, sid, id, code } => {
                Ok(json!({"kind":"error","method":method,"sid":sid,"id":id,"code":code}))
            }
            Change::Fallback(bytes) => Ok(json!({"kind":"fallback","bytes":bytes})),
        };
        let bytes = match value {
            Ok(value) => serde_json::to_vec(&value).unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        output(out, bytes)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn acpmux_client_bytes_free(bytes: Bytes) {
    if !bytes.ptr.is_null() {
        // SAFETY: ptr/len came from Bytes::from_vec and are freed once.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
    }
}
