//! One transcript line into the docs a search finds: the person's prompts, the agent's reply text,
//! and each tool call's input and output, with the JSON escaping undone (a `\n` is a real line
//! break). Each line is read alone, so a transcript is followed by reading only the lines it
//! appended; the only state carried from line to line is the turn count ([`LineState`]).
//!
//! Claude Code (`~/.claude/projects/<cwd>/<id>.jsonl`): `{"type": "user" | "assistant",
//! "timestamp", "message": {"content": string | [blocks]}}`. A compaction leaves the lines before it
//! in the file and adds a summary (`isCompactSummary`), so what was said before a compaction is
//! found too. Other line kinds (`api-request-blob`, `queue-operation`, attachments, ...) repeat or
//! describe what those lines hold and are skipped.
//!
//! Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`): `{"timestamp", "type":
//! "response_item", "payload": {"type": "message" | "function_call" | ...}}`; `event_msg` lines
//! repeat the items and are skipped; a `compacted` line's summary is kept.

use serde_json::Value;

/// Who said a doc's text.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// The person's prompt (and anything delivered as one: another agent's message).
    User,
    /// The agent's reply text.
    Assistant,
    /// A tool call's input or its output.
    Tool,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            "tool" => Some(Self::Tool),
            _ => None,
        }
    }

    pub(crate) fn code(self) -> i64 {
        match self {
            Self::User => 0,
            Self::Assistant => 1,
            Self::Tool => 2,
        }
    }

    pub(crate) fn from_code(code: i64) -> Self {
        match code {
            0 => Self::User,
            1 => Self::Assistant,
            _ => Self::Tool,
        }
    }
}

/// Which harness wrote a transcript, and so how its lines read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Harness {
    Claude,
    Codex,
}

impl Harness {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }
}

/// The most of a prompt's or reply's text one doc holds; the rest is left out.
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
/// The most of a tool call's input or output one doc holds: a file read or a long log is mostly
/// not what anyone searches for, and the index stays a small part of the transcript's size.
pub const MAX_TOOL_BYTES: usize = 8 * 1024;

/// One searchable piece of a line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Doc {
    pub role: Role,
    pub text: String,
    /// The harness's id of the reply the text is from, as acpmux reports it on the reply's
    /// chunks (`agent_message_chunk.messageId`): Claude Code's `message.id` (`msg_...`), a Codex
    /// item's `id` when its rollout line has one. Only the agent's reply text has one.
    pub message: Option<String>,
}

/// What is carried from one line to the next: the turn the next doc is in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LineState {
    /// The person's prompts read so far: a doc is in turn `turn` (0 before the first prompt).
    pub turn: u32,
}

/// One line's docs, and its time (ms since the epoch) when it has one.
#[derive(Debug, Default)]
pub struct Line {
    pub at_ms: Option<i64>,
    pub docs: Vec<Doc>,
}

/// Reads one line; a line that is not JSON or holds nothing searchable gives no docs.
pub fn line(harness: Harness, bytes: &[u8], state: &mut LineState) -> Line {
    // Most lines are bookkeeping: skip them before parsing (an `api-request-blob` is megabytes).
    let wanted: &[&[u8]] = match harness {
        Harness::Claude => &[b"\"type\":\"user\"", b"\"type\":\"assistant\""],
        Harness::Codex => &[b"\"response_item\"", b"\"compacted\"", b"\"type\":\"message\""],
    };
    if !wanted.iter().any(|w| memchr::memmem::find(bytes, w).is_some()) {
        return Line::default();
    }
    let Ok(record) = serde_json::from_slice::<Value>(bytes) else { return Line::default() };
    let at_ms = record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
    let mut docs = Vec::new();
    match harness {
        Harness::Claude => claude(&record, state, &mut docs),
        Harness::Codex => codex(&record, state, &mut docs),
    }
    docs.retain(|d| !d.text.trim().is_empty());
    Line { at_ms, docs }
}

