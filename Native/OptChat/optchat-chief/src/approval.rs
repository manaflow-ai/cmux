//! Permission requests of a turn another person started (README
//! "Remote-origin messages"). That turn's session runs with acpmux policy
//! `ask`; the host answers each request at once: the memory tools and the
//! Chief's own tools are allowed, every other local effect is refused. The
//! Chief never asks a person (Lawrence, 2026-10-20). Every refusal goes to
//! the trace.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::{Value, json};

/// Tools that only read (the OptChat memory, the versions): allowed without asking.
pub const MEMORY_TOOLS: [&str; 4] = [
    "mcp__optchat__zoom",
    "mcp__optchat__date",
    "mcp__optchat__version",
    "mcp__optchat__transcript",
];

/// The Chief's own tools: Chief talking to the person and to its
/// subagents, never a local effect of their own. `spawn` is safe in a gated turn because a child spawned there
/// takes the ask floor (`spawn_policy`); `tell` and `control` are checked
/// against their target by the brain (`Brain::internal_allowed`), and
/// `cloud_workspace` (a billed Cloud machine) runs only in the owner's turn.
pub const CHIEF_TOOLS: [&str; 12] = [
    "mcp__optchat__send",
    "mcp__optchat__reply",
    "mcp__optchat__react",
    "mcp__optchat__stop",
    "mcp__optchat__sleep",
    "mcp__optchat__spawn",
    "mcp__optchat__tell",
    "mcp__optchat__control",
    "mcp__optchat__profile",
    "mcp__optchat__remember",
    "mcp__optchat__automation",
    "mcp__optchat__cloud_workspace",
];

/// The tools a turn session runs without a permission request (its
/// project settings' `permissions.allow`): acpmux takes an allow only from
/// the person's app, so a request the host answered itself would wait
/// forever. In a turn another person started, `Brain::internal_allowed`
/// checks each call's input when the tool runs (`Orchestrator::turn_gate`).
pub fn turn_allowed_tools() -> Vec<&'static str> {
    MEMORY_TOOLS
        .iter()
        .chain(CHIEF_TOOLS.iter())
        .copied()
        .collect()
}

/// One permission request the host answers.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub session_id: String,
    pub permission_id: String,
    pub tool: String,
    pub request: Value,
    /// The child agent that asked (its name), None for the turn itself.
    pub child: Option<String>,
}

/// The tag `chief agents spawn` puts on a child that runs with policy `ask`
/// (the host's spawn floor): the host refuses its local effects.
pub const POLICY_TAG: &str = "optchat.policy";
pub const ASK: &str = "ask";

/// The harness's tool name of a permission request (Claude Code's
/// `_meta.claude.tool`), else its title.
pub fn tool_name(request: &Value) -> String {
    let call = request.get("toolCall");
    call.and_then(|c| {
        c.pointer("/_meta/claude/tool")
            .or_else(|| c.pointer("/_meta/claudeCode/toolName"))
            .or_else(|| c.get("title"))
    })
    .and_then(Value::as_str)
    .filter(|s| !s.is_empty())
    .unwrap_or("a tool")
    .to_owned()
}

/// Whether the request only reads the memory.
pub fn is_memory_tool(request: &Value) -> bool {
    MEMORY_TOOLS.contains(&tool_name(request).as_str())
}

/// The host's answer to a permission request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Allow,
    Deny,
}

impl Answer {
    pub fn as_str(self) -> &'static str {
        match self {
            Answer::Allow => "allow",
            Answer::Deny => "deny",
        }
    }
}

