//! A session's last replies (`acpmux last`, the MCP `last` tool, `wait --print`, a prompt's
//! wait for its reply), read from the newest transcript records.
//!
//! The newest [`LAST_REPLY_RECORDS`] records hold the replies. They are read newest first in
//! pages that grow from [`FIRST_PAGE`], and the read stops as soon as the replies asked for are
//! the ones the whole log gives ([`replies`]). The whole 5,000 records (up to 4 MiB of JSON) were
//! read for a reply of a few hundred: 50 ms of each `acpmux last` on a fleet Mac.
//!
//! The daemon that holds the log does this paging itself (`_acpmux/last`,
//! `server/requests/last.rs`) and answers the replies in one reply. A session on another machine
//! then costs one round trip, not one per page: through the mesh hub each page was at most 40 KiB
//! and its own round trip through a busy machine's inbox, and a coordinator's long turn ran past
//! the 50 s a read waits (cmuxterm-hq#15806). A daemon or machine without the method gets the
//! pages, as before.
use crate::client::Client;
use crate::rpc::method;
use crate::transcript::{Item, Transcript};
use anyhow::Result;
use serde_json::{Value, json};
use std::sync::Arc;

/// The most transcript records read back for the replies.
const LAST_REPLY_RECORDS: usize = 5000;
/// The records the first page asks for; each next page asks for four times as many.
const FIRST_PAGE: usize = 256;
/// The most JSON a page of the daemon's log may hold (`_acpmux/events` `maxBytes`).
const PAGE_BYTES: usize = 4 << 20;

/// The last `count` assistant replies of a session, oldest first.
pub(crate) async fn last_replies(
    client: &Arc<Client>,
    id: &str,
    count: usize,
) -> Result<Vec<String>> {
    let count = count.max(1);
    match client.request(method::MUX_LAST, json!({"sessionId": id, "count": count})).await {
        Ok(reply) => return Ok(texts(&reply)),
        Err(e) if !served(&e) => {}
        Err(e) => return Err(e),
    }
    let mut pages = Pages::new(count);
    while let Some(query) = pages.next_query(id) {
        pages.take(&client.request(method::MUX_EVENTS, query).await?);
    }
    Ok(pages.replies())
}

/// The reply texts of an `_acpmux/last` answer.
fn texts(reply: &Value) -> Vec<String> {
    let replies = reply.get("replies").and_then(Value::as_array);
    replies.into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect()
}

/// Whether `e` is an answer from a daemon that serves `_acpmux/last`: false for one that does
/// not know it (an older daemon or peer), or a machine past the hub that does not carry it.
fn served(e: &anyhow::Error) -> bool {
    let Some(daemon) = e.downcast_ref::<crate::client::DaemonError>() else { return true };
    daemon.0.code != crate::rpc::RpcError::method_not_found("").code
        && !daemon.0.message.contains("mesh.read_unsupported")
}

/// The newest transcript records read back page by page until they give the last `count`
/// replies whole: [`last_replies`] over a client, and the daemon's own `_acpmux/last` over its
/// log.
pub(crate) struct Pages {
    count: usize,
    events: Vec<Value>,
    before: u64,
    ask: usize,
    done: bool,
}

impl Pages {
    pub(crate) fn new(count: usize) -> Self {
        Self {
            count: count.max(1),
            events: Vec::new(),
            before: u64::MAX,
            ask: FIRST_PAGE,
            done: false,
        }
    }

    /// The `_acpmux/events` params of the next page of `id`, or None once the records read give
    /// the replies.
    pub(crate) fn next_query(&self, id: &str) -> Option<Value> {
        if self.done {
            return None;
        }
        let limit = self.ask.min(LAST_REPLY_RECORDS.saturating_sub(self.events.len()));
        // Transcript records only. Read newest first (`beforeSeq`): this one-shot read must not
        // attach the shared daemon-to-daemon link to a running chat's live stream.
        Some(json!({
            "sessionId": id, "limit": limit, "kinds": ["transcript"], "maxBytes": PAGE_BYTES,
            "beforeSeq": self.before,
        }))
    }

