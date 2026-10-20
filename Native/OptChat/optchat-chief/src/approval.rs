//! Approvals of a remote-origin turn's local effects (README "Remote-origin
//! messages"). The turn session runs with acpmux policy `ask`; each
//! permission request it raises is either one of the memory tools (answered
//! at once: reading the memory has no local effect) or shown in the Chief
//! chat and answered by the next `allow` or `deny` a person of the
//! conversation sends. Every answer goes to the trace with the approving
//! device.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::{Value, json};

/// Tools that only read (the OptChat memory, the versions): allowed without asking.
pub const MEMORY_TOOLS: [&str; 3] = [
    "mcp__optchat__zoom",
    "mcp__optchat__date",
    "mcp__optchat__version",
];

/// The Chief's own tools: Chief talking to the person and to its
/// subagents, never a local effect of their own. They never wait for an
/// approval. `spawn` is safe in a gated turn because a child spawned there
/// takes the ask floor (`spawn_policy`); `tell` and `control` are checked
/// against their target by the brain (`Brain::internal_allowed`).
pub const CHIEF_TOOLS: [&str; 9] = [
    "mcp__optchat__send",
    "mcp__optchat__reply",
    "mcp__optchat__react",
    "mcp__optchat__stop",
    "mcp__optchat__sleep",
    "mcp__optchat__spawn",
    "mcp__optchat__tell",
    "mcp__optchat__control",
    "mcp__optchat__profile",
];

/// Why a turn asks before its local effects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Why {
    /// Someone other than the Chief's owner wrote in the turn (always on).
    Participant,
    /// A paired device started it, and `remote.ask` is on; the device's name.
    Device(String),
    /// The turn reads the Home workspace, and `home.ask` is on.
    Home,
}

/// One permission request waiting for a person.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub session_id: String,
    pub permission_id: String,
    pub tool: String,
    pub request: Value,
    /// The child agent that asked (its name), None for the turn itself.
    pub child: Option<String>,
    /// The side conversation whose turn asked (None: the main one, which
    /// also takes every child's request). Only a message in this
    /// conversation answers it.
    pub conversation: Option<String>,
    /// Why the turn asks (None: a child's request).
    pub why: Option<Why>,
}

/// The tag `chief agents spawn` puts on a child that runs with policy `ask`
/// (the host's spawn floor): its approvals go to the Chief chat.
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

/// A person's answer in a chat message: `allow` or `deny` (any case, alone).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Allow,
    Deny,
}

impl Answer {
    pub fn parse(text: &str) -> Option<Answer> {
        match text.trim().to_ascii_lowercase().as_str() {
            "allow" => Some(Answer::Allow),
            "deny" => Some(Answer::Deny),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Answer::Allow => "allow",
            Answer::Deny => "deny",
        }
    }
}

/// The option that answers `request`: allow once (never "always": each
/// effect is approved on its own), or reject once. None: no such option.
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

/// Why the card asks, one muted line ("Started from your iPhone: local
/// actions need your OK").
pub fn reason(pending: &Pending) -> String {
    match (&pending.child, &pending.why) {
        (Some(_), _) => {
            "It started in a turn that needs approvals, so its local actions need your OK."
                .to_owned()
        }
        (None, Some(Why::Device(device))) => format!(
            "Started from {device}: Ask before acting on requests from other devices is on."
        ),
        (None, Some(Why::Participant)) => {
            "Someone else in this conversation asked: local actions need your OK.".to_owned()
        }
        (None, Some(Why::Home)) => {
            "This turn read your Home screens: Ask before acting on what Home shows is on."
                .to_owned()
        }
        (None, None) => "This turn needs your OK for local actions.".to_owned(),
    }
}

/// The card's bold line: the action and its target, as a question.
pub fn headline(pending: &Pending) -> String {
    let what = describe(&pending.tool, pending.request.pointer("/toolCall/rawInput"));
    match &pending.child {
        Some(child) => format!("Allow subagent {child} to {what}?"),
        None => format!("Allow Chief to {what}?"),
    }
}

