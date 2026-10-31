//! An adopted chat shows its past at once (Lawrence P0 2026-10-11, "opening chat doesnt work").
//!
//! Adopting resumes a Claude Code or Codex conversation in a new acpmux session (`adopt.rs`).
//! Claude Code's `--resume` replays nothing to the client, so the pane showed an empty chat. This
//! reads the harness's own transcript (the file `adopt::find` found) into turns: each person
//! prompt, the tool calls the turn made (`adopt_tools.rs`) and the assistant text that answered
//! it. `Hub::replay_adopted` appends them as acpmux history (`turn_started`, `user_message`,
//! `tool_call` and `tool_call_update`, `agent_message_chunk`, `turn_end`) before the session
//! continues, the same records a live turn leaves, so every client draws them.

use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

use crate::adopt_tools::{PastTool, ToolResult};

#[path = "adopt_replay_page.rs"]
mod page;
pub use page::{
    ClaudePage, PAGE_TURNS, claude_page, claude_page_with_turns, newest_claude_page,
    newest_prompt_start,
};
pub(crate) use page::{claude_page_with_turns_open, newest_prompt_start_open};

/// One past exchange: the person's prompt, the tool calls it led to, in order, and the
/// assistant's answer text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PastTurn {
    pub prompt: String,
    pub tools: Vec<PastTool>,
    pub answer: String,
    /// When the prompt was sent and the answer last written (ms since the epoch), when recorded.
    pub prompt_at: Option<u64>,
    pub answer_at: Option<u64>,
}

/// At most this many turns (the newest) and this much text per answer: a long chat stays cheap.
const MAX_TURNS: usize = 200;
const MAX_ANSWER: usize = 20_000;
/// At most this many tool calls per turn (the first).
const MAX_TOOLS: usize = 400;
/// A transcript bigger than this is read for its newest part only.
const MAX_BYTES: u64 = 64 << 20;

/// The turns of `file`, a `family` (`claude`, `codex`) transcript; empty when unreadable.
pub fn read(family: &str, file: &Path) -> Vec<PastTurn> {
    let Ok(mut f) = std::fs::File::open(file) else { return Vec::new() };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    // A bigger transcript is read from its newest MAX_BYTES; the first, partial line is skipped.
    let skip_first = len > MAX_BYTES;
    if skip_first && f.seek(SeekFrom::Start(len - MAX_BYTES)).is_err() {
        return Vec::new();
    }
    // No further than the file was when opened: what the harness appends meanwhile waits for the
    // next read, so one read is bounded however fast the chat grows.
    let f = f.take(len.min(MAX_BYTES));
    let mut turns: Vec<PastTurn> = Vec::new();
    // Codex's message items before its rollout turns current (items annotated with their kinds):
    // older Codex also wrote each turn as event messages, which are read instead, so no turn
    // shows twice; a rollout with no event messages at all is read from these.
    let mut items: Vec<PastTurn> = Vec::new();
    // Current Codex writes no event messages: from its first annotated item on (a chat begun on
    // an older Codex and resumed on a current one), items are the turns.
    let mut current = false;
    // Current Codex records each finished tool call as an `item_completed` event; older Codex
    // wrote `exec_command_end` and patch events, read until the first such item.
    let mut tool_items = false;
    for (index, line) in BufReader::new(f).lines().map_while(Result::ok).enumerate() {
        if skip_first && index == 0 {
            continue;
        }
        let Ok(record) = serde_json::from_str::<Value>(&line) else { continue };
        let at = record.get("timestamp").and_then(Value::as_str).and_then(parse_ms);
        match family {
            "codex" => {
                current = current || has_item_kinds(&record);
                if let Some((tool, item)) = crate::adopt_tools::codex_tool(&record, at) {
                    tool_items = tool_items || item;
                    if item || !tool_items {
                        // With the turns that are being read: event messages, else items.
                        let into =
                            if current || !turns.is_empty() { &mut turns } else { &mut items };
                        add(into, tool.map_or_else(Step::ToolResult, Step::Tool), at);
                    }
                } else if let Some(step) = codex_step(&record) {
                    add(&mut turns, step, at);
                } else if let Some(step) = codex_item_step(&record) {
                    add(if current { &mut turns } else { &mut items }, step, at);
                }
            }
            _ => {
                for step in claude_steps(&record, at) {
                    add(&mut turns, step, at);
                }
            }
        }
    }
    if turns.is_empty() {
        turns = items;
    }
    let skip = turns.len().saturating_sub(MAX_TURNS);
    turns.drain(..skip);
    turns
}

/// What one transcript record adds: a person's prompt, or answer text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    Prompt(String),
    Answer(String),
    Tool(PastTool),
    ToolResult(ToolResult),
}

