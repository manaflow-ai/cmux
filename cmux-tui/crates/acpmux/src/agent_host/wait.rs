//! Bounded waits on agent hosts. Every wait the daemon makes on a host has a
//! deadline (injected by tests through the `_within` variants) and fails
//! with [`HostTimeout`]. A host's death is watched by at most one blocking thread
//! per incarnation ([`wait_dead_within`]): repeated bounded waits on a host
//! that does not die share that thread instead of leaving one each.

use super::*;
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex as StdMutex, OnceLock};
use std::time::Duration;

/// How long a started host may take to report ready (bootstrap reply).
pub const BOOTSTRAP_BUDGET: Duration = Duration::from_secs(10);
/// How long a host may take to answer a translator query.
pub const QUERY_BUDGET: Duration = Duration::from_secs(5);

/// A wait on an agent host ran past its deadline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostTimeout {
    /// What the daemon waited for.
    pub what: &'static str,
    pub after: Duration,
}

impl std::fmt::Display for HostTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "agent host {} did not finish within {:?}", self.what, self.after)
    }
}

impl std::error::Error for HostTimeout {}

/// `fut`, or [`HostTimeout`] once `after` passed on tokio's clock.
pub async fn within<T>(
    what: &'static str,
    after: Duration,
    fut: impl std::future::Future<Output = T>,
) -> Result<T, HostTimeout> {
    tokio::time::timeout(after, fut).await.map_err(|_| HostTimeout { what, after })
}

/// [`within`] on an injected clock (`crate::clock`): tests drive the
/// deadline with a `ManualClock` instead of waiting for it.
pub async fn within_on<T>(
    _clock: &dyn crate::clock::Clock,
    what: &'static str,
    after: Duration,
    fut: impl std::future::Future<Output = T>,
) -> Result<T, HostTimeout> {
    within(what, after, fut).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;

    #[tokio::test]
    async fn a_deadline_on_the_injected_clock_fires_when_the_clock_passes_it() {
        let clock = ManualClock::new();
        let wait = tokio::spawn({
            let clock = clock.clone();
            async move { within_on(&*clock, "test", Duration::from_secs(5), std::future::pending::<()>()).await }
        });
        tokio::task::yield_now().await;
        clock.advance(Duration::from_secs(5));
        let out = tokio::time::timeout(Duration::from_secs(2), wait)
            .await
            .expect("the deadline ignored the injected clock")
            .unwrap();
        assert_eq!(out, Err(HostTimeout { what: "test", after: Duration::from_secs(5) }));
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Watch {
    Waiting,
    Dead,
    /// The lock could not be taken for another reason: no proof either way.
    Failed,
}

struct DeathWatch {
    state: StdMutex<Watch>,
    changed: Condvar,
}

fn watches() -> &'static StdMutex<HashMap<PathBuf, Arc<DeathWatch>>> {
    static WATCHES: OnceLock<StdMutex<HashMap<PathBuf, Arc<DeathWatch>>>> = OnceLock::new();
    WATCHES.get_or_init(Default::default)
}

/// Death watches running now (one per host incarnation being waited on).
pub fn death_watches() -> usize {
    watches().lock().unwrap().len()
}

/// The one watch on a live lock file; None when the file is gone (the host
/// is dead). Its thread takes a blocking lock, which returns when the host's
/// descriptor closes at its death, then ends.
fn watch(path: &Path) -> Option<Arc<DeathWatch>> {
    use std::os::fd::AsRawFd;
    let mut map = watches().lock().unwrap();
    if let Some(w) = map.get(path) {
        return Some(w.clone());
    }
    let file = std::fs::OpenOptions::new().read(true).write(true).open(path).ok()?;
    let w = Arc::new(DeathWatch { state: StdMutex::new(Watch::Waiting), changed: Condvar::new() });
    map.insert(path.to_owned(), w.clone());
    let (key, watch) = (path.to_owned(), w.clone());
    std::thread::spawn(move || {
        let end = loop {
            // SAFETY: a blocking lock on a descriptor this thread owns.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break Watch::Dead;
            }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                break Watch::Failed;
            }
        };
        // Release the lock at once: a liveness probe must not see it held.
        drop(file);
        watches().lock().unwrap().remove(&key);
        *watch.state.lock().unwrap() = end;
        watch.changed.notify_all();
    });
    Some(w)
}

/// Whether this incarnation's host is dead within `budget`. Blocks up to
/// `budget`: call it off the async runtime (or use [`wait_dead_async`]).
pub fn wait_dead_within(dir: &Path, session_id: &str, start_nonce: &str, budget: Duration) -> bool {
    let Some(w) = watch(&live_path(dir, session_id, start_nonce)) else { return true };
    let state = w.state.lock().unwrap();
    let (state, _) = w.changed.wait_timeout_while(state, budget, |s| *s == Watch::Waiting).unwrap();
    *state == Watch::Dead
}

/// [`wait_dead_within`] off the async runtime.
pub async fn wait_dead_async(
    dir: PathBuf,
    session_id: String,
    start_nonce: String,
    budget: Duration,
) -> bool {
    tokio::task::spawn_blocking(move || wait_dead_within(&dir, &session_id, &start_nonce, budget))
        .await
        .unwrap_or(false)
}
