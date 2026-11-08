//! What stops the daemon besides a client: a signal, and the store asking for a restart (moved
//! out of `daemon.rs`, which is over its size budget).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The daemon's exit status after its store asked it to stop for a restart ([`store_asks_to_stop`]:
/// a failed log sync froze the event journal's checkpoint, or the journal's writer ended): EX_IOERR.
/// The next start's replay repairs the logs; a supervisor starts it again (launchd `KeepAlive`,
/// systemd `Restart=always`: the units prevent only 75), and otherwise the next client does.
pub const EXIT_REPAIR: i32 = 74;

/// The store's stop won the daemon's stop select.
static STOPPED_FOR_REPAIR: AtomicBool = AtomicBool::new(false);

/// The process's exit status after `daemon::run` returned: [`EXIT_REPAIR`] when the store asked
/// for the stop, else 0.
pub fn exit_status() -> i32 {
    if STOPPED_FOR_REPAIR.load(Ordering::SeqCst) { EXIT_REPAIR } else { 0 }
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
/// to [`EXIT_REPAIR`]; never for a store that does not ask, or once the store is gone.
pub(super) async fn store_asks_to_stop(hub: Arc<crate::hub::Hub>) {
    let Some(mut reason) = hub.store.stop_reason() else { return std::future::pending().await };
    match reason.wait_for(Option::is_some).await {
        Ok(why) => {
            tracing::error!("stopping for a restart: {}", why.as_deref().unwrap_or_default());
        }
        Err(_) => return std::future::pending().await,
    }
    hub.restart_requested.store(true, Ordering::SeqCst);
    STOPPED_FOR_REPAIR.store(true, Ordering::SeqCst);
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
