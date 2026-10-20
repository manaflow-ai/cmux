//! Approvals of a remote-origin turn's local effects (README "Remote-origin
//! messages"). The turn session runs with acpmux policy `ask`; each
//! permission request it raises is either one of the memory tools (answered
//! at once: reading the memory has no local effect) or shown in the Chief
//! chat as a card (Allow / Deny) and answered there, or by the next `allow`
//! or `deny` a person of the conversation sends. Every answer goes to the trace with the approving
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

/// Why a turn asks before each local effect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AskReason {
    /// A paired device's message started it (`remote.autoApprove` off).
    Remote,
    /// Another participant's message started it.
    Participant,
    /// It reads the ambient text of the Home terminals.
    Ambient,
    /// Not known here.
    #[default]
    Unknown,
}

impl AskReason {
    fn text(self) -> &'static str {
        match self {
            AskReason::Remote => "this turn started from a paired device",
            AskReason::Participant => "another participant's message started this turn",
            AskReason::Ambient => "this turn reads your Home terminals' text",
            AskReason::Unknown => "this turn needs approval for local effects",
        }
    }
}

/// The Chief chat's question for one request: what the card's prompt says.
/// The input preview is cut so the whole prompt fits a question part
/// (`MAX_QUESTION_TEXT_BYTES`).
pub fn question(pending: &Pending, reason: AskReason) -> String {
    let head = match &pending.child {
        None => format!(
            "Approval needed: {}, so every local effect waits for you. {} wants to run:",
            reason.text(),
            pending.tool
        ),
        Some(child) => format!(
            "Approval needed: subagent {child} started from a turn that needs approvals, so its local effects wait for you too. {} wants to run:",
            pending.tool
        ),
    };
    let tail = CARD_TAIL;
    let raw = pending
        .request
        .pointer("/toolCall/rawInput")
        .map(Value::to_string)
        .unwrap_or_default();
    // One byte for the newline before the input, three for an ellipsis.
    let budget =
        cmux_conversation::MAX_QUESTION_TEXT_BYTES.saturating_sub(head.len() + tail.len() + 4);
    let input = if raw.is_empty() {
        String::new()
    } else if raw.len() <= budget {
        format!("\n{raw}")
    } else {
        let mut cut = budget;
        while !raw.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("\n{}…", &raw[..cut])
    };
    format!("{head}{input}{tail}")
}

/// The card's prompt as a plain chat message, for an owner that refuses the
/// card: chat can deny, and only the cmux app can allow.
pub fn question_text(prompt: &str) -> String {
    prompt.replace(CARD_TAIL, "\nReply deny, or allow it in the cmux app.")
}

/// The end of a card's prompt.
const CARD_TAIL: &str = "\nAllow or deny it here, or reply deny.";

/// The card item's id and its two options' ids.
pub const CARD_ITEM: &str = "approval";
pub const CARD_ALLOW: &str = "allow";
pub const CARD_DENY: &str = "deny";

/// The approval as a question card (plans/cmux-next/agent-questions.md
/// §5): the app answers the permission itself with the person's proof and
/// then the card; a chat `deny` still answers it too.
pub fn card(pending: &Pending, reason: AskReason) -> cmux_conversation::Question {
    use cmux_conversation::{
        Question, QuestionHarness, QuestionItem, QuestionOption, QuestionState,
    };
    let option = |id: &str, label: &str| QuestionOption {
        id: id.to_owned(),
        label: label.to_owned(),
        detail: None,
        preview: None,
    };
    Question {
        harness: QuestionHarness::Chief,
        session: pending.session_id.clone(),
        permission: Some(pending.permission_id.clone()),
        agent: pending.child.clone(),
        items: vec![QuestionItem {
            id: CARD_ITEM.to_owned(),
            header: Some("Approval".to_owned()),
            prompt: question(pending, reason),
            options: vec![option(CARD_ALLOW, "Allow"), option(CARD_DENY, "Deny")],
            multi_select: false,
            allows_other: false,
        }],
        state: QuestionState::Pending,
    }
}

/// An answered approval card: its permission id, the answer and who gave
/// it. None: not a Chief approval card, or not answered.
pub fn card_answer(question: &cmux_conversation::Question) -> Option<(String, Answer, String)> {
    use cmux_conversation::{QuestionHarness, QuestionState};
    if question.harness != QuestionHarness::Chief {
        return None;
    }
    let permission = question.permission.clone()?;
    let QuestionState::Answered { answer } = &question.state else {
        return None;
    };
    let chosen = answer.selections.get(CARD_ITEM)?.option_ids.first()?;
    let decision = match chosen.as_str() {
        CARD_ALLOW => Answer::Allow,
        CARD_DENY => Answer::Deny,
        _ => return None,
    };
    let who = answer
        .respondent
        .as_ref()
        .map_or_else(|| "a person".to_owned(), |r| r.participant.clone());
    Some((permission, decision, who))
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
