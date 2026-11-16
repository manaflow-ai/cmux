//! `daemon.log` stays bounded. The daemon's stdout and stderr are that file, opened for append by
//! whatever started it (`spawn_detached`, the login-session job), and nothing ever cut it: Leo's
//! laptop had 88 MB of it from a month of runs (2026-11-11, cmuxterm-hq#9263).
//!
//! At its start, once it holds the home's lock (no other daemon writes the file then), a daemon
//! whose stderr is `daemon.log` and finds it past [`CAP`] moves it to `daemon.log.1` (replacing
//! the one before) and points its stdout and stderr at a new `daemon.log`. So the home keeps at
//! most this run's log and the one before it past the cap. A daemon whose output goes elsewhere (a
//! terminal, a test's pipe) leaves the file alone.

use std::path::Path;

/// The size past which a starting daemon moves its log aside.
pub(super) const CAP: u64 = 32 << 20;

/// The log's previous copy, beside it.
pub(super) fn previous(log: &Path) -> std::path::PathBuf {
    log.with_extension("log.1")
}

/// Moves `log` to [`previous`] and reopens stdout and stderr on a new `log` when it is past
/// `cap` and stderr is that file; whether it did. Errors leave the log as it was.
pub(super) fn rotate_at_start(log: &Path, cap: u64) -> anyhow::Result<bool> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = std::fs::symlink_metadata(log) else { return Ok(false) };
    if !meta.is_file() || meta.len() <= cap {
        return Ok(false);
    }
    let same = |fd: i32| {
        // SAFETY: `fstat` writes into the zeroed struct it is given, and only reads `fd`.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        (unsafe { libc::fstat(fd, &mut st) } == 0)
            && st.st_dev as u64 == meta.dev()
            && st.st_ino as u64 == meta.ino()
    };
    if !same(libc::STDERR_FILENO) {
        return Ok(false);
    }
    let out = same(libc::STDOUT_FILENO);
    crate::home_fs::rename(log, previous(log))?;
    let fresh = crate::config::private_state_append(log)?;
    for (fd, take) in [(libc::STDERR_FILENO, true), (libc::STDOUT_FILENO, out)] {
        // SAFETY: both descriptors are open; `dup2` swaps the target atomically.
        if take && unsafe { libc::dup2(fresh.as_raw_fd(), fd) } < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(true)
}

#[cfg(test)]
#[path = "log_cap_tests.rs"]
mod tests;
