//! The bound on the `acpmux` MCP server's `inbox_read` answer (`acpmux_mcp.rs` `inbox_tool`,
//! `hub/inbox.rs`).
//!
//! `inbox_read` with no thread answers every thread of a chat's inbox, and a thread's row carries
//! its newest message's preview; with a thread, that thread's messages whole. Neither shape had a
//! bound. On an agent session on one of our hosts, 2026-11-22, a chat with 101 threads answered
//! `inbox_read` with 68,054 characters -- past the caller's token limit, so the harness wrote the
//! answer to a file and the agent read it back with `jq` in three more calls. The four threads
//! that said they needed the agent were in there somewhere; the agent could not see them.
//!
//! So the thread *list* is cut to [`MAX_CHARS`] the way `wrap_up` caps its recap at 600: the threads that
//! have unread messages are kept first, every field keeps its name, long text is clipped, and
//! `omitted` counts exactly what was left out and says how to ask for it. `detail: true` returns
//! the answer whole, for a caller with the room. A short answer that does not say it is short is
//! worse than a long one: an agent reads absence as an empty inbox.
//!
//! One thread's messages are never clipped. That call is the one that says "give me this whole",
//! and a helper that reads a standing order in preview form refuses work it was given (hub
//! integration test `with_team_messaging_off_a_chat_reads_its_inbox_whole`, 2026-10-31). A thread
//! read keeps its newest `limit` messages whole and counts the older ones under `omitted`.

use serde_json::{Value, json};

/// The most characters the default answer takes, stated in the tool's description so a caller
/// knows the bound before it calls. Not a refusal and not a `maxLength`: a longer answer is
/// clipped and says what it left out, because a caller that cannot read the answer calls again.
pub(super) const MAX_CHARS: usize = 6000;
/// The most thread rows (or messages of one thread) the default answer carries, before the bound
/// cuts further. Also the default `limit`.
pub(super) const BRIEF_ROWS: usize = 20;
/// The largest `limit` a caller may ask for without `detail`.
pub(super) const MAX_LIMIT: usize = 200;
/// How much of each row the answer keeps, tried in order: the longest any text in it stays (a
/// message's text, a preview, a label). Rows give up length before any row is dropped, so a chat
/// with one very long message keeps every row and loses only the length.
const TEXT_TIERS: [usize; 4] = [4000, 1200, 400, 160];

/// `text` at most `max` characters, with an ellipsis when it was cut. Character counts, not byte
/// offsets, so no cut lands inside a character.
fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let kept: String = text.chars().take(max.saturating_sub(1)).collect();
    format!("{}…", kept.trim_end())
}

/// `value` with every string in it clipped to `field` characters, all the way down, counting into
/// `cut` the characters left out.
fn brief_value(value: &Value, field: usize, cut: &mut usize) -> Value {
    match value {
        Value::String(s) => {
            let whole = s.chars().count();
            let short = clip(s, field);
            *cut += whole.saturating_sub(short.chars().count());
            json!(short)
        }
        Value::Array(entries) => {
            Value::Array(entries.iter().map(|e| brief_value(e, field, cut)).collect())
        }
        Value::Object(fields) => Value::Object(
            fields.iter().map(|(k, v)| (k.clone(), brief_value(v, field, cut))).collect(),
        ),
        other => other.clone(),
    }
}

/// Which array of rows this answer is: the thread list, or one thread's messages.
fn rows_key(answer: &Value) -> Option<&'static str> {
    ["threads", "messages"]
        .into_iter()
        .find(|&key| answer.get(key).and_then(Value::as_array).is_some())
}

/// A thread row that says it has unread messages: kept before the quiet ones, because the one
/// question in an inbox of 101 threads is the reason to read it at all.
fn unread(row: &Value) -> bool {
    row.get("unread").and_then(Value::as_u64).unwrap_or(0) > 0
        || row.get("new").and_then(Value::as_u64).unwrap_or(0) > 0
        || row.get("needYou").and_then(Value::as_bool).unwrap_or(false)
}

/// `rows` with the unread ones first, each keeping its place otherwise (a stable partition), so
/// the bound never drops a thread that needs an answer while keeping a quiet one.
fn unread_first(rows: &[Value]) -> Vec<Value> {
    let mut out: Vec<Value> = rows.iter().filter(|r| unread(r)).cloned().collect();
    out.extend(rows.iter().filter(|r| !unread(r)).cloned());
    out
}