fn claude(record: &Value, state: &mut LineState, docs: &mut Vec<Doc>) {
    let kind = record.get("type").and_then(Value::as_str).unwrap_or_default();
    if kind != "user" && kind != "assistant" {
        return;
    }
    // Text Claude Code puts in as a prompt for its own reasons (skills, command output).
    if record.get("isMeta").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let compact = record.get("isCompactSummary").and_then(Value::as_bool) == Some(true);
    let Some(content) = record.pointer("/message/content") else { return };
    let role = if kind == "user" { Role::User } else { Role::Assistant };
    let message = record
        .pointer("/message/id")
        .and_then(Value::as_str)
        .filter(|id| role == Role::Assistant && !id.is_empty());
    let said = |text: String| Doc { message: message.map(str::to_owned), ..capped(role, text) };
    let mut prompt = false;
    match content {
        Value::String(text) => {
            prompt = role == Role::User;
            docs.push(said(text.clone()));
        }
        Value::Array(blocks) => {
            for block in blocks {
                match block.get("type").and_then(Value::as_str).unwrap_or_default() {
                    "text" => {
                        if let Some(text) = block.get("text").and_then(Value::as_str) {
                            prompt |= role == Role::User;
                            docs.push(said(text.to_owned()));
                        }
                    }
                    "tool_use" => {
                        let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = block.get("input").unwrap_or(&Value::Null);
                        docs.push(capped(Role::Tool, tool_text(name, input)));
                    }
                    "tool_result" => {
                        let text = content_text(block.get("content").unwrap_or(&Value::Null));
                        docs.push(capped(Role::Tool, text));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    // A compaction's summary is the agent's account of the turns before it, not a new prompt.
    if prompt && !compact {
        state.turn += 1;
    }
}

/// How Codex's injected `user` context begins (environment, AGENTS.md, a shell command's echo):
/// not a prompt, and not what anyone searches for.
const CODEX_CONTEXT: [&str; 5] = [
    "<environment_context>",
    "<user_instructions>",
    "# AGENTS.md instructions",
    "<user_shell_command>",
    "<turn_aborted>",
];

fn codex(record: &Value, state: &mut LineState, docs: &mut Vec<Doc>) {
    let kind = record.get("type").and_then(Value::as_str).unwrap_or_default();
    let item = match kind {
        "response_item" => record.get("payload").unwrap_or(&Value::Null),
        "compacted" => {
            if let Some(text) = record.pointer("/payload/message").and_then(Value::as_str) {
                docs.push(capped(Role::Assistant, text.to_owned()));
            }
            return;
        }
        // Rollouts before the `response_item` wrapper hold the item itself.
        "message" | "function_call" | "function_call_output" | "local_shell_call" => record,
        _ => return,
    };
    match item.get("type").and_then(Value::as_str).unwrap_or_default() {
        "message" => {
            let text = content_text(item.get("content").unwrap_or(&Value::Null));
            match item.get("role").and_then(Value::as_str).unwrap_or_default() {
                "user" => {
                    if CODEX_CONTEXT.iter().any(|c| text.trim_start().starts_with(c)) {
                        return;
                    }
                    state.turn += 1;
                    docs.push(capped(Role::User, text));
                }
                "assistant" => {
                    let message = item
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|id| !id.is_empty())
                        .map(str::to_owned);
                    docs.push(Doc { message, ..capped(Role::Assistant, text) });
                }
                _ => {}
            }
        }
        "function_call" => {
            let name = item.get("name").and_then(Value::as_str).unwrap_or("tool");
            let args = item.get("arguments").and_then(Value::as_str).unwrap_or_default();
            let input = serde_json::from_str::<Value>(args).unwrap_or(Value::String(args.into()));
            docs.push(capped(Role::Tool, tool_text(name, &input)));
        }
        "custom_tool_call" => {
            let name = item.get("name").and_then(Value::as_str).unwrap_or("tool");
            let input = item.get("input").unwrap_or(&Value::Null);
            docs.push(capped(Role::Tool, tool_text(name, input)));
        }
        "local_shell_call" => {
            let input = item.pointer("/action/command").unwrap_or(&Value::Null);
            docs.push(capped(Role::Tool, tool_text("shell", input)));
        }
        "function_call_output" | "custom_tool_call_output" => {
            let output = item.get("output").unwrap_or(&Value::Null);
            // An older output is `{"output": text, "metadata": ...}` in a string.
            let text = match output {
                Value::String(s) => match serde_json::from_str::<Value>(s) {
                    Ok(Value::Object(o)) => o
                        .get("output")
                        .and_then(Value::as_str)
                        .map_or_else(|| s.clone(), str::to_owned),
                    Ok(v @ Value::Array(_)) => content_text(&v),
                    _ => s.clone(),
                },
                other => content_text(other),
            };
            docs.push(capped(Role::Tool, text));
        }
        _ => {}
    }
}

/// A message's text: a string, or the `text` of each of its blocks, one per line.
fn content_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                Value::String(s) => Some(s.as_str()),
                _ => b.get("text").and_then(Value::as_str),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// A tool call as a reader searches it: its name, then each string in its input on a line of its
/// own (a command, a path, a pattern), unescaped.
fn tool_text(name: &str, input: &Value) -> String {
    let mut out = String::from(name);
    let mut push = |s: &str| {
        out.push('\n');
        out.push_str(s);
    };
    fn walk(v: &Value, push: &mut dyn FnMut(&str)) {
        match v {
            Value::String(s) => push(s),
            Value::Array(items) => items.iter().for_each(|i| walk(i, push)),
            Value::Object(fields) => fields.values().for_each(|i| walk(i, push)),
            Value::Number(n) => push(&n.to_string()),
            Value::Bool(_) | Value::Null => {}
        }
    }
    walk(input, &mut push);
    out
}

fn capped(role: Role, mut text: String) -> Doc {
    let max = if role == Role::Tool { MAX_TOOL_BYTES } else { MAX_MESSAGE_BYTES };
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    Doc { role, text, message: None }
}

/// `2026-11-18T09:00:00.123Z` (or with an offset) in ms since the epoch.
pub fn parse_rfc3339_ms(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    if b.len() < 19
        || b.get(4) != Some(&b'-')
        || b.get(7) != Some(&b'-')
        || !matches!(b.get(10), Some(b'T' | b' '))
    {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        std::str::from_utf8(b.get(r)?).ok()?.parse::<i64>().ok()
    };
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let mut i = 19;
    let mut ms = 0i64;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        let frac = text.get(start..i)?;
        let digits: String = frac.chars().chain("000".chars()).take(3).collect();
        ms = digits.parse().ok()?;
    }
    let offset_min = match b.get(i) {
        None | Some(b'Z' | b'z') => 0,
        Some(sign @ (b'+' | b'-')) => {
            let oh = num(i + 1..i + 3)?;
            let om = num(i + 4..i + 6).unwrap_or(0);
            let total = oh * 60 + om;
            if *sign == b'+' { total } else { -total }
        }
        _ => return None,
    };
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + s - offset_min * 60;
    Some(secs * 1000 + ms)
}