/// The request's arguments, pretty-printed and cut to `max` bytes (the
/// card's monospace block; never in a chat bubble).
pub fn arguments(pending: &Pending, max: usize) -> Option<String> {
    let raw = pending.request.pointer("/toolCall/rawInput")?;
    if raw.as_object().is_some_and(serde_json::Map::is_empty) || raw.is_null() {
        return None;
    }
    let text = serde_json::to_string_pretty(raw).ok()?;
    if text.len() <= max {
        return Some(text);
    }
    let mut cut = max.saturating_sub(4);
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    Some(format!("{}\n\u{2026}", &text[..cut]))
}

/// The text form of the card: two lines and how to answer (a client that
/// draws no question card, the CLI, and the fallback when the owner
/// refuses the question part). No JSON.
pub fn question(pending: &Pending) -> String {
    // The arguments too, in a fence no backtick in them can close: the
    // headline's command may be cut.
    let args = arguments(pending, 1_500).map_or(String::new(), |a| {
        let fence = "`".repeat(longest_backticks(&a).max(2) + 1);
        format!("\n{fence}\n{a}\n{fence}")
    });
    format!(
        "{}\n{}{args}\nReply allow or deny.",
        headline(pending),
        reason(pending)
    )
}

/// The option ids of the card's question part.
pub const ALLOW_OPTION: &str = "allow";
pub const DENY_OPTION: &str = "deny";

/// The card: one `question` part (harness `chief`, the permission it
/// settles): the headline as its prompt, the reason as Allow's detail and
/// the arguments as Allow's monospace preview, then Allow once and Deny.
/// No "always": each effect is approved on its own (`option_for`).
pub fn card(pending: &Pending) -> cmux_conversation::Part {
    use cmux_conversation::{
        PreviewFormat, Question, QuestionHarness, QuestionItem, QuestionOption, QuestionPreview,
        QuestionState,
    };
    let short = |text: String, max: usize| -> String { text.chars().take(max).collect() };
    cmux_conversation::Part::Question(Question {
        harness: QuestionHarness::Chief,
        session: short(pending.session_id.clone(), 200),
        permission: Some(short(pending.permission_id.clone(), 200)),
        agent: pending.child.clone().map(|c| short(c, 200)),
        items: vec![QuestionItem {
            id: "approval".to_owned(),
            header: Some("Approval".to_owned()),
            prompt: short(headline(pending), 400),
            options: vec![
                QuestionOption {
                    id: ALLOW_OPTION.to_owned(),
                    label: "Allow once".to_owned(),
                    detail: Some(short(reason(pending), 400)),
                    preview: arguments(pending, 6_000).map(|text| QuestionPreview {
                        text,
                        format: PreviewFormat::Monospace,
                    }),
                },
                QuestionOption {
                    id: DENY_OPTION.to_owned(),
                    label: "Deny".to_owned(),
                    detail: None,
                    preview: None,
                },
            ],
            multi_select: false,
            allows_other: false,
        }],
        state: QuestionState::Pending,
    })
}

/// The answer a card's selection gives.
pub fn card_answer(answer: &cmux_conversation::QuestionAnswer) -> Option<Answer> {
    let chosen = answer.selections.get("approval")?.option_ids.first()?;
    match chosen.as_str() {
        ALLOW_OPTION => Some(Answer::Allow),
        DENY_OPTION => Some(Answer::Deny),
        _ => None,
    }
}

/// A request's identity within one turn: the tool and its input. A request
/// denied once is denied again at once when the model repeats it.
pub fn signature(pending: &Pending) -> String {
    let input = pending
        .request
        .pointer("/toolCall/rawInput")
        .map(Value::to_string)
        .unwrap_or_default();
    format!("{}\u{0}{input}", pending.tool)
}

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
