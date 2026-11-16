//! Shared predicates deciding which raw Claude lines the log keeps.
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};

/// Whether a raw Claude line answers the `get_context_usage` a turn's result
/// asked (`ctx-*`); its trimmed breakdown is what acpmux keeps.
pub fn is_context_answer(line: &Value) -> bool {
    line.pointer("/response/request_id")
        .and_then(Value::as_str)
        .is_some_and(|id| id.starts_with("ctx-"))
}

/// Whether a raw `stream_event` line is one a request's timing reads: a `message_start`, or the
/// first `content_block_delta` after one. Only the main agent's requests are timed; a subagent's
/// lines (`parent_tool_use_id`) stream alongside them and are never kept.
pub fn times_request(params: &Value, awaiting_first_delta: &AtomicBool) -> bool {
    if params.get("parent_tool_use_id").is_some_and(|p| !p.is_null()) {
        return false;
    }
    match params.pointer("/event/type").and_then(Value::as_str) {
        Some("message_start") => {
            awaiting_first_delta.store(true, Ordering::Relaxed);
            true
        }
        Some("content_block_delta") => awaiting_first_delta.swap(false, Ordering::Relaxed),
        _ => false,
    }
}