    /// Takes the page [`Self::next_query`] asked for.
    pub(crate) fn take(&mut self, page: &Value) {
        let older = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let more = page.get("hasMore").and_then(Value::as_bool).unwrap_or(false);
        let Some(first) = older.first().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            self.done = true;
            return;
        };
        self.before = first;
        self.events.splice(0..0, older);
        self.done =
            !more || self.events.len() >= LAST_REPLY_RECORDS || replies(&self.events, self.count).1;
        self.ask = self.ask.saturating_mul(4);
    }

    /// The last replies of the records read, oldest first.
    pub(crate) fn replies(&self) -> Vec<String> {
        replies(&self.events, self.count).0
    }
}

/// The last `count` assistant replies in `events` (oldest first), and whether they are whole:
/// the replies the whole log gives, of which `events` are the newest records.
///
/// A reply grows only while it is the last item (an `agent_message_chunk` extends the last item
/// when it is a reply, else starts one), so the records read can differ from the whole log only
/// in whether the last item is a reply when a chunk comes. Most records make that the same in
/// both (a thought, the person's words, a turn's end), or leave the last item as it was (an
/// update in place). Three kinds add an item only when the item they change is not there, and
/// it may be in the older records: a tool call or its update (by id), a plan (the last plan),
/// and an automatic permission decision (by id). When one of these adds an item after a reply,
/// the whole log may instead have changed an older item and kept the reply last. Until a record
/// makes the last item the same in both again, a chunk that starts a reply here may extend the
/// reply before it in the whole log: that reply is "suspect". The first records read are
/// suspect the same way, as nothing older is known. The replies are whole when there are
/// `count` of them and none is suspect.
fn replies(events: &[Value], count: usize) -> (Vec<String>, bool) {
    let mut t = Transcript::default();
    // Whether the whole log's last item may be a reply while the records read end in another
    // item. The other way round never happens: an item added here is added there too.
    let mut diverged = true;
    // For each reply, in order: whether it may be part of the reply before it in the whole log.
    let mut suspect: Vec<bool> = Vec::new();
    let last_is_reply = |t: &Transcript| matches!(t.items.last(), Some(Item::Assistant { .. }));
    for e in events {
        let (was_reply, before) = (last_is_reply(&t), t.items.len());
        t.apply_event(e);
        // The person's message always ends the transcript, also when it moves a queued one there
        // (one item out, one in).
        let added = t.items.len() > before || is_mux(e, "user_message");
        let is_reply = last_is_reply(&t);
        if !added {
            // An update in place, or a record that changes no item: the last item stays as it
            // was in both.
            if !is_reply && was_reply {
                // Never seen: an item removed from the end. Count it as unknown.
                diverged = true;
            }
        } else if adds_only_when_missing(e) {
            diverged |= was_reply;
        } else if is_reply {
            suspect.push(diverged);
            diverged = false;
        } else {
            diverged = false;
        }
    }
    let at: Vec<usize> = t
        .items
        .iter()
        .enumerate()
        .filter_map(|(i, item)| matches!(item, Item::Assistant { .. }).then_some(i))
        .collect();
    let kept = at.get(at.len().saturating_sub(count)..).unwrap_or_default();
    let whole = at.len() >= count
        && suspect.len() == at.len()
        && !suspect.get(suspect.len().saturating_sub(count)..).unwrap_or_default().contains(&true);
    let texts = kept
        .iter()
        .filter_map(|&i| match t.items.get(i) {
            Some(Item::Assistant { text }) => Some(text.clone()),
            _ => None,
        })
        .collect();
    (texts, whole)
}

/// Whether `record` adds an item only when the item it changes is not among the records read:
/// a tool call or its update, a plan, or an automatic permission decision.
fn adds_only_when_missing(record: &Value) -> bool {
    match record.get("dir").and_then(Value::as_str) {
        Some("in") => matches!(
            record.pointer("/msg/params/update/sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update" | "plan")
        ),
        Some("mux") => is_mux(record, "permission_auto"),
        _ => false,
    }
}

/// Whether `record` is the daemon's own record of `kind`.
fn is_mux(record: &Value, kind: &str) -> bool {
    record.get("dir").and_then(Value::as_str) == Some("mux")
        && record.get("kind").and_then(Value::as_str) == Some(kind)
}

#[cfg(test)]
#[path = "last_reply_tests.rs"]
mod tests;
