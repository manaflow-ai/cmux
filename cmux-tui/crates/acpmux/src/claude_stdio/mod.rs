//! Claude Code over its own stdio protocol, presented to the hub as an ACP
//! agent.
//!
//! `claude -p --input-format stream-json --output-format stream-json` keeps
//! one process alive for many turns. This module owns that process and
//! translates in both directions:
//!
//!   hub -> claude   ACP requests become user messages and control_requests
//!   claude -> hub   stream-json becomes session/update notifications,
//!                   session/request_permission requests, and responses to
//!                   the pending ACP request (session/prompt, initialize, ...)
//!
//! Nothing outside this file knows the Claude wire format.

use crate::config::HarnessProfile;
use crate::rpc::{Id, Message, RpcError, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use tokio::sync::Mutex;

/// The session/update variants and ids this translator emits are plain ACP.
pub const AGENT_NAME: &str = "claude-stdio";

/// Claude mode ids, offered as ACP session modes.
/// Claude's own modes. Its permission modes (acceptEdits, bypassPermissions)
/// are not offered: acpmux's policy answers permission prompts itself, so
/// `perms approve-edits` and `perms approve-all` cover them for every
/// harness, and bypassPermissions would also need the process launched with
/// --dangerously-skip-permissions. Plan and auto change what Claude does,
/// so they stay.
const MODES: [(&str, &str); 3] = [("default", "Normal"), ("plan", "Plan"), ("auto", "Auto")];

/// Model aliases Claude Code accepts on `set_model` and `--model`. Aliases
/// track Claude Code's own defaults; the `[1m]` suffix asks for the 1M
/// context window, and the full ids pin a model regardless of alias drift.
const MODELS: [(&str, &str); 12] = [
    ("default", "Default (Claude Code's choice)"),
    ("claude-fable-5-1", "Fable 5.1"),
    ("claude-fable-5-1[1m]", "Fable 5.1 · 1M context"),
    ("opus", "Opus"),
    ("opus[1m]", "Opus · 1M context"),
    ("claude-opus-5", "Opus 5"),
    ("opusplan", "Opus plan · Sonnet execute"),
    ("sonnet", "Sonnet"),
    ("sonnet[1m]", "Sonnet · 1M context"),
    ("claude-sonnet-5", "Sonnet 5"),
    ("haiku", "Haiku"),
    ("claude-haiku-4-5-20251001", "Haiku 4.5"),
];

/// Effort levels Claude Code accepts for `--effort` and the live
/// `apply_flag_settings` control request. "default" leaves the model's own.
const EFFORTS: [(&str, &str); 6] = [
    ("default", "Default (model's choice)"),
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Xhigh"),
    ("max", "Max"),
];

/// The model aliases offered in pickers.
pub fn models() -> &'static [(&'static str, &'static str)] {
    &MODELS
}

mod inbound;
mod outbound;
#[cfg(test)]
mod tests;

/// What the hub's request becomes: lines for claude's stdin, or an
/// immediate ACP reply when claude need not be asked.
pub enum Outbound {
    Lines(Vec<Value>),
    Reply(Message),
}

#[derive(Debug, Clone)]
pub struct SpawnPlan {
    pub program: String,
    pub args: Vec<String>,
}

/// Build the claude command line. `resume` reopens an existing Claude
/// session (or forks it); `fresh_id` pins the id of a brand-new one so acpmux
/// knows it before the first turn.
/// `mode` is pinned with `--permission-mode` so the user's Claude settings
/// (often `auto`) cannot silently bypass acpmux's permission policy; the
/// mode chip then always tells the truth. `model` is the session's chosen
/// model, passed as `--model` so forks and respawns keep it.
pub fn spawn_plan(
    profile: &HarnessProfile,
    resume: Option<&str>,
    fork: bool,
    fresh_id: Option<&str>,
    effort: Option<&str>,
    mode: &str,
    model: Option<&str>,
) -> SpawnPlan {
    let program = profile.argv.first().cloned().unwrap_or_else(|| "claude".into());
    // Everything after the program in argv comes first: a wrapper such as
    // `sr claude proxy` needs its own words before Claude's flags, and a
    // plain profile can still pin --model, --settings, --mcp-config, ...
    let mut args: Vec<String> = profile.argv.iter().skip(1).cloned().collect();
    args.extend([
        "-p".into(),
        "--input-format".into(),
        "stream-json".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        "--include-partial-messages".into(),
        "--permission-prompt-tool".into(),
        "stdio".into(),
    ]);
    if let Some(sid) = resume {
        args.push("--resume".into());
        args.push(sid.into());
        if fork {
            args.push("--fork-session".into());
        }
    } else if let Some(id) = fresh_id {
        args.push("--session-id".into());
        args.push(id.into());
    }
    if let Some(e) = effort.filter(|e| *e != "default") {
        args.push("--effort".into());
        args.push(e.into());
    }
    // A later --model wins over one the profile pins in its argv.
    if let Some(m) = model.filter(|m| !m.is_empty() && *m != "default") {
        args.push("--model".into());
        args.push(m.into());
    }
    if !profile.argv.iter().any(|a| a == "--permission-mode") && !mode.is_empty() {
        args.push("--permission-mode".into());
        args.push(mode.into());
    }
    SpawnPlan { program, args }
}

