//! The thread the signaling socket lives on: its connect, its reads, its writes and its keepalive.
//!
//! The service lists a Mac online while its signaling socket is open, and fresh while the
//! socket's application pings keep coming (PROTOCOL.md "Mac freshness"). On a Mac at load 90 on
//! 15 cores with its swap full (2026-11-23, cmux#52200), the host's shared runtime
//! fell behind: its workers were busy or blocked, so the keepalive tick and the reads of the
//! service's pongs waited behind that work, the pings stopped, and the phone showed the Mac
//! offline for 50 min while it was up. The socket's own work is a few small frames every 15 s,
//! so it gets a runtime of its own, on one OS thread that no other work shares, raised to the
//! user-interactive class on Apple platforms (elsewhere it runs at the process's priority).
//!
//! The socket is opened on this runtime, so its reactor (readiness and timers) is this thread's
//! too: a starved shared runtime cannot hold back a read, a pong or a keepalive.

use std::future::Future;
use std::sync::OnceLock;

/// This runtime's handle; the thread starts on first use and lives for the process.
fn handle() -> &'static tokio::runtime::Handle {
    static HANDLE: OnceLock<tokio::runtime::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("the liveness runtime builds");
        let handle = runtime.handle().clone();
        std::thread::Builder::new()
            .name("cmux-liveness".into())
            .spawn(move || {
                raise_priority();
                runtime.block_on(std::future::pending::<()>());
            })
            .expect("the liveness thread starts");
        handle
    })
}

/// Runs `future` on the liveness thread.
pub(crate) fn spawn<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    handle().spawn(future)
}

/// The calling thread at `QOS_CLASS_USER_INTERACTIVE`: the scheduler runs it ahead of default,
/// utility and background work, on a performance core.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn raise_priority() {
    const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
    unsafe extern "C" {
        fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32;
    }
    // SAFETY: changes only the calling thread's QoS class; plain integer arguments.
    let refused = unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) };
    if refused != 0 {
        tracing::debug!(refused, "the liveness thread keeps its QoS class");
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn raise_priority() {}
