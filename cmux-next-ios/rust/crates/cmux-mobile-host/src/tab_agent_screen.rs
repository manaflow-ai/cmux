//! An agent tab's last-known text for the phone's tab grid: the chat's last
//! turns, read on this Mac, so a tab the phone never opened, or whose chat
//! hibernated, still shows what was said in it.
//!
//! Leo, 2026-11-25: "there are too many empty previews in the safari grid
//! thing we ought to be able to simply capture them before they get
//! hibernated maybe".
//!
//! The text goes into the tab's row as its screen ([`Tabs::set_screen`]), the
//! path a terminal's screen text takes, so it reaches only the phones whose
//! chat exposure shows the tab (the `tabs` service's row filter). It is read
//! from acpmux's event log (`_acpmux/events`, newest first), a read from disk
//! that never resumes the agent, so a hibernated chat is read as it is. A
//! read that fails leaves the last capture in place.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Value, json};

use crate::config::AcpmuxTarget;
use crate::tab_snapshots::Tabs;

/// The most an agent tab's text of its last turns holds ([`agent_screen`]).
pub const MAX_AGENT_SCREEN_BYTES: usize = 4 << 10;
/// The turns an agent tab's text shows, newest last.
pub const AGENT_SCREEN_TURNS: usize = 3;
/// The width an agent tab's text is laid out to, in characters.
pub const AGENT_SCREEN_COLS: usize = 80;
/// The newest records read for the last turns.
const TAIL_RECORDS: usize = 1024;
/// The most JSON that page may hold.
const TAIL_BYTES: usize = 1 << 20;
/// The newest seq `_acpmux/events` can be asked to read before (2^53 - 1).
const BEFORE_ANY: u64 = crate::catch_up::TAIL_BEFORE_SEQ;

/// One turn of an agent chat, as an agent tab's text shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentTurn {
    /// Who spoke ("You", the agent's name).
    pub who: String,
    pub text: String,
}

/// An agent tab's last turns (the newest [`AGENT_SCREEN_TURNS`] of `turns`)
/// as text: each speaker's name, then what they said wrapped to
/// [`AGENT_SCREEN_COLS`], each turn's share of [`MAX_AGENT_SCREEN_BYTES`]
/// cut short with an ellipsis. None when no turn has text.
pub fn agent_screen(turns: &[AgentTurn]) -> Option<String> {
    let shown: Vec<&AgentTurn> = turns.iter().filter(|t| !t.text.trim().is_empty()).collect();
    let shown = shown.get(shown.len().saturating_sub(AGENT_SCREEN_TURNS)..).unwrap_or_default();
    if shown.is_empty() {
        return None;
    }
    let share = MAX_AGENT_SCREEN_BYTES / shown.len();
    let mut out = String::new();
    for turn in shown {
        let mut block = String::new();
        block.push_str(&truncate(turn.who.trim().to_owned(), AGENT_SCREEN_COLS));
        block.push('\n');
        for line in turn.text.trim().lines() {
            for row in wrap(line.trim_end(), AGENT_SCREEN_COLS) {
                block.push_str(&row);
                block.push('\n');
            }
        }
        block.push('\n');
        if block.len() > share {
            let cut = truncate(block, share.saturating_sub('…'.len_utf8() + 2));
            block = format!("{}…\n\n", cut.trim_end());
        }
        out.push_str(&block);
    }
    Some(truncate(out.trim_end().to_owned(), MAX_AGENT_SCREEN_BYTES))
}

/// `line` in rows of at most `cols` characters, broken at a space when one is in the row.
fn wrap(line: &str, cols: usize) -> Vec<String> {
    let mut rows = Vec::new();
    let mut rest: Vec<char> = line.chars().collect();
    while rest.len() > cols {
        let at = rest.get(..=cols).and_then(|r| r.iter().rposition(|c| *c == ' ')).filter(|at| *at > 0);
        let end = at.unwrap_or(cols);
        rows.push(rest.get(..end).unwrap_or_default().iter().collect::<String>().trim_end().to_owned());
        let skip = if at.is_some() { end.saturating_add(1) } else { end };
        rest = rest.get(skip..).unwrap_or_default().to_vec();
    }
    rows.push(rest.into_iter().collect());
    rows
}

/// `text` cut to at most `cap` bytes, on a character boundary.
fn truncate(mut text: String, cap: usize) -> String {
    if text.len() > cap {
        let mut end = cap;
        while end > 0 && !text.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        text.truncate(end);
    }
    text
}

/// The acpmux session an agent tab shows, from the daemon's tab object: the
/// fields the exposure rule reads (`acpmux_policy::daemon_chat_blocked`).
pub fn agent_session(raw: &Value) -> Option<String> {
    ["/agent_session", "/conversation/agent_session", "/extra/conversation/agent_session"]
        .iter()
        .find_map(|path| {
            let agent = raw.pointer(path)?;
            agent.as_str().or_else(|| agent.get("session").and_then(Value::as_str)).map(str::to_owned)
        })
        .filter(|s| !s.is_empty())
}

