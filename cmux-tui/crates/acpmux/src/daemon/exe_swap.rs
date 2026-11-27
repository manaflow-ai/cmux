//! Watches the installed executable and requests a drained, same-process exec update.
//! An unfinished turn defers the attempt; a bad build leaves the old daemon serving.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long after the installed path changed a file there may take to become runnable (its
/// copy and chmod), looked at every [`BUILD_LOOK`].
// timeout: an update that leaves no runnable file is no build yet; the next change looks again.
const BUILD_WITHIN: Duration = Duration::from_secs(10);
const BUILD_LOOK: Duration = Duration::from_millis(100);
/// How long the new build may take to answer the exec-protocol preflight.
// timeout: a new build that hangs at its start is a failed readiness; the old daemon serves on.
pub(crate) const READY_WITHIN: Duration = Duration::from_secs(10);
/// After a swap that kept the old daemon (a new build that did not answer, a take-over start that
/// never asked in time under load), the watch tries again after each of these waits, as long as
/// the installed path still is not the file this daemon runs. Before, a failed swap waited for the
/// next change of the path, so the replaced daemon served on until the app stopped it: the app
/// cannot hand a daemon whose bundle an update replaced this launch's person key (it cannot check
/// that peer), and its stop left every chat without a daemon until a new one started (Leo's
/// NIGHTLY, 2026-11-22 23:44Z: the swap failed at :25, the app stopped the daemon at :35, 4.6 s
/// dark).
// timeout: not a deadline; the waits between drained exec preflight attempts.
pub(crate) const RETRY_AFTER: [Duration; 5] = [
    Duration::from_secs(5),
    Duration::from_secs(15),
    Duration::from_secs(30),
    Duration::from_secs(60),
    Duration::from_secs(120),
];

// Busy sends leave a pending handoff; they do not consume the bad-build retry budget.
// timeout: retry cadence, never permission to cut an accepted send.
const BUSY_RETRY_AFTER: Duration = Duration::from_secs(30);

#[derive(Default)]
struct SwapRetry {
    failures: usize,
    busy: bool,
}
impl SwapRetry {
    fn after(&self) -> Option<Duration> {
        if self.busy {
            Some(BUSY_RETRY_AFTER)
        } else {
            self.failures.checked_sub(1).and_then(|i| RETRY_AFTER.get(i)).copied()
        }
    }
    fn deferred(&mut self) {
        self.busy = true;
    }
    fn failed(&mut self) {
        self.busy = false;
        self.failures += 1;
    }
}

#[cfg(test)]
#[test]
fn busy_update_stays_pending_after_the_failure_budget_would_be_exhausted() {
    let mut retry = SwapRetry::default();
    assert_eq!(retry.after(), None);
    retry.failed();
    let failed_delay = retry.after();
    // A long turn lasts past every old retry slot, then finishes.
    for _ in 0..100 {
        retry.deferred();
        assert_eq!(retry.after(), Some(Duration::from_secs(30)));
        assert_eq!(retry.failures, 1);
    }
    retry.busy = false;
    assert_eq!(retry.after(), failed_delay);
    for _ in 0..RETRY_AFTER.len() {
        retry.failed();
    }
    assert_eq!(retry.after(), None, "bad builds retain their finite retry bound");
    retry.deferred();
    assert_eq!(retry.after(), Some(Duration::from_secs(30)));
}

/// The installed path and its identity when the watch started, for [`replaced`] and a client's
/// swap request ([`request_swap`]).
static WATCHED: std::sync::OnceLock<(PathBuf, super::home_watch::Owned)> =
    std::sync::OnceLock::new();
/// A client asked for the swap now (`_acpmux/shutdown` with `swapIfReplaced`).
static SWAP_NOW: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// Why the installed executable is no longer the file this daemon runs, when a runnable build
/// is there now; `None` when it is the same file, the watch is off, or no build runs there yet.
pub(crate) fn replaced() -> Option<String> {
    let (installed, owned) = WATCHED.get()?;
    let why = owned.lost()?;
    runnable(installed).then_some(why)
}

/// The original installed path, even when Linux current_exe now names a deleted inode.
pub(super) fn installed_path() -> Option<PathBuf> {
    WATCHED.get().map(|(path, _)| path.clone()).or_else(|| std::env::current_exe().ok())
}

/// A client's swap request wakes the watcher. It drains accepted sends and preflights the
/// installed build before scheduling exec; a failed drain or preflight leaves this daemon serving.
pub(crate) fn request_swap() -> Option<String> {
    let why = replaced()?;
    SWAP_NOW.notify_one();
    Some(why)
}

/// What woke the watch.
enum Wake {
    /// The kernel watch saw the path or a folder above it change.
    Changed,
    /// A client asked for the swap ([`request_swap`]).
    Asked,
    /// The wait after a failed swap ended ([`RETRY_AFTER`]).
    Retry,
}

