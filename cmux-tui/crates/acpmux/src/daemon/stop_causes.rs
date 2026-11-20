//! What stops the daemon besides a client: a signal, and the store asking for a restart (moved
//! out of `daemon.rs`, which is over its size budget).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The daemon's exit status after its store asked it to stop for a restart ([`store_asks_to_stop`]:
/// a failed log sync froze the event journal's checkpoint, or the journal's writer ended): EX_IOERR.
/// The next start's replay repairs the logs; a supervisor starts it again (launchd `KeepAlive`,
/// systemd `Restart=always`: the units prevent only 75), and otherwise the next client does.
pub const EXIT_REPAIR: i32 = 74;

/// The daemon's exit status after a supervised task could not go on (`crate::supervise`: a task
/// that kept panicking, or one that cannot run twice): EX_SOFTWARE. Started again like
/// [`EXIT_REPAIR`]; its agents stay up in their hosts and the next start adopts them.
pub const EXIT_TASK_PANIC: i32 = 70;

/// The store's stop won the daemon's stop select.
static STOPPED_FOR_REPAIR: AtomicBool = AtomicBool::new(false);
/// A supervised task's stop won it.
static STOPPED_FOR_PANIC: AtomicBool = AtomicBool::new(false);

/// The process's exit status after `daemon::run` returned: [`EXIT_REPAIR`] when the store asked
/// for the stop, [`EXIT_TASK_PANIC`] when a supervised task did, else 0.
pub fn exit_status() -> i32 {
    if STOPPED_FOR_REPAIR.load(Ordering::SeqCst) {
        EXIT_REPAIR
    } else if STOPPED_FOR_PANIC.load(Ordering::SeqCst) {
        EXIT_TASK_PANIC
    } else {
        0
    }
}

/// Aborts a task when dropped.
pub(super) struct AbortOnDrop(pub(super) tokio::task::AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Resolves once the store asks the daemon to stop (`Store::stop_reason`), with the reason
/// logged, the stop marked a restart handoff (WebSocket clients get 1012) and the exit status set
/// to [`EXIT_REPAIR`]; never for a store that does not ask, or once the store is gone. Also once
/// a supervised task could not go on (`Hub::fatal`), the same way with [`EXIT_TASK_PANIC`].
pub(super) async fn store_asks_to_stop(hub: Arc<crate::hub::Hub>) {
    tokio::select! {
        () = store_stop(&hub) => STOPPED_FOR_REPAIR.store(true, Ordering::SeqCst),
        why = hub.fatal.raised() => {
            tracing::error!("stopping for a restart: {why}");
            STOPPED_FOR_PANIC.store(true, Ordering::SeqCst);
        }
    }
    hub.restart_requested.store(true, Ordering::SeqCst);
}

async fn store_stop(hub: &crate::hub::Hub) {
    let Some(mut reason) = hub.store.stop_reason() else { return std::future::pending().await };
    match reason.wait_for(Option::is_some).await {
        Ok(why) => {
            tracing::error!("stopping for a restart: {}", why.as_deref().unwrap_or_default());
        }
        Err(_) => std::future::pending().await,
    }
}

/// The next delivery of a registered signal; never, if registration failed.
#[cfg(unix)]
pub(super) async fn next_signal(stream: Option<&mut tokio::signal::unix::Signal>) {
    match stream {
        Some(stream) => {
            stream.recv().await;
        }
        None => std::future::pending::<()>().await,
    }
}