/// One thread's answer with its newest `limit` messages, each whole (the daemon sends them newest
/// first), and `omitted` counting the older ones. No text is clipped here: a message read in
/// preview form is a standing order half read.
fn newest_messages(answer: &Value, limit: usize, whole: usize) -> Value {
    let rows: Vec<Value> =
        answer.get("messages").and_then(Value::as_array).cloned().unwrap_or_default();
    let keep = rows.len().min(limit.clamp(1, MAX_LIMIT));
    let dropped = rows.len().saturating_sub(keep);
    let mut out = answer.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.insert("messages".into(), Value::Array(rows.into_iter().take(keep).collect()));
        if dropped > 0 {
            obj.insert(
                "omitted".into(),
                json!({
                    "bound": limit,
                    "rows": dropped,
                    "of": "messages",
                    "charactersLeftOut": 0,
                    "charactersOfWhole": whole,
                    "textMax": 0,
                    "how": "pass a larger limit, or detail: true, for the older messages; the kept ones are whole",
                }),
            );
        }
    }
    out
}

/// The daemon's answer under [`MAX_CHARS`]: at most `limit` rows, unread first, each clipped, and
/// the last rows dropped until it fits. `omitted` says what was left out and how to get it.
/// `detail` returns the answer whole.
pub(super) fn brief(answer: &Value, limit: usize, detail: bool) -> Value {
    if detail {
        return answer.clone();
    }
    let whole = answer.to_string().chars().count();
    let Some(key) = rows_key(answer) else { return answer.clone() };
    // One thread's messages arrive whole: only how many of them is bounded.
    if key == "messages" {
        return newest_messages(answer, limit, whole);
    }
    let rows: Vec<Value> =
        answer.get(key).and_then(Value::as_array).map(|r| unread_first(r)).unwrap_or_default();
    let asked = limit.clamp(1, MAX_LIMIT);
    let unread_rows = rows.iter().filter(|r| unread(r)).count();
    let mut keep = rows.len().min(asked);
    let mut tier = 0usize;
    loop {
        let field = TEXT_TIERS.get(tier).copied().unwrap_or(160);
        let mut cut = 0usize;
        let kept: Vec<Value> =
            rows.iter().take(keep).map(|r| brief_value(r, field, &mut cut)).collect();
        let dropped = rows.len().saturating_sub(keep);
        let mut out = answer.clone();
        if let Some(obj) = out.as_object_mut() {
            obj.insert(key.into(), Value::Array(kept));
            obj.insert(
                "omitted".into(),
                json!({
                    "bound": MAX_CHARS,
                    "rows": dropped,
                    "of": key,
                    "unreadKept": unread_rows.min(keep),
                    "unreadLeftOut": unread_rows.saturating_sub(keep),
                    "charactersLeftOut": cut,
                    "charactersOfWhole": whole,
                    // The length each kept row was clipped to, so rows in short form read apart
                    // from rows in full.
                    "textMax": field,
                    "how": "pass detail: true for the answer whole, a thread for its messages, or limit for more rows",
                }),
            );
        }
        if out.to_string().chars().count() <= MAX_CHARS || keep == 0 {
            return out;
        }
        if tier + 1 < TEXT_TIERS.len() {
            tier += 1;
        } else {
            tier = 0;
            keep -= 1;
        }
    }
}

/// The answer as the CLI prints it (`cli::session_inbox::describe`), with what the bound left out
/// stated at the end, never silently.
pub(super) fn text(answer: &Value) -> String {
    let mut out = crate::cli::session_inbox::describe(answer).trim_end().to_owned();
    if let Some(o) = answer.get("omitted") {
        let n = |k: &str| o.get(k).and_then(Value::as_u64).unwrap_or(0);
        let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("rows").to_owned();
        let (rows, chars, whole) = (n("rows"), n("charactersLeftOut"), n("charactersOfWhole"));
        if rows > 0 && chars == 0 && n("textMax") == 0 {
            out.push_str(&format!(
                "\n({rows} older messages left out of {whole} characters; the kept ones are whole. \
For the rest: a larger limit, or detail: true.)"
            ));
        } else if rows > 0 || chars > 0 {
            out.push_str(&format!(
                "\n(bounded to {MAX_CHARS} characters of {whole}: {rows} {} and {chars} \
characters of text left out, unread first, each row kept to {} characters. For all of it: \
detail: true; for one thread's messages: thread.)",
                s("of"),
                n("textMax"),
            ));
            if n("unreadLeftOut") > 0 {
                out.push_str(&format!(
                    "\n({} of the threads left out have unread messages: raise limit.)",
                    n("unreadLeftOut")
                ));
            }
        }
    }
    out
}

/// `limit` as the tool takes it: a number, the default [`BRIEF_ROWS`] when absent.
pub(super) fn limit_of(args: &Value) -> usize {
    args.get("limit")
        .and_then(Value::as_u64)
        .map_or(BRIEF_ROWS, |n| usize::try_from(n).unwrap_or(BRIEF_ROWS).clamp(1, MAX_LIMIT))
}

