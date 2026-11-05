//! Bounded waits on agent hosts. A wait on a running host's answer has a
//! deadline (injected by tests through the `_within` variants) and fails
//! with [`HostTimeout`]. A host's start has none: it ends on the host's
//! answer or its exit (`link::spawn`, P-AUSTIN B10). A host's death is
//! watched by at most one blocking thread per incarnation
//! ([`wait_dead_within`]): repeated bounded waits on a host that does not
//! die share that thread instead of leaving one each.

use super::*;
use crate::no_panic::LockExt;
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex as StdMutex, OnceLock};
use std::time::Duration;

/// How long a host may take to answer a translator query.
pub const QUERY_BUDGET: Duration = crate::rpc::ANSWER_WAIT;

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
    watches().lock_or_recover().len()
}

/// The one watch on a live lock file; None when the file is gone (the host
/// is dead). Its thread takes a blocking lock, which returns when the host's
/// descriptor closes at its death, then ends.
fn watch(path: &Path) -> Option<Arc<DeathWatch>> {
    let mut map = watches().lock_or_recover();
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
        watches().lock_or_recover().remove(&key);
        *watch.state.lock_or_recover() = end;
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
#[cfg(unix)]
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
/// Windows port: `LockFileEx` there (a later landing); no watch can prove a
/// death yet.
#[cfg(not(unix))]
fn take_death_lock(_file: std::fs::File) -> Watch {
    Watch::Failed
}

/// Whether this incarnation's host is dead within `budget`. Blocks up to
/// `budget`: call it off the async runtime (or use [`wait_dead_async`]).
pub fn wait_dead_within(dir: &Path, session_id: &str, start_nonce: &str, budget: Duration) -> bool {
    let Some(w) = watch(&live_path(dir, session_id, start_nonce)) else { return true };
    let state = w.state.lock_or_recover();
    let (state, _) = w
        .changed
        .wait_timeout_while(state, budget, |s| *s == Watch::Waiting)
        .unwrap_or_else(std::sync::PoisonError::into_inner);
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

/// Whether host `record` is dead now, without waiting: its live lock is in one of its lock
/// directories ([`live_lock_dirs`]) and no process holds it. A claim reads this before it serves
/// a pooled host, because the link's own end (`ChildAgent::is_alive`) comes only once the
/// daemon's reader sees the closed socket, which can be after a session asked for the host.
pub fn host_dead_now(record: &HostRecord) -> bool {
    dead_now_in(&live_lock_dirs(record), &record.session_id, &record.start_nonce)
}

/// [`host_dead_now`] over explicit directories (tests pass a temporary one). The first lock
/// file found decides: held is alive, free is dead. No lock file in any directory is no proof
/// either way (a pooled lock moves between directories when a session takes it): false.
#[cfg(unix)]
fn dead_now_in(dirs: &[PathBuf], session_id: &str, start_nonce: &str) -> bool {
    use std::os::fd::AsRawFd;
    for dir in dirs {
        let path = live_path(dir, session_id, start_nonce);
        let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(&path) else {
            continue;
        };
        // SAFETY: a non-blocking lock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return false;
        }
        // An explicit unlock, as in `take_death_lock`: a child spawned meanwhile may hold a copy
        // of this descriptor, and a probe must not leave the lock held.
        // SAFETY: same descriptor.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        return true;
    }
    false
}
/// Windows port: no lock probe yet (as [`take_death_lock`]); the link's end decides.
#[cfg(not(unix))]
fn dead_now_in(_dirs: &[PathBuf], _session_id: &str, _start_nonce: &str) -> bool {
    false
}

#[cfg(all(test, unix))]
mod dead_now_tests {
    use super::*;
    use std::os::fd::AsRawFd;

    #[test]
    fn a_held_lock_is_alive_a_free_one_is_dead_and_none_is_no_proof() {
        let dir = tempfile::tempdir().unwrap();
        let dirs = vec![dir.path().join("pool"), dir.path().to_path_buf()];
        assert!(!dead_now_in(&dirs, "s1", "n1"), "no lock file is no proof");
        let host = std::fs::File::create(live_path(dir.path(), "s1", "n1")).unwrap();
        // SAFETY: an exclusive lock on the descriptor this test owns, as a host takes its own.
        assert_eq!(unsafe { libc::flock(host.as_raw_fd(), libc::LOCK_EX) }, 0);
        assert!(!dead_now_in(&dirs, "s1", "n1"), "a held lock is a live host");
        assert!(!dead_now_in(&dirs, "s1", "n1"), "a probe leaves a held lock held");
        drop(host);
        assert!(dead_now_in(&dirs, "s1", "n1"), "a free lock is a dead host");
        assert!(dead_now_in(&dirs, "s1", "n1"), "a probe releases what it took");
    }
}
