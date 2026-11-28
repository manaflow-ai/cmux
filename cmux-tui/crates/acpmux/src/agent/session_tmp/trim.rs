//! An open session's temporary folder kept under a size cap (`session.tmpMaxMb`, default 2 GiB).
//! A folder went only at its session's close, purge or the daemon's start, and long-lived
//! sessions are rarely closed (gcp-codex-lane-5, 2026-11-27: 6.7 GiB in one open session's
//! folder: `cmux-web-lint-*`, `fast-gate-webviews-base-*`, Python `tmp*`, 1 to 2 GiB each).
//!
//! Over the cap, top-level entries untouched (newest mtime or ctime in them) for
//! `session.tmpIdleMinutes` (default 30) go, oldest first, until the folder is under it again;
//! never one acpmux keeps for the agent's life (`copilot_auth`, `command/grok_key`), never one in
//! which any file is held open ([`held`]). Each is moved aside into the daemon's root
//! (`.gone-*`, which a starting daemon removes), checked again there, and moved back if held.
//!
//! Held, without scanning processes (plans/cmux-next/pty-holder.md 4): Linux grants a write
//! lease (`F_SETLEASE`) only on a file no other open file description has, for reading, writing,
//! mapping or running; it is let go at once. A socket is held when a connect to it is answered;
//! any other special file and any error count as held. Linux only: macOS has no such test. A process's cwd holds nothing open: the idle time keeps that entry.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// What one [`trim`] of a folder did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Trimmed {
    /// The folder's allocated bytes before the pass and after it.
    pub(crate) before: u64,
    pub(crate) after: u64,
    /// Top-level entries removed.
    pub(crate) evicted: usize,
    /// Top-level entries left while the folder was still over the cap: held open, touched
    /// within the idle time, or acpmux's own.
    pub(crate) kept: usize,
}

/// `session.tmpMaxMb` in bytes (unset 2048 MiB); None: off.
pub(crate) fn cap_bytes(cfg: &crate::config::SessionResourceConfig) -> Option<u64> {
    Some(cfg.tmp_max_mb.unwrap_or(2048)).filter(|&mb| mb > 0).map(|mb| mb.saturating_mul(1 << 20))
}

/// `session.tmpIdleMinutes` (unset 30).
pub(crate) fn idle(cfg: &crate::config::SessionResourceConfig) -> Duration {
    Duration::from_secs(cfg.tmp_idle_minutes.unwrap_or(30).saturating_mul(60))
}

/// Names acpmux puts in a session's folder for the agent's life: never taken.
fn acpmux_own(name: &str) -> bool {
    name == "opencode" || name.starts_with("copilot-") || name.starts_with("grok-key-")
}

/// `path`'s allocated bytes and the newest mtime or ctime in it, never following a symlink.
fn measure(path: &Path) -> (u64, SystemTime) {
    use std::os::unix::fs::MetadataExt as _;
    let mut bytes = 0u64;
    let mut newest = SystemTime::UNIX_EPOCH;
    let mut todo = vec![path.to_path_buf()];
    while let Some(p) = todo.pop() {
        let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
        bytes = bytes.saturating_add(meta.blocks().saturating_mul(512));
        let ctime = SystemTime::UNIX_EPOCH + Duration::from_secs(meta.ctime().max(0) as u64);
        let changed = meta.modified().map_or(ctime, |m| m.max(ctime));
        newest = newest.max(changed);
        if meta.file_type().is_dir()
            && let Ok(entries) = std::fs::read_dir(&p)
        {
            todo.extend(entries.flatten().map(|e| e.path()));
        }
    }
    (bytes, newest)
}

/// Whether a process may hold anything in `path` open (module docs): true unless every file in
/// it is shown free.
pub(crate) fn held(path: &Path) -> bool {
    let mut todo = vec![path.to_path_buf()];
    while let Some(p) = todo.pop() {
        let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
        let kind = meta.file_type();
        if kind.is_symlink() {
            continue;
        }
        if kind.is_dir() {
            let Ok(entries) = std::fs::read_dir(&p) else { return true };
            todo.extend(entries.flatten().map(|e| e.path()));
            continue;
        }
        if file_held(&p, kind) {
            return true;
        }
    }
    false
}

