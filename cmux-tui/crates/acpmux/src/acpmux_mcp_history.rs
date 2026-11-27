//! The `acpmux` MCP server's `chat_history` tool (`server/history.rs`, `hub/compaction_outline.rs`,
//! RFD 0075): this chat's own past, read back from its pack, so a chat that compacted holds a
//! summary plus the names of the turns it summarized and fetches what it needs. One call is a
//! few milliseconds to tens of milliseconds, and each answer is bounded.

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "chat_history";
/// What every chat with the tool is told.
pub(super) const STEER: &str = "After a compaction, call chat_history with a range from your summary \
(<session>@<first>-<last>) to read what was asked and run there; with seq for one result whole.";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Read this chat's own earlier history from its pack, after a compaction or whenever you need what was said or run before. Three ways, one call each (about 10 to 50 ms; the first call on a chat that was never packed packs it, which takes seconds on a large chat). (1) No range and no seq: the OUTLINE, one line a turn: range id (<session>@<first line>-<last line>), start time (ms), record count, the first 160 bytes of what was asked; at most 200 turns (default 50, newest first; before=LINE pages to older ones; compacted=true lists only the turns your newest compaction summarized). (2) range=<session>@<first>-<last>: that range's DIGEST as text: what was asked, what you replied, each tool call's input (400 bytes) and the first 600 bytes of its result, each cut result naming the seq that brings it whole; the answer is at most 32 KiB. (3) seq=N: ONE RECORD whole as JSON, at most 64 KiB per call (nextOffset in the answer; pass it as offset for the rest). Read-only; answers are of the packed log, whose newest records may not be in it yet (packedThroughSeq says how far; fresh=true packs the newest first, slow on a large chat).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "range": {"type": "string", "description": "A turn's range id from the outline or your compaction summary, <session>@<first line>-<last line>. Returns its digest (at most 32 KiB)."},
                "seq": {"type": "integer", "minimum": 1, "description": "A record's seq (named in a digest as 'seq N'). Returns that record whole (at most 64 KiB per call)."},
                "offset": {"type": "integer", "minimum": 0, "description": "With seq: the byte to start at, from a previous answer's nextOffset."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200, "description": "Outline only: how many turns (default 50, at most 200)."},
                "before": {"type": "integer", "minimum": 0, "description": "Outline only: list the turns that start before this line (a previous answer's older-turns note gives it)."},
                "compacted": {"type": "boolean", "description": "Outline only: only the turns the newest compaction summarized."},
                "fresh": {"type": "boolean", "description": "Pack the newest records first (slow on a large chat). Default false."}
            }
        }
    })
}

/// The `_acpmux/history/read` params of one `chat_history` call.
pub(super) fn request(session: &str, args: &Value) -> Result<Value, String> {
    let object = args.as_object().ok_or("arguments must be an object")?;
    if object.contains_key("range") && object.contains_key("seq") {
        return Err("pass a range or a seq, not both".to_owned());
    }
    let mut params = json!({"sessionId": session});
    if let Some(p) = params.as_object_mut() {
        for key in ["range", "seq", "offset", "limit", "before", "compacted", "fresh"] {
            if let Some(v) = object.get(key).filter(|v| !v.is_null()) {
                p.insert(key.to_owned(), v.clone());
            }
        }
    }
    Ok(params)
}

/// One `chat_history` call for chat `session`.
pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("this server runs in no acpmux chat".to_owned());
    }
    let params = match request(session, args) {
        Ok(p) => p,
        Err(e) => return error_result(e),
    };
    match daemon.request(method::MUX_HISTORY_READ, params).await {
        Ok(answer) => {
            let text = text(&answer);
            ok(text, answer)
        }
        Err(e) => refusal(e),
    }
}

/// The answer as the agent reads it: the text, then where to go on.
pub(super) fn text(answer: &Value) -> String {
    let mut out = answer.get("text").and_then(Value::as_str).unwrap_or_default().to_owned();
    if let Some(next) = answer.get("nextOffset").and_then(Value::as_u64) {
        let seq = answer.get("seq").and_then(Value::as_u64).unwrap_or(0);
        out.push_str(&format!(
            "\n[record {seq} is {} bytes; this is part of it: call again with seq={seq} offset={next}]",
            answer.get("bytes").and_then(Value::as_u64).unwrap_or(0)
        ));
    }
    out
}
