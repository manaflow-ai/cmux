//! The `idleHelperBackgroundPriority` feature's wiring in the daemon:
//! idle helpers run best-effort, as Chromium runs its
//! spare and hidden renderers (`RenderProcessHostImpl::UpdateProcessPriority`).
//!
//! - A pooled agent's host and harness groups once it is ready
//!   (`Hub::pool_want`) or a claim gave it back (`Hub::pool_return_claimed`),
//!   and normal again before a claim serves it (`Hub::pool_claim`;
//!   `hub/pool/priority.rs`).
//! - This daemon while no client is connected and no agent or pooled start
//!   runs ([`ClientPresence::run_idle_priority`], asked again on each
//!   [`ClientPresence::work_changed`]), normal again when a client connects
//!   and before an agent or a pooled host starts (`Hub::ensure_child`,
//!   `Hub::pool_want`).
//!
//! Terminal hosts and holders never: they are not acpmux's. Nothing changes
//! where a lowered priority could not be raised again (Linux without root
//! or `RLIMIT_NICE`).
//!
//! [`ClientPresence::run_idle_priority`]: super::ClientPresence::run_idle_priority
//! [`ClientPresence::work_changed`]: super::ClientPresence::work_changed

use std::sync::Arc;

use cmux_tui_platform::process_priority::{self, PriorityError, ProcessPriority};

use crate::hub::Hub;

/// Turns the feature on for `hub` when it is on and reversible here.
/// Returns the daemon's idle task, ended at shutdown.
pub(crate) async fn install(hub: &Arc<Hub>) -> Option<tokio::task::JoinHandle<()>> {
    let features = cmux_blocking::spawn_blocking(super::daemon_features).await;
    let on = features.is_ok_and(|features| {
        features.is_enabled(cmux_features::feature::IDLE_HELPER_BACKGROUND_PRIORITY)
    });
    if !on {
        return None;
    }
    if !process_priority::reversible() {
        tracing::info!("idle helpers keep their priority: this process could not raise it again");
        return None;
    }
    #[cfg(debug_assertions)]
    hub.set_pool_priority(Arc::new(stall_for_tests(process_priority::set_group)));
    #[cfg(not(debug_assertions))]
    hub.set_pool_priority(Arc::new(process_priority::set_group));
    hub.clients.install_priority(Arc::new(process_priority::set_self));
    let weak = Arc::downgrade(hub);
    let started = weak.clone();
    let idle =
        hub.clients.run_idle_priority(move || weak.upgrade().is_some_and(|h| h.idle_quiet()));
    // Startup work counts as live until it is done: asked again then.
    let startup = async move {
        let Some(hub) = started.upgrade() else { return };
        hub.wait_startup().await;
        hub.wait_logs().await;
        hub.clients.work_changed();
    };
    Some(tokio::spawn(async move {
        tokio::join!(idle, startup);
    }))
}

/// The debug builds' pool priority stall seam's variable: the path of a
/// FIFO the daemon's integration tests create.
#[cfg(debug_assertions)]
const STALL_FIFO_ENV: &str = "ACPMUX_TEST_POOL_PRIORITY_STALL_FIFO";

/// Debug builds only: while the FIFO `ACPMUX_TEST_POOL_PRIORITY_STALL_FIFO`
/// names exists, the next change of a pooled entry back to its normal
/// priority opens it (waiting for the test to open its write end), removes
/// it, and waits until the test closes that end. A test can so hold a claim
/// in its priority change. Release builds have no seam.
#[cfg(debug_assertions)]
fn stall_for_tests(
    set_group: impl Fn(u32, ProcessPriority) -> Result<(), PriorityError> + Send + Sync + 'static,
) -> impl Fn(u32, ProcessPriority) -> Result<(), PriorityError> + Send + Sync + 'static {
    let fifo = std::env::var_os(STALL_FIFO_ENV).map(std::path::PathBuf::from);
    move |leader, priority| {
        if priority == ProcessPriority::UserVisible
            && let Some(fifo) = &fifo
            && let Ok(mut held) = cmux_blocking::fs::open(fifo)
        {
            let _ = cmux_blocking::fs::remove_file(fifo);
            let _ = std::io::copy(&mut held, &mut std::io::sink());
        }
        set_group(leader, priority)
    }
}
