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

/// Another daemon holds the lock: one that runs, or is stopping or starting. Any other failure
/// to take the lock (permissions, a symlink, an I/O error) is a plain error. It names the
/// holder's pid when the lock file records a live one, and the command that shows that daemon;
/// the lock and the socket are the holder's, so it never suggests clearing either.
#[derive(Debug)]
pub(super) struct LockHeld {
    path: PathBuf,
    pid: Option<u32>,
}

impl LockHeld {
    #[cfg(unix)]
    fn new(path: &Path, file: &std::fs::File) -> Self {
        Self { path: path.to_owned(), pid: holder_pid(file) }
    }

    /// `acpmux daemon status` as it reaches the daemon of this lock's home: with the home (and
    /// this process's socket) when they are not the defaults.
    fn status_command(&self) -> String {
        let mut env = Vec::new();
        if let Some(socket) = std::env::var_os("ACPMUX_SOCKET").filter(|v| !v.is_empty()) {
            env.push(format!("ACPMUX_SOCKET={}", shell_word(&socket.to_string_lossy())));
        }
        let home = self.path.parent().unwrap_or(Path::new("."));
        if home != crate::config::default_home() {
            env.push(format!("ACPMUX_HOME={}", shell_word(&home.to_string_lossy())));
        }
        env.push("acpmux daemon status".into());
        env.join(" ")
    }
}

impl std::fmt::Display for LockHeld {
    // "another acpmux daemon holds PATH" stays the message's start: a start that waits out a
    // handover, and its tests, match it.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let holder = self.pid.map(|pid| format!(" (pid {pid})")).unwrap_or_default();
        write!(
            f,
            "another acpmux daemon holds {}{holder}. See it with `{}`; the lock and its socket are that daemon's, so leave them in place (stop it with `acpmux daemon shutdown` to run another here).",
            self.path.display(),
            self.status_command()
        )
    }
}

impl std::error::Error for LockHeld {}

/// `word` as one shell word: as is when it holds only safe characters, else single-quoted.
fn shell_word(word: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "/._-+:@%=,".contains(c);
    if !word.is_empty() && word.chars().all(safe) {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', r"'\''"))
    }
}

/// The pid the lock's holder wrote into it ([`record_pid`]), when that process still runs.
#[cfg(unix)]
fn holder_pid(file: &std::fs::File) -> Option<u32> {
    use std::os::unix::fs::FileExt;
    let mut buf = [0u8; 16];
    let n = file.read_at(&mut buf, 0).ok()?;
    let pid: libc::pid_t = std::str::from_utf8(&buf[..n]).ok()?.trim().parse().ok()?;
    if pid <= 0 {
        return None;
    }
    // SAFETY: signal 0 sends nothing; it only asks whether the process exists. EPERM: it does,
    // as another user's.
    let alive = unsafe { libc::kill(pid, 0) } == 0
        || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    alive.then_some(pid as u32)
}

/// Write this daemon's pid into the lock it now holds, for the refusal a second daemon prints.
/// Best effort: the lock itself is the flock, never the file's contents.
#[cfg(unix)]
fn record_pid(file: &std::fs::File) {
    use std::os::unix::fs::FileExt;
    let pid = format!("{}\n", std::process::id());
    if file.set_len(0).is_ok() {
        let _ = file.write_at(pid.as_bytes(), 0);
    }
}

#[cfg(unix)]
pub(super) fn acquire_lock(path: &Path) -> Result<DaemonLock> {
    use std::os::unix::io::AsRawFd;
    let file = crate::config::private_state_rw(path)?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::WouldBlock {
            return Err(LockHeld::new(path, &file).into());
        }
        return Err(anyhow!("lock {}: {e}", path.display()));
    }
    record_pid(&file);
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
        // The lock covers the file, so its holder's pid cannot be read here.
        Err(std::fs::TryLockError::WouldBlock) => {
            Err(LockHeld { path: path.to_owned(), pid: None }.into())
        }
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

    /// A second daemon on a home names the one that holds its lock, by pid,
    /// and the command that shows it on that home; it never suggests
    /// removing the lock or the socket (ergo-walk, 2026-10-25).
    #[test]
    fn a_held_lock_names_its_daemon_and_how_to_see_it() {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-lock-held-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let lock = dir.join("daemon.lock");
        let held = acquire_lock(&lock).unwrap();
        let why = acquire_lock(&lock).err().expect("the lock is held").to_string();
        // The start every handover matches on stays.
        assert!(why.starts_with(&format!("another acpmux daemon holds {}", lock.display())));
        assert!(why.contains(&format!("pid {}", std::process::id())), "{why}");
        assert!(
            why.contains(&format!("ACPMUX_HOME={} acpmux daemon status", dir.display())),
            "{why}"
        );
        for removal in ["rm ", "delete", "remove"] {
            assert!(!why.contains(removal), "{why}");
        }
        // A pid the file still records from a daemon that is gone is not named.
        std::fs::write(&lock, format!("{}\n", i32::MAX)).unwrap();
        let why = acquire_lock(&lock).err().expect("the lock is held").to_string();
        assert!(!why.contains("pid "), "{why}");
        assert!(why.contains("acpmux daemon status"), "{why}");
        drop(held);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
