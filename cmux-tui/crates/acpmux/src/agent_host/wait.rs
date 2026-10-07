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
    within_on(&*crate::clock::TokioClock::new(), what, after, fut).await
}

/// [`within`] on an injected clock (`crate::clock`): tests drive the
/// deadline with a `ManualClock` instead of waiting for it.
pub async fn within_on<T>(
    clock: &dyn crate::clock::Clock,
    what: &'static str,
    after: Duration,
    fut: impl std::future::Future<Output = T>,
) -> Result<T, HostTimeout> {
    // A budget past the clock's range has no deadline (as tokio's timeout).
    let Some(at) = clock.now().checked_add(after) else { return Ok(fut.await) };
    let deadline = clock.sleep_until(at);
    tokio::select! {
        // The work first: a result ready together with the deadline wins.
        biased;
        value = fut => Ok(value),
        () = deadline => Err(HostTimeout { what, after }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;

    #[tokio::test]
    async fn a_deadline_on_the_injected_clock_fires_when_the_clock_passes_it() {
        let clock = ManualClock::new();
        let mut wait = std::pin::pin!(within_on(
            &*clock,
            "test",
            Duration::from_secs(5),
            std::future::pending::<()>()
        ));
        // Polled once first, so the deadline is set from the clock's start.
        assert!(futures::poll!(&mut wait).is_pending());
        clock.advance(Duration::from_secs(5));
        let out = tokio::time::timeout(Duration::from_secs(2), wait)
            .await
            .expect("the deadline ignored the injected clock");
        assert_eq!(out, Err(HostTimeout { what: "test", after: Duration::from_secs(5) }));
    }

    #[tokio::test]
    async fn work_ready_with_the_deadline_wins_and_a_huge_budget_never_panics() {
        let clock = ManualClock::new();
        assert_eq!(within_on(&*clock, "test", Duration::ZERO, async { 7 }).await, Ok(7));
        assert_eq!(within_on(&*clock, "test", Duration::MAX, async { 8 }).await, Ok(8));
    }

    /// A child that another thread spawns inherits every descriptor until it
    /// execs, so the watch's descriptor can have a duplicate when the watch
    /// ends. The lock belongs to the open file description, not the
    /// descriptor: the watch must release it, or a probe of a dead host sees
    /// it held.
    #[test]
    fn a_death_watch_releases_the_lock_while_a_duplicate_of_its_descriptor_is_open() {
        let dir = std::env::temp_dir().join(format!("acpmux-wait-dup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = live_path(&dir, "s1", "00ff");
        std::fs::write(&path, "").unwrap();
        let file = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
        // What a concurrent fork gives its child: the same open file description.
        let inherited = file.try_clone().unwrap();
        assert!(take_death_lock(file) == Watch::Dead);
        assert_eq!(liveness(&dir, "s1", "00ff"), Liveness::Dead, "the watch left the lock held");
        drop(inherited);
        let _ = std::fs::remove_dir_all(&dir);
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
    /// The same end for async waiters ([`dead`]).
    ended: tokio::sync::watch::Sender<Watch>,
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
    let mut map = watches().lock().unwrap();
    if let Some(w) = map.get(path) {
        return Some(w.clone());
    }
    let file = std::fs::OpenOptions::new().read(true).write(true).open(path).ok()?;
    let w = Arc::new(DeathWatch {
        state: StdMutex::new(Watch::Waiting),
        changed: Condvar::new(),
        ended: tokio::sync::watch::channel(Watch::Waiting).0,
    });
    map.insert(path.to_owned(), w.clone());
    let (key, watch) = (path.to_owned(), w.clone());
    std::thread::spawn(move || {
        let end = take_death_lock(file);
        watches().lock().unwrap().remove(&key);
        *watch.state.lock().unwrap() = end;
        watch.changed.notify_all();
        watch.ended.send_replace(end);
    });
    Some(w)
}

/// Block until the host's lock on `file` is free (the host died), then
/// release it at once: a liveness probe must not see it held. The release
/// is an explicit unlock, not the close: the lock belongs to the open file
/// description, and a child that another thread spawns holds a copy of this
/// descriptor until it execs, so a close alone can leave the lock held.
fn take_death_lock(file: std::fs::File) -> Watch {
    use std::os::fd::AsRawFd;
    let end = loop {
        // SAFETY: a blocking lock on a descriptor this thread owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            break Watch::Dead;
        }
        if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            break Watch::Failed;
        }
    };
    if end == Watch::Dead {
        // SAFETY: same descriptor; unlocks the description for every copy.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
    }
    drop(file);
    end
}

/// Whether this incarnation's host is dead within `budget`. Blocks up to
/// `budget`: call it off the async runtime (or use [`wait_dead_async`]).
pub fn wait_dead_within(dir: &Path, session_id: &str, start_nonce: &str, budget: Duration) -> bool {
    let Some(w) = watch(&live_path(dir, session_id, start_nonce)) else { return true };
    let state = w.state.lock().unwrap();
    let (state, _) = w.changed.wait_timeout_while(state, budget, |s| *s == Watch::Waiting).unwrap();
    *state == Watch::Dead
}

/// Resolves once this incarnation's host is dead (true) or its watch failed
/// (false). It has no deadline and holds no runtime thread: race it with one
/// ([`within_on`]). The shared watch thread ends only with the host.
pub async fn dead(dir: &Path, session_id: &str, start_nonce: &str) -> bool {
    let Some(w) = watch(&live_path(dir, session_id, start_nonce)) else { return true };
    let mut ended = w.ended.subscribe();
    let end = match ended.wait_for(|s| *s != Watch::Waiting).await {
        Ok(end) => *end,
        Err(_) => Watch::Failed,
    };
    end == Watch::Dead
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
