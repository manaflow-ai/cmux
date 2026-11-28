//! The `acpmux` MCP server's `who_else` tool: who else is working on these files, in one call,
//! for every harness acpmux runs (`_acpmux/who_else`, `hub/touched.rs`). It answers the same as
//! `acpmux who-else --json`: the other live and recent sessions, here and on peers, that read or
//! edited the files, share the chat's worktree or branch, or work on the topic, best first. Its
//! text is one line per session; `structuredContent` is the daemon's answer, which the
//! agent pane draws as a card (`webviews/.../conversation/whoElseCalls.ts`).
//!
//! The answer is bounded (`brief`). The question the tool answers, who already owns this area, is
//! a short answer, but the daemon's row carries every field it knows for each session, so a few
//! sessions with long file lists and titles made a result no caller could read: on an agent
//! session on one of our hosts, 2026-11-21, one call returned 113,488 characters, over the
//! caller's token limit, and the same call again returned the same 113,488 and failed the same
//! way. Two calls, no information. So by default the result is cut to `MAX_CHARS` the way
//! `wrap_up` caps its recap at 600: every field keeps its name, long text and long lists are
//! clipped, the lowest-ranked rows go last, and `omitted` counts exactly what was left out.
//! `detail: true` returns the answer whole, for a caller that wants it and has the room.

use super::{arg, error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Map, Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "who_else";

/// The most characters the default `structuredContent` takes, stated in the tool's description so
/// a caller knows the bound before it calls. Not a refusal and not a `maxLength`: a longer answer
/// is clipped and says what it left out, because a caller that cannot read the answer re-sends
/// the same call.
pub(super) const MAX_CHARS: usize = 6000;
/// The most session rows the default answer carries, before the bound cuts further.
pub(super) const BRIEF_SESSIONS: usize = 12;
/// How much of each row the default answer keeps, tried in order: the most entries a row's list
/// field keeps (its files, topic words, pull requests) and the longest any text in it stays (its
/// title, folder, branch, a file's path). Rows give up detail before any row is dropped, so a
/// few sessions with long file lists keep every row and lose only the length.
const BRIEF_TIERS: [(usize, usize); 3] = [(3, 120), (1, 60), (0, 40)];

/// The instruction the server gives with the tool.
pub(super) const STEER: &str = "Before changing files another agent may be working on, or to \
learn who owns an area, call who_else (files, topic, or nothing) instead of digging through git \
log or PR lists.";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": format!("Find live or recent sessions here and on peers by file, worktree, branch or topic. Defaults to your recent edits. Up to {BRIEF_SESSIONS} rows and {MAX_CHARS} characters. Use detail: true if omitted counts show a match you need."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "files": {"type": "array", "items": {"type": "string"}, "description": "Paths, absolute or relative to this chat's folder."},
                "topic": {"type": "string", "description": "Words a session's name, title or prompt should share."},
                "since": {"type": "string", "description": "How far back a touch counts: 30m, 6h, 2d (default 1d)."},
                "detail": {"type": "boolean", "description": "Return every row and field whole (default false)."},
                "description": {"type": "string", "description": "A few words on why you look, shown as this call's title."}
            }
        }
    })
}

/// The request params for a call from session `session`.
pub(super) fn params(session: &str, args: &Value) -> Result<Value, String> {
    let mut p = Map::new();
    p.insert("sessionId".into(), json!(session));
    if let Some(files) = args.get("files") {
        let files: Vec<&str> = files
            .as_array()
            .ok_or("files must be an array of paths")?
            .iter()
            .filter_map(Value::as_str)
            .filter(|f| !f.trim().is_empty())
            .collect();
        if !files.is_empty() {
            p.insert("files".into(), json!(files));
        }
    }
    if let Some(topic) = arg(args, "topic") {
        p.insert("topic".into(), json!(topic));
    }
    if let Some(since) = arg(args, "since") {
        let ms = crate::cli::who_else::duration_ms(since).map_err(|e| e.to_string())?;
        p.insert("sinceMs".into(), json!(ms));
    }
    Ok(Value::Object(p))
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("who_else needs the chat's session (ACPMUX_SESSION_ID)".to_owned());
    }
    let p = match params(session, args) {
        Ok(p) => p,
        Err(e) => return error_result(e),
    };
    match daemon.request(method::MUX_WHO_ELSE, p).await {
        Ok(answer) => {
            if args.get("detail").and_then(Value::as_bool) == Some(true) {
                return ok(text(&answer), answer);
            }
            let short = brief(&answer);
            ok(text(&short), short)
        }
        Err(e) => refusal(e),
    }
}

/// `text` at most `max` characters, with an ellipsis when it was cut. Character counts, not byte
/// offsets, so no cut lands inside a character.
fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let kept: String = text.chars().take(max.saturating_sub(1)).collect();
    format!("{}…", kept.trim_end())
}

