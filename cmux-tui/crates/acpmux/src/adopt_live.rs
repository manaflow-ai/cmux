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

/// How session `id` is live outside acpmux, if it is. Processes under an
/// `acpmux` process (the daemon, its agent hosts and their harnesses) are
/// acpmux's own and never count.
pub fn live_use(id: &str, transcript: &Path, procs: &[Proc], now: SystemTime) -> Option<LiveUse> {
    let ours = acpmux_tree(procs);
    let named = procs.iter().find(|p| {
        !ours.contains(&p.pid)
            && p.command.split_whitespace().any(|t| t == id || t.ends_with(&format!("={id}")))
    });
    if let Some(p) = named {
        let command: String = p.command.chars().take(120).collect();
        return Some(LiveUse::Process { pid: p.pid, command });
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