/// The prompts and answer text one record of a transcript being followed adds (`hub/watch.rs`),
/// by the rules [`read`] uses; tool calls and results are left out. `codex_items` says the
/// rollout is a current Codex one, whose message items are its turns; a record annotated with
/// item kinds sets it.
pub fn record_steps(family: &str, record: &Value, codex_items: &mut bool) -> Vec<Step> {
    match family {
        "codex" => {
            *codex_items = *codex_items || has_item_kinds(record);
            codex_step(record)
                .or_else(|| codex_item_step(record).filter(|_| *codex_items))
                .into_iter()
                .collect()
        }
        _ => claude_steps(record, record_time(record))
            .into_iter()
            .filter(|step| matches!(step, Step::Prompt(_) | Step::Answer(_)))
            .collect(),
    }
}

/// Whether `record` ends the turn it belongs to: Claude Code's assistant message stopped at the
/// end of its turn, Codex's task or turn completed.
pub fn ends_turn(family: &str, record: &Value) -> bool {
    match family {
        "codex" => {
            record.get("type").and_then(Value::as_str) == Some("event_msg")
                && matches!(
                    record.pointer("/payload/type").and_then(Value::as_str),
                    Some("task_complete" | "turn_complete")
                )
        }
        // Claude Code writes each content block of a message as its own line, all with the
        // message's stop reason (thinking first): the turn ends with its text.
        _ => {
            record.get("type").and_then(Value::as_str) == Some("assistant")
                && record.get("isSidechain").and_then(Value::as_bool) != Some(true)
                && matches!(
                    record.pointer("/message/stop_reason").and_then(Value::as_str),
                    Some("end_turn" | "stop_sequence")
                )
                && record.pointer("/message/content").and_then(Value::as_array).is_some_and(
                    |blocks| {
                        blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                    },
                )
        }
    }
}

/// When `record` was written (its `timestamp`), in ms since the epoch.
pub fn record_time(record: &Value) -> Option<u64> {
    record.get("timestamp").and_then(Value::as_str).and_then(parse_ms)
}

/// A prompt starts a turn; an answer adds to the last one, capped at MAX_ANSWER; a tool call
/// joins the last one (once: a call recorded again replaces it), and a result settles its call.
fn add(turns: &mut Vec<PastTurn>, step: Step, at: Option<u64>) {
    match step {
        Step::Prompt(text) => turns.push(PastTurn {
            prompt: text,
            tools: Vec::new(),
            answer: String::new(),
            prompt_at: at,
            answer_at: at,
        }),
        Step::Tool(tool) => {
            let Some(turn) = turns.last_mut() else { return };
            if let Some(known) = turn.tools.iter_mut().find(|t| t.id == tool.id) {
                *known = tool;
            } else if turn.tools.len() < MAX_TOOLS {
                turn.tools.push(tool);
            }
        }
        Step::ToolResult(result) => {
            let Some(turn) = turns.last_mut() else { return };
            if let Some(tool) = turn.tools.iter_mut().rev().find(|t| t.id == result.id) {
                tool.settle(&result, at);
            }
        }
        Step::Answer(text) => {
            let Some(turn) = turns.last_mut() else { return };
            turn.answer_at = at.or(turn.answer_at);
            if !turn.answer.is_empty() {
                turn.answer.push_str("\n\n");
            }
            turn.answer.push_str(&text);
            if turn.answer.len() > MAX_ANSWER {
                let mut cut = MAX_ANSWER;
                while !turn.answer.is_char_boundary(cut) {
                    cut -= 1;
                }
                turn.answer.truncate(cut);
            }
        }
    }
}

/// Claude Code: `{"type":"user","message":{"content":...}}` (a typed prompt: a string or text
/// blocks; tool results settle their calls, and meta lines are not prompts) and
/// `{"type":"assistant",...}` text and `tool_use` blocks.
fn claude_steps(record: &Value, at: Option<u64>) -> Vec<Step> {
    let flag = |key: &str| record.get(key).and_then(Value::as_bool) == Some(true);
    if flag("isSidechain") || flag("isMeta") || flag("isCompactSummary") || !from_person(record) {
        return Vec::new();
    }
    let Some(content) = record.pointer("/message/content") else { return Vec::new() };
    match record.get("type").and_then(Value::as_str) {
        // A tool result is not a prompt, also beside text (as `hub::fork_at::is_prompt`).
        Some("user")
            if content.as_array().is_some_and(|blocks| {
                blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
            }) =>
        {
            crate::adopt_tools::claude_tool_results(content, record.get("toolUseResult"))
                .into_iter()
                .map(Step::ToolResult)
                .collect()
        }
        Some("assistant") => {
            let mut steps: Vec<Step> = crate::adopt_tools::claude_tool_uses(content, at)
                .into_iter()
                .map(Step::Tool)
                .collect();
            steps.extend(text_of(content).map(Step::Answer));
            steps
        }
        Some("user") => claude_prompt(content).into_iter().collect(),
        _ => Vec::new(),
    }
}

