//! The daemon lock: one daemon per home holds `daemon.lock` while it runs.

use anyhow::Result;
#[cfg(unix)]
use anyhow::anyhow;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The daemon lock, held while the daemon runs. Dropping it unlocks
/// explicitly: a child forked but not yet exec'd shares the open file
/// description, so closing this descriptor alone would leave the lock held
/// after the daemon exits, and the next daemon would find it taken.
pub(super) struct DaemonLock(std::fs::File);

#[cfg(unix)]
impl Drop for DaemonLock {
    fn drop(&mut self) {
        use std::os::unix::io::AsRawFd;
        // SAFETY: flock on the descriptor this guard owns.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

/// Another daemon holds the lock: one that is stopping or starting. Any other failure to take
/// the lock (permissions, a symlink, an I/O error) is a plain error.
#[derive(Debug)]
pub(super) struct LockHeld(PathBuf);

impl std::fmt::Display for LockHeld {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "another acpmux daemon holds {}", self.0.display())
    }
}

impl std::error::Error for LockHeld {}

#[cfg(unix)]
pub(super) fn acquire_lock(path: &Path) -> Result<DaemonLock> {
    use std::os::unix::io::AsRawFd;
    let file = crate::config::private_state_rw(path)?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::WouldBlock {
            return Err(LockHeld(path.to_owned()).into());
        }
        return Err(anyhow!("lock {}: {e}", path.display()));
    }
    Ok(DaemonLock(file))
}
/// Windows: an exclusive `LockFileEx` lock (std's `File::try_lock`), held
/// while the file stays open; the system releases it when the daemon exits
/// (a child gets no copy: the daemon starts children with a handle list).
#[cfg(windows)]
pub(super) fn acquire_lock(path: &Path) -> Result<DaemonLock> {
    use anyhow::Context;
    let file = crate::config::private_state_rw(path)?;
    match file.try_lock() {
        Ok(()) => Ok(DaemonLock(file)),
        Err(std::fs::TryLockError::WouldBlock) => Err(LockHeld(path.to_owned()).into()),
        Err(std::fs::TryLockError::Error(e)) => {
            Err(anyhow::Error::new(e).context(format!("lock {}", path.display())))
        }
    }
}

/// Polls a non-blocking `flock`, so the deadline always ends the wait: a
/// blocking `flock` on a worker thread would outlive the timeout and hold
/// up runtime teardown.
#[cfg(unix)]
pub(super) async fn wait_for_lock_release(lock: PathBuf, budget: Duration) -> bool {
    use std::os::unix::io::AsRawFd;
    let Ok(file) = crate::config::private_state_rw(&lock) else {
        return true;
    };
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return true;
        }
        let kind = std::io::Error::last_os_error().kind();
        if kind != std::io::ErrorKind::WouldBlock && kind != std::io::ErrorKind::Interrupted {
            return false;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
/// Windows: polls a non-blocking `LockFileEx` (std's `File::try_lock`), as
/// the Unix arm polls `flock`.
#[cfg(windows)]
pub(super) async fn wait_for_lock_release(lock: PathBuf, budget: Duration) -> bool {
    let Ok(file) = crate::config::private_state_rw(&lock) else {
        return true;
    };
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        match file.try_lock() {
            Ok(()) => return true,
            Err(std::fs::TryLockError::WouldBlock) => {}
            Err(std::fs::TryLockError::Error(_)) => return false,
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Debug builds only: `ACPMUX_TEST_FORK_HOLD_MS` forks a child that sleeps
/// and exits without exec, as a spawn (a model probe, an agent host) that
/// is forked but has not reached its exec yet. Until it execs, the child
/// shares the daemon's descriptors, the lock among them. Bounded.
#[cfg(all(unix, debug_assertions))]
pub(super) fn fork_a_child_for_tests() {
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_FORK_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        let ms = ms.min(5_000);
        let nap = libc::timespec {
            tv_sec: (ms / 1_000) as libc::time_t,
            tv_nsec: ((ms % 1_000) * 1_000_000) as libc::c_long,
        };
        // SAFETY: the child only calls nanosleep and _exit, both
        // async-signal-safe, and touches no Rust state.
        if unsafe { libc::fork() } == 0 {
            unsafe {
                libc::nanosleep(&nap, std::ptr::null_mut());
                libc::_exit(0);
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn daemon_lock_refuses_a_symlink() {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-lock-link-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("outside");
        let lock = dir.join("daemon.lock");
        std::fs::write(&target, "outside").unwrap();
        std::os::unix::fs::symlink(&target, &lock).unwrap();

        assert!(acquire_lock(&lock).is_err(), "the daemon locked through a symlink");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "outside");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