/// The option that answers `request`: allow once (never "always"), or
/// reject once. None: no such option.
pub fn option_for(request: &Value, answer: Answer) -> Option<String> {
    let options = request.get("options").and_then(Value::as_array)?;
    fn kind(o: &Value) -> &str {
        o.get("kind").and_then(Value::as_str).unwrap_or("")
    }
    let pick = match answer {
        Answer::Allow => options.iter().find(|o| kind(o) == "allow_once"),
        Answer::Deny => options
            .iter()
            .find(|o| kind(o) == "reject_once")
            .or_else(|| options.iter().find(|o| kind(o).starts_with("reject"))),
    }?;
    pick.get("optionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// What a request will do, in a few words: the command a shell call runs,
/// the file an edit writes, the subagent a `tell` reaches; never the raw
/// JSON of its input.
pub fn describe(tool: &str, input: Option<&Value>) -> String {
    let field = |key: &str| {
        input
            .and_then(|i| i.get(key))
            .and_then(|v| match v {
                Value::String(s) => Some(s.clone()),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .map(|s| one_line(&s, 120))
            .filter(|s| !s.is_empty())
    };
    let short = tool.rsplit("__").next().unwrap_or(tool);
    match tool {
        "Bash" => field("command").map_or("run a shell command".to_owned(), |c| {
            format!("run {}", code_span(&c))
        }),
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => field("file_path")
            .or_else(|| field("notebook_path"))
            .map_or("edit a file".to_owned(), |f| format!("edit {f}")),
        "Read" => field("file_path").map_or("read a file".to_owned(), |f| format!("read {f}")),
        "WebFetch" => field("url").map_or("fetch a web page".to_owned(), |u| format!("fetch {u}")),
        "mcp__optchat__tell" => match (field("id"), field("message")) {
            (Some(id), Some(m)) => {
                format!("tell subagent {id}: \u{201c}{}\u{201d}", one_line(&m, 80))
            }
            (Some(id), None) => format!("tell subagent {id}"),
            _ => "tell a subagent".to_owned(),
        },
        "mcp__optchat__control" => match (field("action"), field("id")) {
            (Some(a), Some(id)) => format!("{a} subagent {id}"),
            (Some(a), None) => format!("change subagents ({a})"),
            _ => "control a subagent".to_owned(),
        },
        _ if tool.starts_with("mcp__") => {
            let server = tool
                .trim_start_matches("mcp__")
                .split("__")
                .next()
                .unwrap_or("");
            format!("use {short} ({server})")
        }
        _ => format!("use {tool}"),
    }
}

/// `text` on one line, at most `max` characters: a line break shows as
/// `⏎` (two commands never read as one), and a cut ends with "… (cut)" so
/// the reader knows to look at the arguments for the rest.
fn one_line(text: &str, max: usize) -> String {
    let line = text
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" \u{23ce} ");
    if line.chars().count() <= max {
        return line;
    }
    let cut: String = line.chars().take(max.saturating_sub(1)).collect();
    format!("{}\u{2026} (cut)", cut.trim_end())
}

/// The longest run of backticks in `text`.
fn longest_backticks(text: &str) -> usize {
    text.split(|c| c != '`').map(str::len).max().unwrap_or(0)
}

/// `text` as a Markdown code span whose fence no backtick in it can close
/// (CommonMark: a longer fence, padded when the text touches a backtick).
fn code_span(text: &str) -> String {
    let fence = "`".repeat(longest_backticks(text) + 1);
    if text.contains('`') {
        format!("{fence} {text} {fence}")
    } else {
        format!("{fence}{text}{fence}")
    }
}

/// A request's identity within one turn: the tool and its input. A
/// repeat of a refused request counts toward stopping the turn.
pub fn signature(pending: &Pending) -> String {
    signature_of(&pending.tool, pending.request.pointer("/toolCall/rawInput"))
}

/// [`signature`] of a call of `tool` with `input` (a permission request's
/// `rawInput`, or the arguments a Chief tool runs with).
pub fn signature_of(tool: &str, input: Option<&Value>) -> String {
    let input = input.map(Value::to_string).unwrap_or_default();
    format!("{tool}\u{0}{input}")
}

/// The longest a permission request of the Chief's turn session or of one
/// of its children may wait with no answer before the host denies it
/// (`Brain::deny_overdue_permissions_at`): a request nobody sees never holds
/// a turn forever. A subagent's prompt that the person's app shows with an
/// approval button waits for the person instead.
pub const PERMISSION_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

/// Appends one `approval` event to the trace in `dir`
/// (`traces/YYYY-MM-DD.jsonl`, the monitoring trace's layout:
/// `{"ts", "ev", ...}`, 0600). A failed write is reported, never fatal.
pub fn record(dir: &Path, fields: Value) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let now = chrono::Local::now();
    let mut line = json!({"ts": now.timestamp_millis(), "ev": "approval"});
    if let (Some(line), Value::Object(fields)) = (line.as_object_mut(), fields) {
        line.extend(fields);
    }
    let path = dir.join(format!("{}.jsonl", now.format("%Y-%m-%d")));
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(format!("{line}\n").as_bytes())
}
