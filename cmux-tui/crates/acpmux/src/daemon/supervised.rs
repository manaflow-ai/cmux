//! The daemon's long-lived tasks under panic supervisors (cmux-panic-log
//! `supervise`, plans/cmux-next/rust-panic-free.md section 5): a worker
//! that rebuilds its state restarts after a panic; the web accept loop,
//! which nothing awaits, stops the daemon through its normal shutdown
//! instead of leaving it alive without a listener.

use crate::hub::Hub;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Set when the web accept loop panicked: the daemon stops with an error.
static WEB_LISTENER_PANICKED: AtomicBool = AtomicBool::new(false);

/// The catalog refresh, restarted after a panic. A restart waits a whole
/// refresh period: a fetch that panics every time must not turn the 6 h
/// refresh into one every few seconds.
pub(super) fn catalog_refresh(catalog: Arc<crate::catalog::CatalogService>) {
    let run = move || catalog.clone().run();
    let wait = |_| tokio::time::sleep(crate::catalog::REFRESH_EVERY);
    tokio::spawn(cmux_panic_log::supervise::restarting("acpmux catalog refresh", run, wait));
}

/// `notify_command` deliveries, restarted after a panic.
pub(super) fn notify(hub: Arc<Hub>) {
    let run = move || super::notify::notify_loop(hub.clone());
    tokio::spawn(cmux_panic_log::supervise::restarting("acpmux notify", run, tokio::time::sleep));
}

/// The web accept loop. After a panic the daemon shuts down as on
/// `_acpmux/shutdown` (agents kept, state flushed) and exits with an
/// error; the app's next pane connect starts a new daemon, which adopts the
/// agent hosts.
pub(super) fn web_accept_loop(
    hub: &Arc<Hub>,
    serve: impl Future<Output = anyhow::Result<()>> + Send + 'static,
) -> tokio::task::JoinHandle<()> {
    let hub = hub.clone();
    tokio::spawn(async move {
        match cmux_panic_log::supervise::catch_future("acpmux web accept loop", serve).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::warn!("web listener stopped: {e:#}"),
            Err(_) => {
                WEB_LISTENER_PANICKED.store(true, Ordering::SeqCst);
                hub.shutdown.notify_waiters();
                hub.shutdown.notify_one();
            }
        }
    })
}

/// The result `run` ends with once its shutdown is done.
pub(super) fn exit_status() -> anyhow::Result<()> {
    if WEB_LISTENER_PANICKED.load(Ordering::SeqCst) {
        anyhow::bail!("the web listener panicked; the daemon stopped so that it can be restarted");
    }
    Ok(())
}

/// Debug builds only: `ACPMUX_TEST_PANIC=request:<method>` makes a request
/// of `<method>` panic inside its handler (tests/panic_log.rs): the client
/// gets an internal error and the daemon keeps answering.
#[cfg(debug_assertions)]
pub(crate) fn panic_in_request_for_test(method: &str) {
    let armed = std::env::var(super::TEST_PANIC_ENV)
        .ok()
        .is_some_and(|value| value.strip_prefix("request:") == Some(method));
    if armed {
        // crash-allow: debug-only test trigger for the request boundary
        panic!("acpmux test request panic");
    }
}
