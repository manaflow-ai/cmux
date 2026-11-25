//! A turn Claude Code ends with its own API error as the reply.
//!
//! Claude Code reports a request it gave up on as an assistant line of its own
//! (`"is_api_error_message": true`, model `<synthetic>`, text "API Error: ..."), then a result.
//! Usually that result says `is_error: true` and acpmux fails the turn, so the capacity resume
//! continues it (`hub/auto_resume.rs`). Some results say `is_error: false`, `subtype: success`:
//! the turn then read as an answer, and a chat whose last words were "API Error: Repeated 529
//! Overloaded errors" sat idle with nothing to wake it (gcp-agent-lane-13, 2026-11-24 22:05Z and
//! 22:10Z; Leo: "i wonder what will happen with claudes on vms... do they get stranded!?").
//! Such a result is the turn's failure, with the error's text, whatever its flags say.

use serde_json::Value;

/// The text of `line` when it is Claude Code's own API error line on the chat's main loop: an
/// assistant line marked `is_api_error_message`, or a `<synthetic>` one whose text starts with
/// "API Error". None for any other line, a subagent's included (its own turn handles it).
pub(super) fn text(line: &Value) -> Option<String> {
    if line.get("type").and_then(Value::as_str) != Some("assistant")
        || line.get("parent_tool_use_id").and_then(Value::as_str).is_some()
    {
        return None;
    }
    let said: String = line
        .pointer("/message/content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| c.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|c| c.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("");
    let said = said.trim();
    let flagged = line.get("is_api_error_message").and_then(Value::as_bool) == Some(true);
    let synthetic = line.pointer("/message/model").and_then(Value::as_str) == Some("<synthetic>");
    if !flagged && !(synthetic && said.starts_with("API Error")) {
        return None;
    }
    if !said.is_empty() {
        return Some(said.to_owned());
    }
    // A line whose text was left out: what its fields still say.
    let status = line.get("api_error_status").and_then(Value::as_u64);
    let kind = line.get("error").and_then(Value::as_str);
    Some(match (status, kind) {
        (Some(status), Some(kind)) => format!("API Error: {status} {kind}"),
        (Some(status), None) => format!("API Error: {status}"),
        (None, Some(kind)) => format!("API Error: {kind}"),
        (None, None) => "API Error".to_owned(),
    })
}

/// The error a result ends its turn with, if it fails it: `None` when the result says nothing
/// went wrong and the turn's last assistant line (`last`, [`text`]) was not an API error.
/// A result's own text wins when it names the error (Claude Code puts it there too).
pub(super) fn failure(result: &Value, last: Option<String>) -> Option<String> {
    let last = last?;
    let own = result.get("result").and_then(Value::as_str).map(str::trim).unwrap_or("");
    Some(if own.starts_with("API Error") { own.to_owned() } else { last })
}
