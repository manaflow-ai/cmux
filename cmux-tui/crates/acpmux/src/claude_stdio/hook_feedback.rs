//! A Stop hook that blocks the agent's stop: Claude Code goes on with the hook's reason as a new
//! synthetic user line, `"<Event> hook feedback:\n<reason>"` (2.1.3xx; `isSynthetic: true`), in
//! the same turn and with no record of its own. Without a mark the continuation reads as a second
//! reply (Leo, 2026-11-22: "if you did get hooked, i think it should get displayed better"), so
//! acpmux turns the line into a `hook_feedback` update the chat draws where the turn went on.

use serde_json::{Value, json};

/// The hook events whose block makes the agent go on (Claude Code's Stop and SubagentStop).
const EVENTS: [&str; 2] = ["Stop", "SubagentStop"];

/// The `hook_feedback` update for a synthetic hook-feedback user line, or None for any other line.
/// A reason Claude Code prefixes with its hook's command (`[cmd]: reason`) names the hook.
pub(super) fn hook_feedback_update(line: &Value) -> Option<Value> {
    if line.get("isSynthetic").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let text = match line.pointer("/message/content")? {
        Value::String(s) => s.as_str(),
        Value::Array(blocks) => match blocks.as_slice() {
            [block] if block.get("type").and_then(Value::as_str) == Some("text") => {
                block.get("text").and_then(Value::as_str)?
            }
            _ => return None,
        },
        _ => return None,
    };
    let (event, rest) = text.split_once(" hook feedback:")?;
    if !EVENTS.contains(&event) {
        return None;
    }
    let reason = rest.trim();
    let mut update = json!({"sessionUpdate": "hook_feedback", "hookEvent": event});
    let (name, reason) = match reason.strip_prefix('[').and_then(|r| r.split_once("]: ")) {
        Some((name, reason)) if !name.is_empty() && !name.contains('\n') => {
            (Some(name), reason.trim())
        }
        _ => (None, reason),
    };
    if let Some(name) = name {
        update["hookName"] = json!(name);
    }
    update["text"] = json!(reason);
    Some(update)
}
