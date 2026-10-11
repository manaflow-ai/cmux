//! An adopted chat shows its past at once (Lawrence P0 2026-10-11, "opening chat doesnt work").
//!
//! Adopting resumes a Claude Code or Codex conversation in a new acpmux session (`adopt.rs`).
//! Claude Code's `--resume` replays nothing to the client, so the pane showed an empty chat. This
//! reads the harness's own transcript (the file `adopt::find` found) into turns: each person
//! prompt and the assistant text that answered it. `Hub::replay_adopted` appends them as acpmux
//! history (`turn_started`, `user_message`, `agent_message_chunk`, `turn_end`) before the session
//! continues, the same records a live turn leaves, so every client draws them.

use std::io::{BufRead, BufReader};
use std::path::Path;

use serde_json::Value;

/// One past exchange: the person's prompt and the assistant's answer text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PastTurn {
    pub prompt: String,
    pub answer: String,
}

/// At most this many turns (the newest) and this much text per answer: a long chat stays cheap.
const MAX_TURNS: usize = 200;
const MAX_ANSWER: usize = 20_000;
/// A transcript bigger than this is read for its newest part only.
const MAX_BYTES: u64 = 64 << 20;

/// The turns of `file`, a `family` (`claude`, `codex`) transcript; empty when unreadable.
pub fn read(family: &str, file: &Path) -> Vec<PastTurn> {
    let Ok(f) = std::fs::File::open(file) else { return Vec::new() };
    if f.metadata().map(|m| m.len() > MAX_BYTES).unwrap_or(true) {
        return Vec::new();
    }
    let mut turns: Vec<PastTurn> = Vec::new();
    for line in BufReader::new(f).lines().map_while(Result::ok) {
        let Ok(record) = serde_json::from_str::<Value>(&line) else { continue };
        let step = match family {
            "codex" => codex_step(&record),
            _ => claude_step(&record),
        };
        match step {
            Some(Step::Prompt(text)) => {
                turns.push(PastTurn { prompt: text, answer: String::new() })
            }
            Some(Step::Answer(text)) => {
                if let Some(turn) = turns.last_mut() {
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
            None => {}
        }
    }
    let skip = turns.len().saturating_sub(MAX_TURNS);
    turns.drain(..skip);
    turns
}

enum Step {
    Prompt(String),
    Answer(String),
}

/// Claude Code: `{"type":"user","message":{"content":...}}` (a typed prompt: a string or text
/// blocks; tool results and meta lines are not prompts) and `{"type":"assistant",...}` text blocks.
fn claude_step(record: &Value) -> Option<Step> {
    if record.get("isSidechain").and_then(Value::as_bool) == Some(true)
        || record.get("isMeta").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let content = record.pointer("/message/content")?;
    match record.get("type").and_then(Value::as_str)? {
        "user" => {
            let text = text_of(content)?;
            // Command and hook echoes (`<command-name>`, `<local-command-stdout>`) are not prompts.
            (!text.trim_start().starts_with('<')).then_some(Step::Prompt(text))
        }
        "assistant" => text_of(content).map(Step::Answer),
        _ => None,
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

/// The text of a message's content: a string, or the `text` of its text blocks.
fn text_of(content: &Value) -> Option<String> {
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}