/// Per-process translation state.
pub struct Translator {
    /// ACP request id -> what we are waiting on from claude.
    pending: Mutex<HashMap<String, Pending>>,
    /// claude control request_id -> ACP request id we issued to the hub.
    control_out: Mutex<HashMap<String, Id>>,
    next_control: AtomicI64,
    pub session_id: Mutex<Option<String>>,
    pub acp_session_id: String,
    mode: Mutex<String>,
    model: Mutex<String>,
    effort: Mutex<String>,
    in_turn: AtomicBool,
    /// Text streamed so far in the current turn, to build the prompt result.
    pub cancelled: AtomicBool,
    pub slash_commands: Mutex<Vec<Value>>,
    /// Lines for claude's stdin produced while reading its stdout (answers
    /// to control requests acpmux declines). The reader drains them.
    stdin_replies: Mutex<Vec<Value>>,
}

#[derive(Debug, Clone)]
enum Pending {
    Initialize,
    NewOrLoad,
    Prompt,
    /// A setting change, applied to the cached value once claude accepts it.
    Control(Setting, String),
}

#[derive(Debug, Clone, Copy)]
enum Setting {
    Mode,
    Model,
    Effort,
}

impl Translator {
    pub fn new(acp_session_id: String, mode: &str, model: &str, effort: &str) -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(HashMap::new()),
            control_out: Mutex::new(HashMap::new()),
            next_control: AtomicI64::new(1),
            session_id: Mutex::new(None),
            acp_session_id,
            mode: Mutex::new(mode.to_owned()),
            model: Mutex::new(model.to_owned()),
            effort: Mutex::new(effort.to_owned()),
            in_turn: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            slash_commands: Mutex::new(Vec::new()),
            stdin_replies: Mutex::new(Vec::new()),
        })
    }

    /// Take the lines `inbound` queued for claude's stdin.
    /// Error answers for every ACP request still waiting on Claude, which
    /// are dropped: used when Claude's answer cannot be carried (a line over
    /// the agent host's frame limit), so no turn waits forever.
    pub async fn fail_pending(&self, message: &str) -> Vec<Message> {
        self.pending
            .lock()
            .await
            .drain()
            .map(|(id, _)| {
                let id: Id = serde_json::from_str(&id).unwrap_or(Value::String(id));
                Message::err(id, RpcError::internal(message))
            })
            .collect()
    }

    pub async fn take_stdin_replies(&self) -> Vec<Value> {
        std::mem::take(&mut *self.stdin_replies.lock().await)
    }

    pub async fn modes_value(&self) -> Value {
        json!({
            "currentModeId": *self.mode.lock().await,
            "availableModes": MODES.iter().map(|(id, name)| json!({"id": id, "name": name})).collect::<Vec<_>>(),
        })
    }

    pub async fn config_options_value(&self) -> Value {
        json!([
            {"id": "model", "name": "Model", "type": "select", "category": "model", "currentValue": *self.model.lock().await,
             "options": MODELS.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
            {"id": "mode", "name": "Permission mode", "type": "select", "category": "mode", "currentValue": *self.mode.lock().await,
             "options": MODES.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
            {"id": "effort", "name": "Effort", "type": "select", "category": "thought_level", "currentValue": *self.effort.lock().await,
             "options": EFFORTS.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
        ])
    }
}

fn tool_kind(name: &str) -> &'static str {
    match name {
        "Read" | "Glob" | "Grep" | "NotebookRead" => "read",
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "edit",
        "Bash" | "BashOutput" | "KillShell" => "execute",
        "WebFetch" | "WebSearch" => "fetch",
        "Task" | "Agent" => "think",
        "AskUserQuestion" | "ExitPlanMode" => "other",
        _ => "other",
    }
}

fn tool_title(name: &str, input: &Value) -> String {
    let s = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_owned);
    match name {
        "Bash" => s("command")
            .map(|c| c.lines().next().unwrap_or("").chars().take(120).collect())
            .unwrap_or_else(|| "Bash".into()),
        "Read" | "Write" | "Edit" | "MultiEdit" => format!(
            "{name} {}",
            s("file_path")
                .map(|p| Path::new(&p)
                    .file_name()
                    .map(|f| f.to_string_lossy().into_owned())
                    .unwrap_or(p))
                .unwrap_or_default()
        ),
        "Glob" | "Grep" => format!("{name} {}", s("pattern").unwrap_or_default()),
        "WebFetch" => format!("Fetch {}", s("url").unwrap_or_default()),
        "WebSearch" => format!("Search {}", s("query").unwrap_or_default()),
        "Task" | "Agent" => format!("Agent: {}", s("description").unwrap_or_default()),
        "AskUserQuestion" => input
            .pointer("/questions/0/question")
            .and_then(Value::as_str)
            .map(|q| format!("Question: {q}"))
            .unwrap_or_else(|| "Question".into()),
        "ExitPlanMode" => "Approve plan".into(),
        _ => name.to_owned(),
    }
}
