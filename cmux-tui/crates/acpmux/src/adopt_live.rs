//! Whether a harness session is open outside acpmux, by the holder the
//! harness itself records, never by guessing from what else runs:
//! - Codex: its thread writer lock (`<CODEX_HOME>/thread-writer-locks/<id>.lock`,
//!   an exclusive `flock` a writer holds while it runs). The kernel releases it
//!   when the writer exits, so a `codex exec` that finished holds nothing,
//!   though its lock file stays on disk.
//! - Claude Code: its session registry (`<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`,
//!   pid, session id, start time). Claude Code removes the entry when it quits;
//!   a crash leaves it, so an entry counts only while its pid runs and that
//!   process started before the entry (a reused pid is another process).
//! - OpenCode records no holder; a process whose command line names the
//!   session is the only signal (`named_use`, cx-t2sqm.2).
//!
//! A transcript written moments ago is no holder: the run that wrote it may
//! have ended (hq#2569 item 7: every finished CLI session opened behind "still
//! open in another process").
//!
//! Adopting a chat that is open elsewhere runs two harnesses on one
//! conversation, which forks it.

use crate::no_panic::JsonExt;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;

/// One row of the process table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub command: String,
}

/// How a session is open elsewhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveUse {
    /// A process outside acpmux whose command line names the session (OpenCode).
    Process { pid: u32, command: String },
    /// A running Claude Code registered the session (`sessions/<pid>.json`).
    Registered { pid: u32 },
    /// A running Codex holds the thread's writer lock.
    WriterLock,
}

impl LiveUse {
    /// The refusal's message: what holds the chat, and the ways on.
    pub fn refusal(&self, family: &str, id: &str) -> String {
        let ways = if family == "claude" {
            "close it there, fork it, or open it anyway"
        } else {
            "close it there or open it anyway"
        };
        let held = match self {
            Self::Process { pid, command } => {
                format!("is open in another process (pid {pid}: {command})")
            }
            Self::Registered { pid } => format!("is open in another process (pid {pid})"),
            Self::WriterLock => "is open in another process (its writer lock is held)".to_owned(),
        };
        format!("{family} session {id} {held}; {ways}")
    }

    /// `details` of the refusal (`adopt.live`).
    pub fn details(&self, family: &str) -> Value {
        let can_fork = family == "claude";
        match self {
            Self::Process { pid, command } => {
                json!({"signal": "process", "pid": pid, "command": command, "canFork": can_fork})
            }
            Self::Registered { pid } => {
                json!({"signal": "registry", "pid": pid, "canFork": can_fork})
            }
            Self::WriterLock => json!({"signal": "writerLock", "canFork": can_fork}),
        }
    }
}

/// The holder of `family` session `id` in the harness store at `store`
/// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), if one still runs.
pub fn holder(family: &str, id: &str, store: &Path) -> Option<LiveUse> {
    match family {
        "claude" => claude_holder(store, id),
        "codex" => codex_holder(store, id),
        _ => None,
    }
}

/// A running Claude Code that registered session `id` in `<config>/sessions`.
fn claude_holder(config: &Path, id: &str) -> Option<LiveUse> {
    std::fs::read_dir(config.join("sessions")).ok()?.flatten().find_map(|entry| {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            return None;
        }
        let record: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
        if record.field("sessionId").as_str() != Some(id) {
            return None;
        }
        let pid = u32::try_from(record.field("pid").as_u64()?).ok()?;
        registered_runs(pid, record.field("startedAt").as_u64())
            .then_some(LiveUse::Registered { pid })
    })
}

/// Whether the process a registry entry names still runs: `pid` exists and,
/// where its start time can be read, started no later than the entry's
/// `startedAt` (milliseconds since the epoch), so a pid reused by a later
/// process does not stand in for the ended one.
fn registered_runs(pid: u32, started_at_ms: Option<u64>) -> bool {
    /// Clock granularity between the process start and the time it records.
    const SLACK_MS: u64 = 1_000;
    if !pid_exists(pid) {
        return false;
    }
    match (started_at_ms, pid_start_ms(pid)) {
        (Some(recorded), Some(started)) => started <= recorded.saturating_add(SLACK_MS),
        _ => true,
    }
}

