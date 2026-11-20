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

/// Points each of `fds` that writes to `/dev/null` at `log` (opened for append, owner-only);
/// whether any did. A daemon is started by many hands (the CLI's `spawn_detached`, the login-session
/// job, an update's `--take-over` successor, the app); one that gave it no output file must not
/// leave the daemon blind: the 2026-11-17 NIGHTLY's daemon ran a morning with stdout and stderr on
/// `/dev/null`, so no start failure it saw was written anywhere. Output that goes elsewhere (a
/// terminal, a pipe, a file) is left alone.
pub(super) fn adopt_discarded_output(log: &Path, fds: &[i32]) -> anyhow::Result<bool> {
    use std::os::fd::AsRawFd;
    let discarded: Vec<i32> = fds.iter().copied().filter(|&fd| writes_to_dev_null(fd)).collect();
    if discarded.is_empty() {
        return Ok(false);
    }
    let file = crate::config::private_state_append(log)?;
    for fd in discarded {
        // SAFETY: `fd` is open (fstat answered) and `file` is open; `dup2` swaps it atomically.
        if unsafe { libc::dup2(file.as_raw_fd(), fd) } < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(true)
}

/// Whether `fd` is open on `/dev/null`: the same character device.
fn writes_to_dev_null(fd: i32) -> bool {
    // SAFETY: `fstat`/`stat` write into the zeroed structs they are given and only read their input.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } != 0 || (st.st_mode & libc::S_IFMT) != libc::S_IFCHR {
        return false;
    }
    let mut null: libc::stat = unsafe { std::mem::zeroed() };
    let path = c"/dev/null";
    (unsafe { libc::stat(path.as_ptr(), &mut null) } == 0) && null.st_rdev == st.st_rdev
}

#[cfg(test)]
#[path = "log_cap_tests.rs"]
mod tests;
