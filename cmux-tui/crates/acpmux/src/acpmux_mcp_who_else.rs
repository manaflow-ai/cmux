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
        "description": format!("Who else is working on these files: the other live and recent agent sessions (any harness, this machine and its peers) that read or edited them, sit in this chat's worktree or on its branch, or work on the topic. Each row: name, harness, host, branch, its pull requests, the files in common (edited or read) and how recent. With no files and no topic, the files this chat edited lately. Message one with the send tool. The answer is a line per session and at most {MAX_CHARS} characters: it keeps the top {BRIEF_SESSIONS} rows, clips long titles, folders and file lists, and counts what it left out under omitted. Pass detail: true for every row and field, which can be far longer."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "files": {"type": "array", "items": {"type": "string"}, "description": "Paths, absolute or relative to this chat's folder."},
                "topic": {"type": "string", "description": "Words a session's name, title or prompt should share."},
                "since": {"type": "string", "description": "How far back a touch counts: 30m, 6h, 2d (default 1d)."},
                "detail": {"type": "boolean", "description": format!("Every session row and every field, whole, instead of the {MAX_CHARS}-character answer (default false). Only when the short answer's omitted counts say the detail you need was cut.")},
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
mod tests {
    use super::*;

    /// A row with every field the daemon sends, with `files` and the text as long as a real
    /// checkout makes them.
    fn fat_row(i: usize) -> Value {
        let dir = format!("/home/agent/checkouts/some-repository/a-rather-long-worktree-name-{i}");
        let files: Vec<Value> = (0..40)
            .map(|f| json!({"repo": "some-repository", "path": format!("{dir}/crates/a-crate-with-a-long-name/src/a_module_with_a_long_name_{f}.rs")}))
            .collect();
        json!({
            "agoMs": 1000 + i, "branch": format!("a-long-branch-name-for-session-{i}"),
            "cwd": dir, "editedInCommon": 3, "files": files, "filesInCommon": 7,
            "harness": "claude", "host": format!("a-host-{i}"), "lastActiveAt": 1_764_000_000_000u64,
            "live": true, "name": format!("a-session-with-a-long-name-{i}"),
            "pullRequests": [{"url": "https://github.com/owner/repo/pull/12345"}],
            "ref": format!("a-host-{i}/a-session-with-a-long-name-{i}"),
            "sameBranch": false, "sameWorktree": false, "score": 90 - i as i64,
            "sessionId": format!("aid-{i:032x}"), "status": "working",
            "title": "A session title that runs on and on about what the agent is doing right now, \
        long enough to matter when forty of them arrive at once".to_owned(),
            "topicWords": ["acpmux", "mcp", "bound", "who", "else", "output"],
        })
    }

    fn fat_answer(n: usize) -> Value {
        let rows: Vec<Value> = (0..n).map(fat_row).collect();
        let lines: Vec<String> = (0..n)
            .map(|i| {
                format!(
                    "a-host-{i}/a-session-with-a-long-name-{i}  claude  working  7 files in common"
                )
            })
            .collect();
        json!({
            "schema": "acpmux.who-else.v1",
            "query": {"files": [], "fileCount": 0, "topic": "acpmux", "branch": null, "worktree": null},
            "sessions": rows, "more": 0, "unreached": [], "lines": lines,
        })
    }

    #[test]
    fn many_long_sessions_stay_under_the_bound_and_say_what_was_left_out() {
        let whole = fat_answer(60);
        // The bug this bounds: the whole answer is far past any caller's room.
        assert!(whole.to_string().chars().count() > 100_000);
        let short = brief(&whole);
        let len = short.to_string().chars().count();
        assert!(len <= MAX_CHARS, "bounded answer is {len} characters, over {MAX_CHARS}");
        let omitted = short.get("omitted").expect("the answer says what it left out");
        let n = |k: &str| omitted.get(k).and_then(Value::as_u64).unwrap();
        assert_eq!(n("bound"), MAX_CHARS as u64);
        assert!(n("sessions") > 0, "60 rows cannot fit, so some are counted out");
        assert!(n("listEntries") > 0, "40-file lists are cut, so their entries are counted out");
        assert_eq!(n("charactersOfWhole"), whole.to_string().chars().count() as u64);
        assert!(omitted.get("how").and_then(Value::as_str).unwrap().contains("detail: true"));
        // The cut is in the text an agent reads, not only in the structure.
        let text = text(&short);
        assert!(text.contains("left out"), "{text}");
        assert!(text.contains("detail: true"), "{text}");
        // Every row keeps every field name, so nothing a caller reads disappears.
        let before = fat_row(0).as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        let after = short.get("sessions").and_then(Value::as_array).unwrap()[0]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        assert_eq!(before, after);
        // The summary line of each kept row survives: that is the answer to "who owns this".
        let lines = short.get("lines").and_then(Value::as_array).unwrap();
        assert_eq!(lines.len(), short.get("sessions").and_then(Value::as_array).unwrap().len());
        assert!(!lines.is_empty(), "the bound never empties the summary");
    }

    #[test]
    fn the_measured_call_six_sessions_of_detail_fits_and_keeps_every_line() {
        // The call that overflowed twice on one of our hosts had 6 lines and more: 0; the bulk
        // was per-session detail. Bounded, every line stays and only the detail is cut.
        let whole = fat_answer(6);
        let short = brief(&whole);
        assert!(short.to_string().chars().count() <= MAX_CHARS);
        assert_eq!(short.get("lines").and_then(Value::as_array).unwrap().len(), 6);
        assert_eq!(short.get("sessions").and_then(Value::as_array).unwrap().len(), 6);
        assert_eq!(short.get("omitted").unwrap().get("sessions").unwrap(), &json!(0));
        assert!(short.get("omitted").unwrap().get("listEntries").unwrap().as_u64().unwrap() > 0);
        // The cut names its tier, so six short rows read apart from six whole ones.
        let detail = short.get("omitted").unwrap().get("rowDetail").unwrap();
        assert!(detail.get("tier").unwrap().as_u64().unwrap() > 0, "{detail}");
        assert!(text(&short).contains("short form"));
    }

    #[test]
    fn a_short_answer_is_unchanged_but_for_the_counts() {
        let whole = json!({
            "schema": "acpmux.who-else.v1", "sessions": [], "more": 0,
            "unreached": [{"host": "a-host", "error": "no answer in 5 s"}], "lines": [],
        });
        let short = brief(&whole);
        assert_eq!(short.get("sessions").unwrap(), &json!([]));
        assert_eq!(short.get("unreached").unwrap(), whole.get("unreached").unwrap());
        assert_eq!(short.get("omitted").unwrap().get("sessions").unwrap(), &json!(0));
        // Nothing was cut, so the text carries no cut note and still names the quiet peer.
        let text = text(&short);
        assert!(!text.contains("left out"), "{text}");
        assert!(text.contains("no answer in 5 s"), "{text}");
    }

    #[test]
    fn the_daemons_own_ranked_out_count_is_carried_not_overwritten() {
        let mut whole = fat_answer(20);
        whole.as_object_mut().unwrap().insert("more".into(), json!(429));
        let short = brief(&whole);
        let omitted = short.get("omitted").unwrap();
        assert_eq!(omitted.get("rankedOut").unwrap(), &json!(429));
        let kept = short.get("sessions").and_then(Value::as_array).unwrap().len();
        let dropped = 20 - kept;
        assert_eq!(short.get("more").unwrap(), &json!(429 + dropped as u64));
    }

    #[test]
    fn the_bound_and_the_way_to_the_rest_are_in_the_tools_own_description() {
        let tool = tool();
        let description = tool.get("description").and_then(Value::as_str).unwrap();
        assert!(description.contains(&MAX_CHARS.to_string()), "{description}");
        assert!(description.contains("detail: true"), "{description}");
        let detail = &tool["inputSchema"]["properties"]["detail"];
        assert_eq!(detail.get("type").unwrap(), &json!("boolean"));
        assert!(detail.get("description").and_then(Value::as_str).unwrap().contains("whole"));
    }

    #[test]
    fn clip_cuts_on_a_character_and_marks_the_cut() {
        assert_eq!(clip("short", 10), "short");
        assert_eq!(clip("ααααα", 3), "αα…");
        assert_eq!(clip("abcdef", 6), "abcdef");
    }
}