/// The name an agent's turns go under: the tab object's agent, or its
/// session's harness (`claude` as "Claude"), else "Agent".
pub fn agent_name(raw: &Value) -> String {
    let name = [
        "/agent",
        "/agent_session/harness",
        "/conversation/agent_session/harness",
        "/extra/conversation/agent_session/harness",
    ]
    .iter()
    .find_map(|path| raw.pointer(path).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()));
    let Some(name) = name else { return "Agent".to_owned() };
    let mut chars = name.chars();
    chars
        .next()
        .map(|first| first.to_uppercase().chain(chars).collect())
        .unwrap_or_else(|| "Agent".to_owned())
}

/// The turns acpmux's transcript records (oldest first) hold: each person's
/// message one turn, and the agent's reply chunks after it one more (its
/// tool calls between them change no turn). Replayed records are skipped.
pub fn turns_of(records: &[Value], agent: &str) -> Vec<AgentTurn> {
    let mut turns: Vec<AgentTurn> = Vec::new();
    for record in records {
        let dir = record.get("dir").and_then(Value::as_str).unwrap_or("");
        let kind = record.get("kind").and_then(Value::as_str).unwrap_or("");
        let msg = record.get("msg").unwrap_or(&Value::Null);
        if dir == "mux" && kind == "user_message" {
            let text = msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned();
            turns.push(AgentTurn { who: "You".into(), text });
        } else if dir == "in"
            && !kind.ends_with(".replay")
            && msg.get("method").and_then(Value::as_str) == Some("session/update")
            && msg.pointer("/params/update/sessionUpdate").and_then(Value::as_str)
                == Some("agent_message_chunk")
        {
            let chunk = text_of(msg.pointer("/params/update/content").unwrap_or(&Value::Null));
            match turns.last_mut() {
                Some(turn) if turn.who != "You" => turn.text.push_str(&chunk),
                _ => turns.push(AgentTurn { who: agent.to_owned(), text: chunk }),
            }
        }
    }
    turns
}

/// The text of an ACP content block (or a list of them).
fn text_of(content: &Value) -> String {
    match content {
        Value::Array(items) => items.iter().map(text_of).collect(),
        Value::Object(o) => match (o.get("text").and_then(Value::as_str), o.get("content")) {
            (Some(text), _) => text.to_owned(),
            (None, Some(inner)) => text_of(inner),
            _ => String::new(),
        },
        Value::String(text) => text.clone(),
        _ => String::new(),
    }
}

/// The seq of the newest record in an `_acpmux/events` page, 0 for none.
fn newest_seq(page: &Value) -> u64 {
    page.get("events")
        .and_then(Value::as_array)
        .and_then(|events| events.iter().filter_map(|e| e.get("seq").and_then(Value::as_u64)).max())
        .unwrap_or(0)
}

/// The agent tabs' reads in flight and the newest record each session's
/// capture was made from, shared by one feeder pass.
#[derive(Default)]
pub(crate) struct AgentReads {
    inflight: Mutex<HashSet<String>>,
    seen: Mutex<HashMap<String, u64>>,
}

impl AgentReads {
    /// Reads tab `tab_id`'s chat `session` again, off the feeder's loop (a
    /// slow acpmux never holds the terminals' screens). One read per tab at a
    /// time; the tail is read only when the log has a newer record than the
    /// last capture's. A read that fails sets nothing: the last capture stays.
    pub(crate) fn spawn(
        self: &Arc<Self>,
        tabs: &Arc<Tabs>,
        target: AcpmuxTarget,
        tab_id: String,
        session: String,
        agent: String,
    ) {
        if !self.inflight.lock().unwrap_or_else(PoisonError::into_inner).insert(tab_id.clone()) {
            return;
        }
        let (reads, tabs) = (Arc::clone(self), Arc::clone(tabs));
        tokio::spawn(async move {
            reads.read(&tabs, &target, &tab_id, &session, &agent).await;
            reads.inflight.lock().unwrap_or_else(PoisonError::into_inner).remove(&tab_id);
        });
    }

    async fn read(&self, tabs: &Tabs, target: &AcpmuxTarget, tab_id: &str, session: &str, agent: &str) {
        let page = |limit: usize, bytes: usize| {
            json!({"sessionId": session, "limit": limit, "kinds": ["transcript"], "maxBytes": bytes,
                   "beforeSeq": BEFORE_ANY})
        };
        let Some(probe) =
            crate::services::trusted_session_query(target, "_acpmux/events", page(1, 64 << 10)).await
        else {
            return;
        };
        let newest = newest_seq(&probe);
        if self.seen.lock().unwrap_or_else(PoisonError::into_inner).get(session) == Some(&newest) {
            return;
        }
        let Some(tail) =
            crate::services::trusted_session_query(target, "_acpmux/events", page(TAIL_RECORDS, TAIL_BYTES))
                .await
        else {
            return;
        };
        let records = tail.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let Some(text) = agent_screen(&turns_of(&records, agent)) else { return };
        if tabs.set_screen(tab_id, text) || tabs.has_screen(tab_id) {
            self.seen
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(session.to_owned(), newest_seq(&tail));
        }
    }
}

#[cfg(test)]
#[path = "tab_agent_screen_tests.rs"]
mod tests;
