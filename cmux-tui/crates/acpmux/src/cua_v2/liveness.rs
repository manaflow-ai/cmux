//! Whether `endpoint.json` names a helper v2 that runs now (cx-zgk0).
//!
//! The app removes the file when it stops the helper, but a host crash
//! (SIGKILL, panic) leaves it, and this daemon outlives the app: every new
//! session then got the bridge to a dead socket and a tool error until the
//! next helper start. A session now gets the bridge only when the file's
//! owner (the helper pid, with its start time when the app recorded it) is
//! alive and the socket accepts a connection. A file proven stale is removed,
//! so sessions get the legacy `cmux-cua mcp` until the app writes a new one.

#[cfg(unix)]
use std::path::Path;

/// The helper process the app recorded in `endpoint.json`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Owner {
    pub pid: i32,
    /// `proc_bsdinfo.pbi_start_tvsec` / `pbi_start_tvusec` (macOS).
    pub start: Option<(u64, u64)>,
}

impl Owner {
    /// `pid`, `start_sec`, `start_usec` of an `endpoint.json` value; none for
    /// a file from an app build that does not record its owner.
    pub fn from_json(value: &serde_json::Value) -> Option<Self> {
        let pid = i32::try_from(value["pid"].as_i64()?).ok().filter(|pid| *pid > 1)?;
        let start = value["start_sec"].as_u64().zip(value["start_usec"].as_u64());
        Some(Owner { pid, start })
    }
}

/// Why an `endpoint.json` is stale, for the log.
#[cfg(unix)]
#[derive(Debug, PartialEq, Eq)]
pub enum Stale {
    OwnerGone(i32),
    OwnerReplaced(i32),
    /// The socket refused. `owner_alive`: the recorded helper still runs, so
    /// the refusal may pass (a full backlog) and the file is kept.
    SocketDead {
        error: String,
        owner_alive: bool,
    },
}

#[cfg(unix)]
impl Stale {
    /// Whether the file is proven to name no running helper, so it may go.
    pub fn removable(&self) -> bool {
        !matches!(self, Stale::SocketDead { owner_alive: true, .. })
    }
}

/// `Ok` when the owner (if recorded) runs and `socket` accepts a connection.
#[cfg(unix)]
pub fn check(owner: Option<Owner>, socket: &Path) -> Result<(), Stale> {
    if let Some(owner) = owner {
        // SAFETY: signal 0 only checks that the pid exists; nothing is sent.
        let alive = unsafe { libc::kill(owner.pid, 0) } == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
        if !alive {
            return Err(Stale::OwnerGone(owner.pid));
        }
        if let (Some(start), Some(now)) = (owner.start, start_time(owner.pid))
            && start != now
        {
            return Err(Stale::OwnerReplaced(owner.pid));
        }
    }
    // A connect only: the helper drops a peer that sends no secret.
    match std::os::unix::net::UnixStream::connect(socket) {
        Ok(_) => Ok(()),
        Err(error) => {
            Err(Stale::SocketDead { error: error.to_string(), owner_alive: owner.is_some() })
        }
    }
}

/// The start time of `pid` as the app records it, on macOS (also the
/// Claude Code registry check, `adopt_live`).
#[cfg(target_os = "macos")]
pub(crate) fn start_time(pid: i32) -> Option<(u64, u64)> {
    // SAFETY: proc_bsdinfo is plain C data; all zero bytes is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is a writable proc_bsdinfo of `size` bytes.
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

/// The helper runs only on macOS; elsewhere the pid and socket checks decide.
#[cfg(all(unix, not(target_os = "macos")))]
fn start_time(_pid: i32) -> Option<(u64, u64)> {
    None
}

/// Removes `path` when it still holds `text`, so a file the app wrote for a
/// new helper since it was read stays.
#[cfg(unix)]
pub fn remove_if_unchanged(path: &Path, text: &str) {
    if std::fs::read_to_string(path).is_ok_and(|now| now == text) {
        let _ = std::fs::remove_file(path);
    }
}