/// `detail` as the tool takes it.
pub(super) fn detail_of(args: &Value) -> bool {
    args.get("detail").and_then(Value::as_bool).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A thread row the size a real inbox makes it: a preview that is the whole first line of
    /// another agent's brief.
    fn fat_thread(i: usize, unread: u64) -> Value {
        json!({
            "threadId": format!("uujx:poy-vjxuz-cvuk-{i}/wbtab-pdtb-nirvm"),
            "label": "messages",
            "class": "fyi",
            "count": 3,
            "unread": unread,
            "new": 0,
            "from": [format!("gcp-agent-lane-{i}/a-lane-with-a-long-name")],
            "newestPreview": "x".repeat(600),
            "sender": {"label": format!("gcp-agent-lane-{i}/a-lane-with-a-long-name"), "harness": "claude", "verification": "verified"},
        })
    }

    fn fat_inbox(n: usize, unread_at: &[usize]) -> Value {
        let threads: Vec<Value> =
            (0..n).map(|i| fat_thread(i, u64::from(unread_at.contains(&i)))).collect();
        json!({"sessionId": "a-session", "surge": {"held": 20, "needYou": 4}, "threads": threads})
    }

    #[test]
    fn a_hundred_threads_stay_under_the_bound_and_say_what_was_left_out() {
        // The loss this bounds: 101 threads answered 68,054 characters, past the caller's limit.
        let whole = fat_inbox(101, &[97]);
        assert!(whole.to_string().chars().count() > 60_000);
        let short = brief(&whole, BRIEF_ROWS, false);
        let len = short.to_string().chars().count();
        assert!(len <= MAX_CHARS, "bounded answer is {len} characters, over {MAX_CHARS}");
        let o = &short["omitted"];
        assert_eq!(o["of"], "threads");
        assert_eq!(o["rows"], json!(101 - BRIEF_ROWS));
        assert_eq!(o["charactersOfWhole"], json!(whole.to_string().chars().count()));
        assert!(text(&short).contains("bounded to"));
    }

    #[test]
    fn the_thread_with_unread_messages_is_never_the_one_dropped() {
        // The unread thread is last in the daemon's order, past any bound on row count.
        let short = brief(&fat_inbox(101, &[100]), BRIEF_ROWS, false);
        let kept = short["threads"].as_array().expect("threads").clone();
        assert!(kept.iter().any(|t| t["unread"].as_u64() == Some(1)), "the unread thread was cut");
        assert_eq!(short["omitted"]["unreadLeftOut"], json!(0));
    }

    #[test]
    fn a_threads_messages_are_never_clipped() {
        // A standing order read in preview form is work half read (hub integration test
        // `with_team_messaging_off_a_chat_reads_its_inbox_whole`).
        let order = "y".repeat(21_000);
        let messages: Vec<Value> = (0..4)
            .map(|i| json!({"kind": "action", "from": "a-lane", "promptId": format!("p{i}"), "text": order.clone()}))
            .collect();
        let thread = json!({"threadId": "pr:12", "label": "#12", "messages": messages});
        let short = brief(&thread, BRIEF_ROWS, false);
        assert_eq!(short["messages"].as_array().map(Vec::len), Some(4), "a message was dropped");
        assert_eq!(short["messages"][0]["text"], json!(order), "a message was clipped");
        assert!(short.get("omitted").is_none(), "nothing was left out: {short}");
    }

    #[test]
    fn a_long_thread_keeps_its_newest_messages_whole_and_counts_the_rest() {
        let messages: Vec<Value> = (0..40)
            .map(|i| json!({"kind": "action", "from": "a-lane", "promptId": format!("p{i}"), "text": format!("message {i} ").repeat(50)}))
            .collect();
        let thread = json!({"threadId": "pr:12", "label": "#12", "messages": messages});
        let short = brief(&thread, 5, false);
        let kept = short["messages"].as_array().expect("messages");
        assert_eq!(kept.len(), 5);
        // Newest first, whole, in the daemon's order.
        assert_eq!(kept[0]["promptId"], "p0");
        assert_eq!(kept[0]["text"], json!("message 0 ".repeat(50)));
        assert_eq!(short["omitted"]["rows"], json!(35));
        assert!(text(&short).contains("35 older messages left out"));
    }

    #[test]
    fn detail_returns_the_answer_whole() {
        let whole = fat_inbox(30, &[]);
        assert_eq!(brief(&whole, BRIEF_ROWS, true), whole);
    }

    #[test]
    fn an_empty_inbox_is_answered_as_itself() {
        let empty = json!({"threads": []});
        let short = brief(&empty, BRIEF_ROWS, false);
        assert_eq!(short["threads"], json!([]));
        assert_eq!(text(&short), "The inbox is empty.");
    }

    #[test]
    fn limit_and_detail_read_what_a_caller_passes() {
        assert_eq!(limit_of(&json!({})), BRIEF_ROWS);
        assert_eq!(limit_of(&json!({"limit": 6})), 6);
        assert_eq!(limit_of(&json!({"limit": 9999})), MAX_LIMIT);
        assert_eq!(limit_of(&json!({"limit": 0})), 1);
        assert!(!detail_of(&json!({})));
        assert!(detail_of(&json!({"detail": true})));
    }
}
