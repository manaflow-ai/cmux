//! Whether a harness session is live outside acpmux: a process whose command
//! line names it (`claude --resume <id>`, `codex resume <id>`,
//! `sr claude proxy --resume <id>`), or a transcript written in the last
//! minutes (a harness started without the id in its arguments). Adopting
//! such a chat runs two harnesses on one conversation, which forks it.

use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, SystemTime};

/// A transcript written this recently belongs to a running harness.
pub const RECENT_WRITE: Duration = Duration::from_secs(120);

/// One row of the process table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub command: String,
}

/// How a session is live elsewhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveUse {
    /// A process outside acpmux whose command line names the session.
    Process { pid: u32, command: String },
    /// Its transcript was written `ago` ago.
    RecentWrite { ago: Duration },
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
            Self::RecentWrite { ago } => {
                format!("was written {}s ago by a harness outside cmux", ago.as_secs())
            }
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
            Self::RecentWrite { ago } => {
                json!({"signal": "recentWrite", "agoSeconds": ago.as_secs(), "canFork": can_fork})
            }
        }
    }
}

/// The process table (`ps`); empty when it cannot be read.
pub fn processes() -> Vec<Proc> {
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
/// database), where a recent write says nothing about this session.
pub fn named_use(id: &str, procs: &[Proc]) -> Option<LiveUse> {
    let ours = acpmux_tree(procs);
    let p = procs.iter().find(|p| {
        !ours.contains(&p.pid)
            && p.command.split_whitespace().any(|t| t == id || t.ends_with(&format!("={id}")))
    })?;
    let command: String = p.command.chars().take(120).collect();
    Some(LiveUse::Process { pid: p.pid, command })
}

/// How session `id` is live outside acpmux, if it is. Processes under an
/// `acpmux` process (the daemon, its agent hosts and their harnesses) are
/// acpmux's own and never count.
/// `cwd`: the conversation's recorded folder; a recent write counts as live only while a harness
/// runs in it (or, when the folders cannot be read, while any harness runs).
pub fn live_use(
    id: &str,
    transcript: &Path,
    cwd: Option<&Path>,
    procs: &[Proc],
    now: SystemTime,
) -> Option<LiveUse> {
    if let Some(named) = named_use(id, procs) {
        return Some(named);
    }
    let ours = acpmux_tree(procs);
    // A recent write means live only while a harness process (outside acpmux) runs at all: a
    // transcript touched minutes ago by a process that has ended is not open anywhere (the
    // freshly written chat showed "still open in another process", Lawrence P0 2026-10-11).
    let harnesses: Vec<u32> = procs
        .iter()
        .filter(|p| {
            !ours.contains(&p.pid) && {
                let command = p.command.to_ascii_lowercase();
                command.split_whitespace().take(2).any(|t| {
                    Path::new(t)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.contains("claude") || n.contains("codex"))
                })
            }
        })
        .map(|p| p.pid)
        .collect();
    // Only a harness in the conversation's folder can hold it open (another chat's Claude Code
    // does not). Folders that cannot be read count every harness (fail closed).
    let harness_runs = match cwd {
        Some(cwd) if !harnesses.is_empty() => match process_cwds(&harnesses) {
            Some(cwds) => cwds.values().any(|dir| same_dir(dir, cwd)),
            None => true,
        },
        _ => !harnesses.is_empty(),
    };
    // An empty process list (`ps` failed) keeps the recent-write rule: fail closed.
    if !harness_runs && !procs.is_empty() {
        return None;
    }
    let written = std::fs::metadata(transcript).and_then(|m| m.modified()).ok()?;
    let ago = now.duration_since(written).unwrap_or_default();
    (ago < RECENT_WRITE).then_some(LiveUse::RecentWrite { ago })
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

/// The working directory of each of `pids` (`lsof -a -d cwd -Fn -p ...`); None when lsof fails.
fn process_cwds(pids: &[u32]) -> Option<HashMap<u32, std::path::PathBuf>> {
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let out = std::process::Command::new("lsof")
        .args(["-b", "-w", "-n", "-a", "-d", "cwd", "-Fn", "-p", &list])
        .output()
        .ok()?;
    let mut cwds = HashMap::new();
    let mut pid = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(p) = line.strip_prefix('p') {
            pid = p.parse::<u32>().ok();
        } else if let (Some(n), Some(p)) = (line.strip_prefix('n'), pid) {
            cwds.insert(p, std::path::PathBuf::from(n));
        }
    }
    (!cwds.is_empty()).then_some(cwds)
}

fn same_dir(a: &Path, b: &Path) -> bool {
    a == b
        || std::fs::canonicalize(a)
            .ok()
            .zip(std::fs::canonicalize(b).ok())
            .is_some_and(|(x, y)| x == y)
}