fn file_held(path: &Path, kind: std::fs::FileType) -> bool {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::fs::{FileTypeExt as _, OpenOptionsExt as _};
    if kind.is_socket() {
        return match std::os::unix::net::UnixStream::connect(path) {
            Err(e) => e.raw_os_error() != Some(libc::ECONNREFUSED),
            Ok(_) => true,
        };
    }
    if !kind.is_file() {
        return true;
    }
    let open = |noatime: libc::c_int| {
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | noatime)
            .open(path)
    };
    let file = match open(libc::O_NOATIME) {
        Err(e) if e.raw_os_error() == Some(libc::EPERM) => open(0),
        other => other,
    };
    let Ok(file) = file else { return true };
    // Linux's F_SETSIG, which the libc crate does not name.
    const F_SETSIG: libc::c_int = 10;
    let fd = file.as_raw_fd();
    // SAFETY: fcntl on an fd this function owns; F_SETSIG and F_SETLEASE take an int.
    unsafe {
        if libc::fcntl(fd, F_SETSIG, libc::SIGURG) != 0 {
            return true;
        }
        if libc::fcntl(fd, libc::F_SETLEASE, libc::F_WRLCK) != 0 {
            return true;
        }
        libc::fcntl(fd, libc::F_SETLEASE, libc::F_UNLCK);
    }
    false
}

/// Remove `path`, a file, symlink or real directory, never following a symlink.
fn remove_entry(path: &Path) {
    let is_dir = std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_dir());
    let gone = if is_dir {
        crate::home_fs::remove_dir_all(path)
    } else {
        crate::home_fs::remove_file(path)
    };
    if let Err(e) = gone {
        tracing::debug!(path = %path.display(), "session tmp entry not removed: {e}");
    }
}

/// Keep `dir`, an open session's folder, under `cap` bytes (module docs). Entries that go are
/// moved aside into `aside_root` (the daemon's root, on the same disk) first. Blocking.
pub(crate) fn trim(
    dir: &Path,
    aside_root: &Path,
    cap: u64,
    idle: Duration,
    now: SystemTime,
) -> Trimmed {
    use std::os::unix::fs::MetadataExt as _;
    let own = std::fs::symlink_metadata(dir).map_or(0, |m| m.blocks().saturating_mul(512));
    let Ok(listing) = std::fs::read_dir(dir) else { return Trimmed::default() };
    // (newest change, path, bytes, acpmux's own)
    let mut entries: Vec<(SystemTime, PathBuf, u64, bool)> = listing
        .flatten()
        .map(|e| {
            let (bytes, newest) = measure(&e.path());
            (newest, e.path(), bytes, e.file_name().to_str().is_some_and(acpmux_own))
        })
        .collect();
    let before = own + entries.iter().map(|e| e.2).sum::<u64>();
    let mut out = Trimmed { before, after: before, ..Trimmed::default() };
    if before <= cap {
        return out;
    }
    entries.sort_by_key(|e| e.0);
    for (newest, path, bytes, mine) in entries {
        if out.after <= cap {
            break;
        }
        let untouched = now.duration_since(newest).is_ok_and(|age| age >= idle);
        if mine || !untouched || held(&path) {
            out.kept += 1;
            continue;
        }
        let aside =
            aside_root.join(format!("{}{}", super::GONE_PREFIX, uuid::Uuid::now_v7().simple()));
        if crate::home_fs::rename(&path, &aside).is_err() {
            out.kept += 1;
            continue;
        }
        // Opened between the look and the move: back it goes (beside its name if that was
        // taken meanwhile), never left under a name a starting daemon removes.
        if held(&aside) {
            let back = if std::fs::symlink_metadata(&path).is_err() {
                path.clone()
            } else {
                let mut name = path.as_os_str().to_owned();
                name.push(format!(".{}", uuid::Uuid::now_v7().simple()));
                PathBuf::from(name)
            };
            let _ = crate::home_fs::rename(&aside, &back);
            out.kept += 1;
            continue;
        }
        remove_entry(&aside);
        out.after = out.after.saturating_sub(bytes);
        out.evicted += 1;
    }
    out
}
