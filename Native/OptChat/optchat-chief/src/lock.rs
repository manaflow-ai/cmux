//! The host lock, the protocol of `mux/host/src/lock.ts` (chief-mac.md
//! section 2): an exclusive non-blocking flock(2) on `$MUX_HOME/state/host.lock`,
//! held by keeping the descriptor open for the process's life. The kernel
//! drops it however the process ends, so there is no stale lock. The file is
//! never removed (removing a locked file would let a second taker lock a new
//! file at the same path). Its text `<pid>\n<start ms>\nflock\n` is for
//! diagnostics; the `flock` mark line tells a kernel-lock host from an older
//! one that held the lock by text only.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Marks a lock file written by a kernel-lock host.
pub const FLOCK_MARK: &str = "flock";
/// `ps` reports whole seconds.
const START_SLACK_MS: i64 = 1_000;

/// The held lock. Dropping it closes the descriptor, which drops the flock.
#[derive(Debug)]
pub struct HostLock {
    _file: File,
}

impl Drop for HostLock {
    fn drop(&mut self) {
        // A concurrent fork can inherit this open file description. Closing
        // our descriptor alone then leaves the flock held until the child
        // closes its copy. Explicitly unlock when the host guard drops.
        let _ = self._file.unlock();
    }
}

#[derive(Debug)]
pub enum LockError {
    /// Another open file holds the flock: a host already runs for this home.
    Held,
    /// An older host holds the lock by its text only (pid given).
    Older(i32),
    Io(io::Error),
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::Held => f.write_str("another host holds the lock"),
            LockError::Older(pid) => {
                write!(
                    f,
                    "an older mux host (pid {pid}) holds the lock without a kernel lock"
                )
            }
            LockError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl HostLock {
    /// Takes the lock. `started_ms` is this process's start, written for diagnostics.
    pub fn take(path: &Path, started_ms: u64) -> Result<HostLock, LockError> {
        // std opens with O_CLOEXEC, so the descriptor never leaks into a child
        // (the acpmux daemon outlives the host and would keep the flock).
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(path)
            .map_err(LockError::Io)?;
        match file.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Err(LockError::Held),
            Err(TryLockError::Error(e)) => return Err(LockError::Io(e)),
        }
        let mut text = String::new();
        file.seek(SeekFrom::Start(0)).map_err(LockError::Io)?;
        // Unreadable text cannot name an older host.
        let _ = file.read_to_string(&mut text);
        let mtime_ms = file
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .map(epoch_ms)
            .unwrap_or(0);
        if let Some(pid) = older_host(&text, mtime_ms, std::process::id() as i32, &SystemProbe) {
            return Err(LockError::Older(pid));
        }
        // Diagnostics only: the flock is the lock.
        if file.set_len(0).is_ok() {
            let _ = file.write_all(
                format!("{}\n{started_ms}\n{FLOCK_MARK}\n", std::process::id()).as_bytes(),
            );
        }
        Ok(HostLock { _file: file })
    }
}

/// What the older-host check asks of the OS.
pub trait ProcessProbe {
    fn alive(&self, pid: i32) -> bool;
    /// The process's start, epoch ms, if known.
    fn start_ms(&self, pid: i32) -> Option<i64>;
}

/// Whether a host holds the lock at `path` now (a non-blocking probe on its
/// own descriptor, released at once). A missing file or another error says
/// no host. Also true for this process's own held lock.
pub fn held(path: &Path) -> bool {
    let Ok(file) = OpenOptions::new().read(true).open(path) else {
        return false;
    };
    match file.try_lock() {
        Ok(()) => {
            let _ = file.unlock();
            false
        }
        Err(TryLockError::WouldBlock) => true,
        Err(TryLockError::Error(_)) => false,
    }
}

/// The file next to the host lock `lock` that says its host is stopping
/// (`mark_stopping`): a host that stops no longer uses its acpmux, so other
/// Chiefs that stop at the same time do not count it (the last of them stops
/// the Chief home's acpmux). The next host of that home removes it when it
/// takes the lock.
fn stopping_file(lock: &Path) -> std::path::PathBuf {
    lock.with_file_name("host.stopping")
}

/// Marks the host of `lock` (this one) as stopping.
pub fn mark_stopping(lock: &Path) {
    let _ = std::fs::write(stopping_file(lock), format!("{}\n", std::process::id()));
}

/// Clears the mark, at a host's start.
pub fn clear_stopping(lock: &Path) {
    let _ = std::fs::remove_file(stopping_file(lock));
}

/// The file next to the host lock `lock` that names the host (its pid) that
/// takes SIGUSR1 as "hand off when idle" (an update: the app waits for the
/// Chief's turn to end before it hands acpmux off). An older host has no
/// such file, and SIGUSR1 would end it at once, so the app does not send it.
pub fn handoff_file(lock: &Path) -> std::path::PathBuf {
    lock.with_file_name("host.handoff")
}

/// Says that this host (holding `lock`) takes SIGUSR1 as a handoff request.
pub fn mark_handoff_when_idle(lock: &Path) {
    let _ = std::fs::write(handoff_file(lock), format!("{}\n", std::process::id()));
}

/// Whether a host runs on `lock` and is not stopping.
pub fn in_use(lock: &Path) -> bool {
    held(lock) && !stopping_file(lock).exists()
}

/// Upgrade check, REMOVE AFTER ONE RELEASE (chief-mac.md section 2): a lock
/// text without the mark that names a live process whose start is no later
/// than the recorded start (or the file's mtime) plus 1 s is an older host
/// that is still running. A reused pid starts later, so the check is one-sided;
/// an unknown start counts as the older host.
pub fn older_host(text: &str, mtime_ms: i64, me: i32, probe: &dyn ProcessProbe) -> Option<i32> {
    let lines: Vec<&str> = text.trim().split('\n').collect();
    if lines.contains(&FLOCK_MARK) {
        return None;
    }
    let pid: i32 = lines.first()?.trim().parse().ok()?;
    if pid <= 0 || pid == me || !probe.alive(pid) {
        return None;
    }
    // lock.ts falls back to the mtime for an empty line as for a missing one.
    let recorded = match lines.get(1).filter(|l| !l.trim().is_empty()) {
        Some(line) => line.trim().parse::<f64>().ok().filter(|v| v.is_finite())? as i64,
        None => mtime_ms,
    };
    match probe.start_ms(pid) {
        Some(started) if started > recorded + START_SLACK_MS => None,
        _ => Some(pid),
    }
}

struct SystemProbe;

impl ProcessProbe for SystemProbe {
    fn alive(&self, pid: i32) -> bool {
        // SAFETY: kill with signal 0 only checks that the pid exists.
        let rc = unsafe { libc::kill(pid, 0) };
        rc == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }

    fn start_ms(&self, pid: i32) -> Option<i64> {
        // Absolute path: the PATH of a host the app started is not trusted for this.
        let out = std::process::Command::new("/bin/ps")
            .args(["-o", "lstart=", "-p", &pid.to_string()])
            .env("LC_ALL", "C")
            .env("TZ", "UTC")
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        parse_lstart(&String::from_utf8_lossy(&out.stdout))
    }
}

/// `ps -o lstart` in the C locale and UTC ("Sat Oct  3 22:21:45 2026") as epoch ms.
pub fn parse_lstart(text: &str) -> Option<i64> {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let at = chrono::NaiveDateTime::parse_from_str(&flat, "%a %b %d %H:%M:%S %Y").ok()?;
    Some(at.and_utc().timestamp_millis())
}

pub fn epoch_ms(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