/// `value` with its text clipped to `field` characters and its lists cut to `list` entries, all
/// the way down (a row's `files` are objects whose `path` is the long part), counting into `cut`
/// every list entry left out.
fn brief_value(value: &Value, list: usize, field: usize, cut: &mut usize) -> Value {
    match value {
        Value::String(s) => json!(clip(s, field)),
        Value::Array(entries) => {
            *cut += entries.len().saturating_sub(list);
            Value::Array(
                entries.iter().take(list).map(|e| brief_value(e, list, field, cut)).collect(),
            )
        }
        Value::Object(fields) => Value::Object(
            fields.iter().map(|(k, v)| (k.clone(), brief_value(v, list, field, cut))).collect(),
        ),
        other => other.clone(),
    }
}

/// One session row clipped (`brief_value`). Every field keeps its name and its type, so the card
/// (`whoElseCalls.ts`) and any caller reading a field still find it; only the length changes.
fn brief_row(row: &Value, list: usize, field: usize, cut: &mut usize) -> Value {
    if !row.is_object() {
        return row.clone();
    }
    brief_value(row, list, field, cut)
}

/// The daemon's answer under `MAX_CHARS`: the `lines` summary with its rows, each row clipped
/// (`brief_row`), and the lowest-ranked rows dropped until it fits. `omitted` says what was left
/// out and how to get it, because an answer that is quietly short is worse than a long one: a
/// caller that cannot tell detail is missing reads absence as "no one else is here".
pub(super) fn brief(answer: &Value) -> Value {
    let whole = answer.to_string().chars().count();
    let rows: Vec<Value> =
        answer.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let lines: Vec<Value> =
        answer.get("lines").and_then(Value::as_array).cloned().unwrap_or_default();
    // The daemon's own count of the rows it ranked out (`hub/touched.rs` MAX_ROWS).
    let ranked_out = answer.get("more").and_then(Value::as_u64).unwrap_or(0);
    let mut keep = rows.len().min(BRIEF_SESSIONS);
    let mut tier = 0usize;
    loop {
        // `tier` stays below `BRIEF_TIERS.len()` (stepped below); the shortest is the fallback.
        let (list, field) = BRIEF_TIERS.get(tier).copied().unwrap_or((0, 40));
        let mut cut = 0usize;
        let kept: Vec<Value> =
            rows.iter().take(keep).map(|r| brief_row(r, list, field, &mut cut)).collect();
        let dropped = rows.len().saturating_sub(keep);
        let mut out = answer.clone();
        if let Some(obj) = out.as_object_mut() {
            obj.insert("sessions".into(), Value::Array(kept));
            obj.insert("lines".into(), Value::Array(lines.iter().take(keep).cloned().collect()));
            obj.insert("more".into(), json!(ranked_out + dropped as u64));
            obj.insert(
                "omitted".into(),
                json!({
                    "bound": MAX_CHARS,
                    "sessions": dropped,
                    "rankedOut": ranked_out,
                    "listEntries": cut,
                    // The detail tier each kept row was cut to, so six rows in short form read
                    // apart from six rows in full: the most entries a list keeps, the longest text.
                    "rowDetail": {"tier": tier, "listMax": list, "textMax": field},
                    "charactersOfWhole": whole,
                    "how": "pass detail: true for every row and field, or narrow the call with files, topic or since",
                }),
            );
        }
        if out.to_string().chars().count() <= MAX_CHARS || keep == 0 {
            return out;
        }
        if tier + 1 < BRIEF_TIERS.len() {
            tier += 1;
        } else {
            tier = 0;
            keep -= 1;
        }
    }
}

/// The answer as the CLI prints it: a line per session, then the peers that gave no answer, so
/// an agent does not read a quiet peer as no one working there. A bounded answer (`brief`) ends
/// with what it left out, stated, never silently.
pub(super) fn text(answer: &Value) -> String {
    let mut out = crate::cli::who_else::text(answer).trim_end().to_owned();
    if let Some(o) = answer.get("omitted") {
        let n = |k: &str| o.get(k).and_then(Value::as_u64).unwrap_or(0);
        let (sessions, entries, whole) = (n("sessions"), n("listEntries"), n("charactersOfWhole"));
        if sessions > 0 || entries > 0 {
            let detail = o.get("rowDetail");
            let d = |k: &str| detail.and_then(|v| v.get(k)).and_then(Value::as_u64).unwrap_or(0);
            out.push_str(&format!(
                "\n(bounded to {MAX_CHARS} characters of {whole}: {sessions} session rows and \
{entries} list entries left out; each row kept in short form, at most {} list entries and {} \
characters of text. For all of it: detail: true.)",
                d("listMax"),
                d("textMax")
            ));
        }
    }
    out
}

#[cfg(test)]
#[path = "acpmux_mcp_who_else_tests.rs"]
mod tests;
