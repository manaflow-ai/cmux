//! An FSEvents stream over one folder, whole, with a coalescing latency (macOS).
//!
//! notify's FSEvents watcher has latency 0: each change below the folder wakes its thread on its
//! own. A Claude Code project folder holds every subagent's transcript and every tool's result,
//! which a running agent writes several times a second; with 170 agents that is hundreds of
//! deliveries a second, each a wake of the daemon, though the index reads none of those files
//! (lead order, 2026-11-12). This stream asks FSEvents to coalesce:
//!
//! - `NoDefer`: the first change after a quiet `latency` is delivered at once, so a new session
//!   or a reply in a quiet chat shows as fast as before.
//! - After a delivery, further changes wait until `latency` has passed and come as one delivery
//!   with all their paths: a busy folder costs one wake per `latency`, however many files change.
//! - `FileEvents`: each changed file's own path, so the callback still drops every path the index
//!   does not read. `WatchRoot`: the folder itself moved or removed asks for a scan.
//!
//! No thread of ours: the stream runs on its own serial dispatch queue, which dropping the stream
//! stops and releases.

use std::ffi::{CStr, c_char, c_void};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

type StreamRef = *mut c_void;
type Queue = *mut c_void;
type CfRef = *const c_void;

#[repr(C)]
struct StreamContext {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

#[repr(C)]
struct ArrayCallBacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

type Callback = extern "C" fn(StreamRef, *mut c_void, usize, *mut c_void, *const u32, *const u64);

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn FSEventStreamCreate(
        allocator: CfRef,
        callback: Callback,
        context: *const StreamContext,
        paths: CfRef,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) -> StreamRef;
    fn FSEventStreamSetDispatchQueue(stream: StreamRef, queue: Queue);
    fn FSEventStreamStart(stream: StreamRef) -> u8;
    fn FSEventStreamStop(stream: StreamRef);
    fn FSEventStreamInvalidate(stream: StreamRef);
    fn FSEventStreamRelease(stream: StreamRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeArrayCallBacks: ArrayCallBacks;
    fn CFStringCreateWithBytes(
        allocator: CfRef,
        bytes: *const u8,
        len: isize,
        encoding: u32,
        external: u8,
    ) -> CfRef;
    fn CFArrayCreate(
        allocator: CfRef,
        values: *const CfRef,
        count: isize,
        callbacks: *const ArrayCallBacks,
    ) -> CfRef;
    fn CFRelease(cf: CfRef);
}

unsafe extern "C" {
    fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> Queue;
    fn dispatch_sync_f(queue: Queue, context: *mut c_void, work: extern "C" fn(*mut c_void));
    fn dispatch_release(object: Queue);
}

const SINCE_NOW: u64 = u64::MAX;
const UTF8: u32 = 0x0800_0100;
const NO_DEFER: u32 = 0x02;
const WATCH_ROOT: u32 = 0x04;
const FILE_EVENTS: u32 = 0x10;
/// Events were lost or the watched folder changed: the folder is scanned again.
const MUST_SCAN: u32 = 0x01 | 0x02 | 0x04 | 0x20;
const HISTORY_DONE: u32 = 0x10;

/// One delivery: the changed paths, and whether the folder must be scanned again.
pub(super) type Deliver = Box<dyn Fn(Vec<PathBuf>, bool) + Send + Sync>;

/// Live while held: dropping it stops the stream and waits for a delivery in progress.
pub(super) struct Stream {
    stream: StreamRef,
    queue: Queue,
    deliver: *mut Deliver,
}

// SAFETY: the stream and queue references are thread-safe CoreServices and dispatch objects; the
// boxed deliver function is Send + Sync and freed only in drop, after the queue is drained.
unsafe impl Send for Stream {}
// SAFETY: as above; `Stream` has no method that uses its fields through `&self`.
unsafe impl Sync for Stream {}

impl Stream {
    /// Watches `folder` and everything below it; `deliver` runs on the stream's own queue.
    pub(super) fn start(
        folder: &Path,
        latency: Duration,
        deliver: Deliver,
    ) -> Result<Self, String> {
        let bytes = folder.as_os_str().as_bytes();
        let len = isize::try_from(bytes.len()).map_err(|_| "the path is too long".to_owned())?;
        // SAFETY: valid bytes and length; every created object is released below or in drop.
        unsafe {
            let path = CFStringCreateWithBytes(std::ptr::null(), bytes.as_ptr(), len, UTF8, 0);
            if path.is_null() {
                return Err("the path is not UTF-8".to_owned());
            }
            let paths = CFArrayCreate(std::ptr::null(), &path, 1, &raw const kCFTypeArrayCallBacks);
            CFRelease(path);
            if paths.is_null() {
                return Err("no memory for the path list".to_owned());
            }
            let deliver = Box::into_raw(Box::new(deliver));
            let context = StreamContext {
                version: 0,
                info: deliver.cast(),
                retain: std::ptr::null(),
                release: std::ptr::null(),
                copy_description: std::ptr::null(),
            };
            let stream = FSEventStreamCreate(
                std::ptr::null(),
                callback,
                &context,
                paths,
                SINCE_NOW,
                latency.as_secs_f64(),
                NO_DEFER | WATCH_ROOT | FILE_EVENTS,
            );
            CFRelease(paths);
            if stream.is_null() {
                drop(Box::from_raw(deliver));
                return Err("FSEventStreamCreate failed".to_owned());
            }
            let queue = dispatch_queue_create(c"acpmux.chat-watch".as_ptr(), std::ptr::null());
            if queue.is_null() {
                FSEventStreamRelease(stream);
                drop(Box::from_raw(deliver));
                return Err("dispatch_queue_create failed".to_owned());
            }
            FSEventStreamSetDispatchQueue(stream, queue);
            let started = Self { stream, queue, deliver };
            if FSEventStreamStart(stream) == 0 {
                // Drop invalidates and releases what was made.
                return Err("FSEventStreamStart failed".to_owned());
            }
            Ok(started)
        }
    }
}

extern "C" fn drained(_: *mut c_void) {}

impl Drop for Stream {
    fn drop(&mut self) {
        // SAFETY: the objects were made in `start` and are released once, here. After
        // `FSEventStreamInvalidate` no delivery starts; `dispatch_sync_f` with an empty block
        // returns once a delivery already running on the serial queue has ended, so `deliver` is
        // freed only when nothing uses it. Never dropped on its own queue (a delivery only sends
        // to a channel).
        unsafe {
            FSEventStreamStop(self.stream);
            FSEventStreamInvalidate(self.stream);
            FSEventStreamRelease(self.stream);
            dispatch_sync_f(self.queue, std::ptr::null_mut(), drained);
            dispatch_release(self.queue);
            drop(Box::from_raw(self.deliver));
        }
    }
}

extern "C" fn callback(
    _stream: StreamRef,
    info: *mut c_void,
    count: usize,
    paths: *mut c_void,
    flags: *const u32,
    _ids: *const u64,
) {
    let delivered = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // SAFETY: FSEvents passes `count` C strings (no UseCFTypes flag) and `count` flags;
        // `info` is the boxed deliver function, alive until drop drains the queue.
        unsafe {
            let deliver = &*(info as *const Deliver);
            let paths = paths as *const *const c_char;
            let mut changed = Vec::with_capacity(count);
            let mut rescan = false;
            for i in 0..count {
                let flag = *flags.add(i);
                rescan |= flag & MUST_SCAN != 0;
                if flag & HISTORY_DONE != 0 {
                    continue;
                }
                let path = CStr::from_ptr(*paths.add(i));
                changed.push(PathBuf::from(std::ffi::OsStr::from_bytes(path.to_bytes())));
            }
            deliver(changed, rescan);
        }
    }));
    if delivered.is_err() {
        tracing::warn!("chat watch: a file event delivery panicked");
    }
}