/// Watch the installed executable; swap once an update replaced it. The path, its identity and
/// the kernel watch are taken here, when this is called (before the daemon says ready: an update
/// right after ready is then a change, never the baseline); the future it returns never resolves.
pub(super) fn watch() -> Watch {
    let start = start();
    if let Some((installed, owned, _, _)) = &start {
        let _ = WATCHED.set((installed.clone(), owned.clone()));
    }
    Watch { start }
}

pub(super) struct Watch {
    start: Option<Started>,
}

impl Watch {
    pub(super) async fn run(self, hub: std::sync::Arc<crate::hub::Hub>) {
        let Self { start } = self;
        let Some((installed, owned, _watcher, mut rx)) = start else {
            return std::future::pending().await;
        };
        let mut watching = true;
        // Busy sends remain pending; real swap failures retain their finite budget.
        let mut retries = SwapRetry::default();
        loop {
            let retry = retries.after();
            let wake = tokio::select! {
                got = rx.recv(), if watching => match got {
                    Some(()) => Wake::Changed,
                    None => {
                        watching = false;
                        continue;
                    }
                },
                () = SWAP_NOW.notified() => Wake::Asked,
                () = tokio::time::sleep(retry.unwrap_or(Duration::MAX)), if retry.is_some() => Wake::Retry,
            };
            let Some(why) = owned.lost() else {
                retries = SwapRetry::default();
                continue;
            };
            // The move, the new copy and its mode are separate steps of the update, and the last
            // (a chmod) changes no identity the watch sees: look again until a file runs.
            let mut waited = Duration::ZERO;
            while !runnable(&installed) && waited < BUILD_WITHIN {
                tokio::time::sleep(BUILD_LOOK).await;
                waited += BUILD_LOOK;
            }
            if !runnable(&installed) {
                tracing::info!("update: {why}; waiting for a build at {}", installed.display());
                continue;
            }
            match wake {
                Wake::Changed => {
                    tracing::warn!(
                        "update: {why}; swapping to the build at {}",
                        installed.display()
                    )
                }
                Wake::Asked => tracing::warn!(
                    "update: {why}; a client asked for the swap; swapping to the build at {}",
                    installed.display()
                ),
                Wake::Retry => tracing::warn!(
                    "update: {why}; trying the swap again (attempt {}) to the build at {}",
                    retries.failures + 1,
                    installed.display()
                ),
            }
            // The executable watcher can beat machine update's explicit restart. It must
            // use the same admission fence before a supervisor can signal this daemon.
            let drain = match crate::server::update_drain::prepare(&hub).await {
                Ok(drain) => drain,
                Err(error) => {
                    retries.deferred();
                    tracing::info!("update deferred; daemon serves on: {error}");
                    continue;
                }
            };
            // An explicit updater that already began shutdown owns the replacement.
            if hub.shutting_down() {
                return std::future::pending().await;
            }
            retries.busy = false;
            match super::exec_update::prepare(&hub).await {
                Ok(receipt) => {
                    tracing::info!(update_id = %receipt["updateId"], "update ready; draining before exec");
                    super::supervision::stopping(super::supervision::shutdown_cause(
                        "exe-watch: updated executable",
                        true,
                    ));
                    hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
                    drain.commit();
                    hub.stop_idle_reaper();
                    hub.shutdown.notify_waiters();
                    hub.shutdown.notify_one();
                    return std::future::pending().await;
                }
                Err(error) => {
                    retries.failed();
                    tracing::warn!("update exec preflight failed; daemon serves on: {error:#}");
                }
            }
        }
    }
}

type Started = (
    PathBuf,
    super::home_watch::Owned,
    crate::agent_host::record_watch::DirWatch,
    tokio::sync::mpsc::Receiver<()>,
);

/// The installed path, its identity now, and a kernel watch on it and every folder above it.
fn start() -> Option<Started> {
    let installed = super::exec_update::installed().or_else(|| std::env::current_exe().ok())?;
    let Some(owned) = super::home_watch::Owned::now(&[&installed]) else {
        tracing::warn!("update watch off: {} cannot be read", installed.display());
        return None;
    };
    let (tx, rx) = tokio::sync::mpsc::channel::<()>(1);
    let mut paths: Vec<PathBuf> = installed.ancestors().map(Path::to_path_buf).collect();
    if let Ok(resolved) = std::fs::canonicalize(&installed) {
        paths.extend(resolved.ancestors().map(Path::to_path_buf));
    }
    paths.retain(|p| !p.as_os_str().is_empty() && p != Path::new("/"));
    paths.sort();
    paths.dedup();
    let Some(watcher) = crate::agent_host::record_watch::DirWatch::start_identities(&paths, {
        move || {
            let _ = tx.try_send(());
            tx.is_closed()
        }
    }) else {
        tracing::warn!("update watch off: no watch on {}", installed.display());
        return None;
    };
    Some((installed, owned, watcher, rx))
}

/// A regular file this user may run.
fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(test)]
#[path = "exe_swap_tests.rs"]
mod tests;