/// A Claude Code prompt: a user message's text, unless it echoes a command or a hook or marks
/// an interruption.
fn claude_prompt(content: &Value) -> Option<Step> {
    let text = text_of(content)?;
    let start = text.trim_start();
    let echo = ["<command-", "<local-command-", "<bash-", "[Request interrupted"]
        .iter()
        .any(|prefix| start.starts_with(prefix));
    (!echo).then_some(Step::Prompt(text))
}

/// Whether a Claude Code line came from the person: it has no `origin`, or its `origin.kind` is
/// `human`. Claude Code also writes user lines itself (`task-notification` when a background task
/// or subagent finishes, `peer` for another session's `<cross-session-message>`).
pub(crate) fn from_person(record: &Value) -> bool {
    match record.pointer("/origin/kind") {
        None | Some(Value::Null) => true,
        Some(kind) => kind.as_str() == Some("human"),
    }
}

/// Codex rollouts: `{"type":"event_msg","payload":{"type":"user_message"|"agent_message","message":...}}`.
fn codex_step(record: &Value) -> Option<Step> {
    if record.get("type").and_then(Value::as_str) != Some("event_msg") {
        return None;
    }
    let payload = record.get("payload")?;
    let text = payload.get("message").and_then(Value::as_str)?.trim().to_owned();
    if text.is_empty() {
        return None;
    }
    match payload.get("type").and_then(Value::as_str)? {
        "user_message" => Some(Step::Prompt(text)),
        "agent_message" => Some(Step::Answer(text)),
        _ => None,
    }
}

/// Current Codex rollouts carry no event messages, only `response_item` messages: a person's
/// prompt is a `user` message whose items are all `user.text` (AGENTS.md and environment context
/// arrive as `user` messages of other kinds), and the answer is the `assistant` message of phase
/// `final_answer` (`commentary` is progress narration). A rollout without these annotations
/// keeps every `user` text that is not a context block, and every `assistant` text.
fn codex_item_step(record: &Value) -> Option<Step> {
    if record.get("type").and_then(Value::as_str) != Some("response_item") {
        return None;
    }
    let payload = record.get("payload")?;
    if payload.get("type").and_then(Value::as_str) != Some("message") {
        return None;
    }
    let text: String = payload
        .get("content")?
        .as_array()?
        .iter()
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .filter(|text| !crate::prompt_context::is_context_text(text))
        .collect::<Vec<_>>()
        .join("\n");
    let text = text.trim().to_owned();
    if text.is_empty() {
        return None;
    }
    match payload.get("role").and_then(Value::as_str)? {
        "user" => {
            let kinds =
                payload.pointer("/internal_chat_message_metadata_passthrough/content_item_kinds");
            let typed = match kinds.and_then(Value::as_array) {
                Some(kinds) => is_typed(kinds),
                None => !CODEX_CONTEXT.iter().any(|prefix| text.starts_with(prefix)),
            };
            typed.then_some(Step::Prompt(text))
        }
        "assistant" => match payload.get("phase").and_then(Value::as_str) {
            None | Some("final_answer") => Some(Step::Answer(text)),
            Some(_) => None,
        },
        _ => None,
    }
}

/// Whether a Codex `user` message's item kinds are the person's own: text, maybe with images
/// (`user.text`, `user.image`), never injected context (`agents_md.instructions`, ...).
fn is_typed(kinds: &[Value]) -> bool {
    kinds.iter().any(|kind| kind.as_str() == Some("user.text"))
        && kinds.iter().all(|kind| kind.as_str().is_some_and(|kind| kind.starts_with("user.")))
}

/// Whether `record` is a Codex message item annotated with its item kinds (current Codex).
fn has_item_kinds(record: &Value) -> bool {
    record.get("type").and_then(Value::as_str) == Some("response_item")
        && record
            .pointer("/payload/internal_chat_message_metadata_passthrough/content_item_kinds")
            .is_some()
}

/// How Codex's injected `user` context begins, for rollouts without item kinds.
const CODEX_CONTEXT: [&str; 4] = [
    "<environment_context>",
    "<user_instructions>",
    "# AGENTS.md instructions",
    "<user_shell_command>",
];

/// The text of a message's content: a string, or the `text` of its text blocks.
fn text_of(content: &Value) -> Option<String> {
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .filter(|text| !crate::prompt_context::is_context_text(text))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// An RFC 3339 time (`2026-10-02T09:00:00.000Z`) in ms since the epoch.
fn parse_ms(text: &str) -> Option<u64> {
    cmux_chat_index::time::parse_rfc3339_ms(text).and_then(|ms| u64::try_from(ms).ok())
}
