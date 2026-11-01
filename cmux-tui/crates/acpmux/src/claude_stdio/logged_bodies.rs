//! What a chat's log keeps of Claude Code's raw `assistant` and `user` lines.
//!
//! Claude Code writes one `assistant` line per content block of a message (the block whole: a tool
//! call's input, a thought and its signature, the text) and one `user` line per tool result (its
//! output twice: `message.content` and `tool_use_result`), and the translated `session/update`
//! records beside them carry all of it again. In four Claude chats of 22-37 MB (2026-10-30) these
//! two raw kinds were 18-45% of the log, and every tool output was in it three times.
//!
//! No reader takes a body from the raw lines; the transcript, the web and iOS clients fold the
//! translated records. What is read, and kept: every field of the line and its `message` but the
//! content blocks' bodies (optchat-chief's `fold.rs`: the message's id, model and usage, the
//! line's session, `parent_tool_use_id`, `isReplay`; `chief-turn`'s `Line::User`: each block's
//! type, `tool_use_id` and `is_error`), so a block keeps its type, ids, tool name and error flag.
//! What goes: the blocks' bodies (`input`, `text`, `thinking`, `signature`, `content`, ...), a
//! string `message.content` (a prompt Claude Code echoes; `user_message` holds it), and Claude
//! Code's own copies of tool data (`tool_use_result`, `tool_result_meta`, `wire_tool_inputs`).
//! The line notes how many bytes went as `_acpmux.bodiesLeftOut`, a namespaced key no Claude field
//! can collide with (as `workflowProgressItems`, `logged_line`).

use serde_json::{Map, Value, json};

/// The raw kinds whose bodies the log leaves out.
const KINDS: [&str; 2] = ["claude.assistant", "claude.user"];
/// Claude Code's copies of a tool's data beside its blocks.
const COPIES: [&str; 3] = ["tool_use_result", "tool_result_meta", "wire_tool_inputs"];
/// What a content block keeps: what it is, the ids that pair a call with its result, the tool's
/// name and whether the result is an error.
const BLOCK_KEEPS: [&str; 5] = ["type", "id", "tool_use_id", "name", "is_error"];

/// `line`, a raw Claude line of `kind` as it is about to be logged, without the bodies no reader
/// takes from the log. Other kinds are left as they are.
pub fn leave_out_bodies(kind: &str, line: &mut Value) {
    if !KINDS.contains(&kind) {
        return;
    }
    let Some(fields) = line.as_object_mut() else { return };
    let mut left_out: usize = 0;
    for key in COPIES {
        left_out = left_out.saturating_add(fields.remove(key).map_or(0, |v| bytes(&v)));
    }
    if let Some(content) = fields.get_mut("message").and_then(|m| m.get_mut("content")) {
        match content {
            Value::String(text) if !text.is_empty() => {
                left_out = left_out.saturating_add(bytes(&Value::String(std::mem::take(text))));
            }
            Value::Array(blocks) => {
                for block in blocks.iter_mut().filter_map(Value::as_object_mut) {
                    left_out = left_out.saturating_add(keep_only(block));
                }
            }
            _ => {}
        }
    }
    if left_out > 0 {
        let note = fields.entry("_acpmux").or_insert_with(|| json!({}));
        if let Some(note) = note.as_object_mut() {
            note.insert("bodiesLeftOut".into(), Value::from(left_out));
        }
    }
}

/// Removes every field of `block` but [`BLOCK_KEEPS`]; the bytes removed.
fn keep_only(block: &mut Map<String, Value>) -> usize {
    let mut removed: usize = 0;
    block.retain(|key, value| {
        let keep = BLOCK_KEEPS.contains(&key.as_str());
        if !keep {
            removed = removed.saturating_add(key.len()).saturating_add(bytes(value));
        }
        keep
    });
    removed
}

/// A value's bytes as JSON.
fn bytes(value: &Value) -> usize {
    serde_json::to_string(value).map_or(0, |s| s.len())
}

#[cfg(test)]
#[path = "logged_bodies_tests.rs"]
mod tests;
