//! Whether `endpoint.json` names a helper v2 that runs now (cx-zgk0).
//!
//! The app removes the file when it stops the helper, but a host crash
//! (SIGKILL, panic) leaves it, and this daemon outlives the app: every new
//! session then got the bridge to a dead socket and a tool error until the
//! next helper start. A session now gets the bridge only when the file's
//! owner (the helper pid, with its start time when the app recorded it) is
//! alive and the socket accepts a connection. A file proven stale is removed,
//! so sessions get the legacy `cmux-cua mcp` until the app writes a new one.
//!
//! Windows: the owner is the cmux Remote host's Computer Use worker (`pid`,
//! and `start`, its creation time); the socket is its named pipe, and a
//! pipe whose every instance is busy is served, so it counts as live.

use std::path::Path;

/// The helper process the app recorded in `endpoint.json`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Owner {
    pub pid: i32,
    /// `proc_bsdinfo.pbi_start_tvsec` / `pbi_start_tvusec` (macOS), or
    /// `(start, 0)` from a cmux Remote host's `start` (Windows: the
    /// process creation FILETIME; Linux: start ticks since boot, compared with
    /// `/proc/<pid>/stat` by `server_is_owner`).
    pub start: Option<(u64, u64)>,
}

impl Owner {
    /// `pid`, `start_sec`, `start_usec` of an `endpoint.json` value; none for
    /// a file from an app build that does not record its owner.
    pub fn from_json(value: &serde_json::Value) -> Option<Self> {
        let pid = i32::try_from(value["pid"].as_i64()?).ok().filter(|pid| *pid > 1)?;
        let start = value["start_sec"]
            .as_u64()
            .zip(value["start_usec"].as_u64())
            .or_else(|| value.get("start").and_then(serde_json::Value::as_u64).filter(|start| *start != 0).map(|start| (start, 0)));
        Some(Owner { pid, start })
    }
}

/// Why an `endpoint.json` is stale, for the log.
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

/// Linux: the start time in clock ticks (`/proc/<pid>/stat` field 22), as
/// the cmux Remote host records its worker's `start` (`(ticks, 0)`).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn start_time(pid: i32) -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ...`: comm may hold spaces and parentheses.
    let rest = stat.get(stat.rfind(')')?.checked_add(1)?..)?;
    let ticks = rest.split_whitespace().nth(19)?.parse().ok()?;
    Some((ticks, 0))
}

/// Other Unix systems run no helper; the pid and socket checks decide.
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux", target_os = "android"))))]
pub(crate) fn start_time(_pid: i32) -> Option<(u64, u64)> {
    None
}

/// Before the secret goes out: the endpoint's server must be the process
/// `endpoint.json` names (its pid, and its start time when recorded), not
/// merely a process of this user. `server_pid` and `server_start` are the
/// kernel's view of the connected server; with no recorded owner any
/// same-user server passes (an older writer).
pub(crate) fn server_is_owner(
    server_pid: Option<i32>,
    server_start: Option<(u64, u64)>,
    owner: Option<Owner>,
) -> Result<(), String> {
    let Some(owner) = owner else { return Ok(()) };
    let Some(pid) = server_pid else {
        return Err("cannot read the server's process id".into());
    };
    if pid != owner.pid {
        return Err(format!("it is served by pid {pid}, not the recorded owner {}", owner.pid));
    }
    match (owner.start, server_start) {
        (None, _) => Ok(()),
        (Some(recorded), Some(now)) if recorded == now => Ok(()),
        (Some(_), Some(_)) => Err(format!("pid {pid} is a later process than the recorded owner")),
        (Some(_), None) => Err(format!("cannot read the start time of pid {pid}")),
    }
}

/// `Ok` when the owner (if recorded) runs and the pipe `socket` has a server.
#[cfg(windows)]
pub fn check(owner: Option<Owner>, socket: &Path) -> Result<(), Stale> {
    if let Some(owner) = owner {
        match process_start(owner.pid) {
            Process::Gone => return Err(Stale::OwnerGone(owner.pid)),
            Process::Alive(Some(now)) if owner.start.is_some_and(|start| start != now) => {
                return Err(Stale::OwnerReplaced(owner.pid));
            }
            Process::Alive(_) => {}
        }
    }
    match super::pipe::probe(socket) {
        Ok(()) => Ok(()),
        Err(error) => Err(Stale::SocketDead { error, owner_alive: owner.is_some() }),
    }
}

#[cfg(windows)]
pub(super) enum Process {
    Gone,
    /// Alive, with its creation time when this user may read it.
    Alive(Option<(u64, u64)>),
}

/// Whether `pid` runs, and its creation time as the host records it
/// (`(FILETIME, 0)`). A process another user owns answers access denied:
/// alive, start unknown (as EPERM is on Unix).
#[cfg(windows)]
pub(super) fn process_start(pid: i32) -> Process {
    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, FILETIME};
    use windows_sys::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    let Ok(pid) = u32::try_from(pid) else { return Process::Gone };
    // SAFETY: plain call; a null handle is handled.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        let denied = std::io::Error::last_os_error().raw_os_error()
            == Some(ERROR_ACCESS_DENIED as i32);
        return if denied { Process::Alive(None) } else { Process::Gone };
    }
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    // SAFETY: a process handle with query rights and four FILETIME out pointers.
    let ok = unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) }
        != 0;
    // SAFETY: the handle OpenProcess returned, closed once.
    unsafe { CloseHandle(handle) };
    if !ok {
        return Process::Alive(None);
    }
    // An exited process answers until its last handle closes: an exit time means gone.
    if exited.dwLowDateTime != 0 || exited.dwHighDateTime != 0 {
        return Process::Gone;
    }
    let start = (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime);
    Process::Alive(Some((start, 0)))
}

/// Removes `path` when it still holds `text`, so a file the app wrote for a
/// new helper since it was read stays.
pub fn remove_if_unchanged(path: &Path, text: &str) {
    if std::fs::read_to_string(path).is_ok_and(|now| now == text) {
        let _ = std::fs::remove_file(path);
    }
}
