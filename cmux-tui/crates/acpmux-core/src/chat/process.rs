use serde::{Deserialize, Serialize};

/// Where a process is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessState {
    Running,
    Exited,
    Failed,
    Killed,
    /// It ended without anyone seeing how (its harness exited).
    Lost,
}

/// One background process, as `_acpmux/process/list` and
/// `_acpmux/process_update` carry it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Process {
    /// `<sessionId>/<harness task id>` (the tool call's id when the harness
    /// never named a task).
    pub id: String,
    pub session_id: String,
    /// The subagent whose tool call started it, if one did.
    pub subagent_session_id: Option<String>,
    pub tool_call_id: String,
    pub task_id: String,
    pub harness: String,
    pub command: String,
    /// What the call that started it says it does (Claude's Bash
    /// `description`); none from Codex.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub cwd: String,
    /// Unix ms.
    pub started_at: u64,
    pub ended_at: Option<u64>,
    pub state: ProcessState,
    /// Reported by Codex, not by Claude Code.
    pub exit_code: Option<i64>,
    pub signal: Option<String>,
    /// Why it stopped: `person` (`_acpmux/process/kill`), `agent`, or
    /// `harness_exit`.
    pub reason: Option<String>,
    /// The harness's own words on its end (Claude's reason or summary).
    pub detail: Option<String>,
    /// `background` (started there), `auto_backgrounded` (Claude Code moved
    /// it there) or `user_backgrounded` (the person did, Ctrl-B).
    pub origin: String,
    /// The length of its output file when it was listed; null while
    /// Claude Code has named no file.
    pub output_bytes: Option<u64>,
    /// The file Claude Code writes its output to (`output_file`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_file: Option<String>,
    /// The loopback server it runs, found in its output (`process_preview.rs`);
    /// only while it runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<ProcessPreview>,
    /// Its latest state is in a logged `process_update`.
    #[serde(skip)]
    pub logged: bool,
}

/// The local URL a running process serves, as its output printed it and a
/// loopback connect confirmed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessPreview {
    pub url: String,
    pub port: u16,
}

/// A session's processes, in the order they started.
#[derive(Debug, Default)]
pub struct ProcessTable {
    /// Read from the session's log (`Hub::process_table`).
    pub loaded: bool,
    /// The last log record the table holds.
    pub through: u64,
    pub processes: Vec<Process>,
    /// Stable slots in `processes`: entries never move, even when an update replaces one.
    pub by_id: std::collections::HashMap<String, usize>,
    /// First process with a tool-call ID (the historical Vec::position behavior).
    pub by_tool: std::collections::HashMap<String, usize>,
    /// Only live process slots, ascending by append order. Completed history can grow
    /// without making idle checks or lost-process propagation scan every old task.
    pub running: std::collections::BTreeSet<usize>,
    /// Processes a person asked to stop: their end is the person's.
    pub stopping: std::collections::HashSet<String>,
    /// Processes whose output a preview watch reads (`process_preview.rs`): one each.
    pub watching: std::collections::HashSet<String>,
}