#[cfg(unix)]
fn pid_exists(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 1 {
        return false;
    }
    // SAFETY: signal 0 only checks that the pid exists; nothing is sent.
    let sent = unsafe { libc::kill(pid, 0) } == 0;
    sent || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_exists(_pid: u32) -> bool {
    false
}

/// When `pid` started, in milliseconds since the epoch (macOS).
#[cfg(target_os = "macos")]
fn pid_start_ms(pid: u32) -> Option<u64> {
    let (sec, usec) = crate::cua_v2::start_time(libc::pid_t::try_from(pid).ok()?)?;
    Some(sec.saturating_mul(1000).saturating_add(usec / 1000))
}

/// Elsewhere the registry's pid decides alone.
#[cfg(not(target_os = "macos"))]
fn pid_start_ms(_pid: u32) -> Option<u64> {
    None
}

/// A running Codex that holds thread `id`'s writer lock. Probed as Codex
/// probes it before it publishes a thread: under the home's coordination lock
/// (every writer takes it before its thread lock), a non-blocking exclusive
/// `flock` on the thread lock, released at once. No lock file: no writer.
#[cfg(unix)]
fn codex_holder(home: &Path, id: &str) -> Option<LiveUse> {
    use std::os::fd::AsRawFd;
    let dir = home.join("thread-writer-locks");
    let thread = std::fs::File::open(dir.join(format!("{id}.lock"))).ok()?;
    let coordination = std::fs::File::open(dir.join(".coordination.lock")).ok();
    if let Some(file) = &coordination {
        // A writer holds it only while it opens its thread lock; wait briefly, never forever.
        // Still held after that: a writer is taking the thread lock now, so the chat is busy.
        let taken = (0..50).any(|attempt| {
            if attempt > 0 {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            // SAFETY: flock on an open descriptor this function owns.
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
        });
        if !taken {
            return Some(LiveUse::WriterLock);
        }
    }
    // SAFETY: flock on the thread lock descriptor this function opened.
    let held = unsafe { libc::flock(thread.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK);
    // Closing both descriptors (end of scope) releases what was taken.
    drop(thread);
    drop(coordination);
    held.then_some(LiveUse::WriterLock)
}

#[cfg(not(unix))]
fn codex_holder(_home: &Path, _id: &str) -> Option<LiveUse> {
    None
}

/// The process table (`ps`); empty when it cannot be read.
pub fn processes() -> Vec<Proc> {
    crate::daemon::hang_watch::will_block();
    std::process::Command::new("ps")
        .args(["-axww", "-o", "pid=,ppid=,command="])
        .output()
        .map(|out| parse_ps(&String::from_utf8_lossy(&out.stdout)))
        .unwrap_or_default()
}

/// Rows of `ps -o pid=,ppid=,command=`.
pub fn parse_ps(text: &str) -> Vec<Proc> {
    text.lines()
        .filter_map(|line| {
            let mut rest = line.trim_start();
            let mut field = || {
                let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
                let (value, tail) = rest.split_at(end);
                rest = tail.trim_start();
                value.parse::<u32>().ok()
            };
            let (pid, ppid) = (field()?, field()?);
            Some(Proc { pid, ppid, command: rest.to_owned() })
        })
        .collect()
}

/// A process outside acpmux that names session `id` on its command line.
/// The only liveness signal for a store every session writes (OpenCode's
/// database), which records no holder. Processes under an `acpmux` process
/// (the daemon, its agent hosts and their harnesses) are acpmux's own and
/// never count.
pub fn named_use(id: &str, procs: &[Proc]) -> Option<LiveUse> {
    let ours = acpmux_tree(procs);
    let p = procs.iter().find(|p| {
        !ours.contains(&p.pid)
            && p.command.split_whitespace().any(|t| t == id || t.ends_with(&format!("={id}")))
    })?;
    let command: String = p.command.chars().take(120).collect();
    Some(LiveUse::Process { pid: p.pid, command })
}

/// Every pid in the subtree of a process whose executable is `acpmux`.
fn acpmux_tree(procs: &[Proc]) -> HashSet<u32> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for p in procs {
        children.entry(p.ppid).or_default().push(p.pid);
    }
    let is_acpmux = |p: &&Proc| {
        p.command
            .split_whitespace()
            .next()
            .and_then(|exe| Path::new(exe).file_name())
            .is_some_and(|name| name == "acpmux")
    };
    let mut stack: Vec<u32> = procs.iter().filter(is_acpmux).map(|p| p.pid).collect();
    let mut tree = HashSet::new();
    while let Some(pid) = stack.pop() {
        if tree.insert(pid) {
            stack.extend(children.get(&pid).into_iter().flatten());
        }
    }
    tree
}
