//! `_acpmux/debug_panic {kind: "panic" | "abort" | "segv"}`: make this
//! daemon crash on purpose, so crash-matrix.py can check that each kind of
//! acpmux crash yields exactly one report
//! (plans/cmux-next/chrome-parity/p09-observability.md, task 101).
//!
//! Chrome's debug URLs do the same for its processes
//! (content/browser/renderer_host/debug_urls.cc `HandleDebugURL`:
//! chrome://crash, chrome://inducebrowsercrashforrealz, chrome://kill), and
//! only a browser-initiated navigation may start one, never a page. Here
//! only the local unix socket may: every WebSocket origin (Web, LocalApp,
//! Peer) gets "Method not found", as for `_acpmux/trace`.
//!
//! The module exists only in debug builds and `--features bench` builds: a
//! release daemon has no such method. It is not in the protocol registry, so
//! no typed client or IR names it.
//!
//! The crash runs on a thread of its own, started before the reply. A
//! `panic` ends only that thread (the panic log records it); `abort` and
//! `segv` end the process, so their reply may not reach the caller.

use serde_json::{Value, json};

use crate::rpc::RpcError;
use crate::server::Origin;

/// The method name.
pub(crate) const METHOD: &str = "_acpmux/debug_panic";
/// The thread the crash runs on: crash reports name it.
pub(crate) const THREAD: &str = "acpmux-debug-crash-inject";

/// How the daemon ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CrashKind {
    /// A Rust panic on [`THREAD`]: the panic hook writes one panic-log line.
    Panic,
    /// `std::process::abort`: SIGABRT.
    Abort,
    /// A store to an unmapped address: a real SIGSEGV with a fault address, as
    /// Chrome's `CrashIntentionally` (content/renderer/render_frame_impl.cc)
    /// writes through a null pointer.
    Segv,
}

impl CrashKind {
    pub(crate) const ALL: [Self; 3] = [Self::Panic, Self::Abort, Self::Segv];

    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Panic => "panic",
            Self::Abort => "abort",
            Self::Segv => "segv",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.wire_name() == name)
    }
}

/// Answer `_acpmux/debug_panic` from `origin`, handing its kind to `crash`.
pub(crate) fn handle(
    origin: Origin,
    params: &Value,
    crash: impl FnOnce(CrashKind) -> std::io::Result<()>,
) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(METHOD));
    }
    let kind = kind_of(params)?;
    crash(kind).map_err(|error| RpcError::internal(format!("crash thread: {error}")))?;
    Ok(json!({"kind": kind.wire_name(), "pid": std::process::id()}))
}

/// The one param, `kind`; any other field is refused.
fn kind_of(params: &Value) -> Result<CrashKind, RpcError> {
    let bad = || RpcError::invalid_params("debug_panic takes only kind: panic, abort or segv");
    let fields = params.as_object().ok_or_else(bad)?;
    if fields.keys().any(|field| field != "kind") {
        return Err(bad());
    }
    fields.get("kind").and_then(Value::as_str).and_then(CrashKind::parse).ok_or_else(bad)
}

/// Crash as `kind` says, on [`THREAD`].
pub(crate) fn fire(kind: CrashKind) -> std::io::Result<std::thread::JoinHandle<()>> {
    cmux_threads::spawn(THREAD, cmux_threads::ThreadQos::Utility, move || crash_now(kind))
}

/// Crash the calling thread (`Panic`) or the process (`Abort`, `Segv`).
#[allow(
    clippy::panic,
    reason = "debug_panic's panic kind: a debug and bench build crash injector, not in release"
)]
fn crash_now(kind: CrashKind) {
    match kind {
        // crash-allow: debug_panic's panic kind; the module is not in release builds
        CrashKind::Panic => panic!("debug_panic: injected acpmux panic"),
        CrashKind::Segv => fault(),
        CrashKind::Abort => {}
    }
    // crash-allow: debug_panic's abort kind, and the end of a segv store the kernel let through
    std::process::abort();
}

/// An address in the first page, which is never mapped: macOS reserves it
/// (`__PAGEZERO`) and Linux refuses to map below `vm.mmap_min_addr`.
const UNMAPPED: usize = 0x10;

/// Store to [`UNMAPPED`]: the CPU faults, and the kernel ends the process
/// with SIGSEGV (EXC_BAD_ACCESS, KERN_INVALID_ADDRESS on macOS). Should the
/// store return, [`crash_now`] aborts.
fn fault() {
    let address = std::ptr::with_exposed_provenance_mut::<u8>(UNMAPPED);
    // SAFETY: none in the language's sense: this store is the crash. The
    // address is in the never-mapped first page, so it can change no memory;
    // the store is volatile so it is emitted as written.
    unsafe { std::ptr::write_volatile(address, 1) };
}

#[cfg(test)]
#[path = "debug_crash_inject_tests.rs"]
mod tests;
