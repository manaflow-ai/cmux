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
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use crate::config::AcpmuxTarget;
use crate::tab_snapshots::Tabs;

/// The most an agent tab's text of its last turns holds ([`agent_screen`]).
pub const MAX_AGENT_SCREEN_BYTES: usize = 4 << 10;
/// The turns an agent tab's text shows, newest last.
pub const AGENT_SCREEN_TURNS: usize = 3;
/// The width an agent tab's text is laid out to, in characters.
pub const AGENT_SCREEN_COLS: usize = 80;
/// An agent tab's log is looked at again at least this often.
pub(crate) const AGENT_INTERVAL: Duration = Duration::from_secs(5);
/// A tab a daemon event named is looked at again at most this often.
pub(crate) const AGENT_EVENT_INTERVAL: Duration = Duration::from_secs(1);
/// A captured tab whose log is not on this disk (another Mac's chat, an acpmux
/// known only by its address) is asked again at most this often unless an event names it.
pub(crate) const AGENT_UNSTAMPED_INTERVAL: Duration = Duration::from_secs(60);
/// The agent tabs' reads one feeder runs at once; the rest wait their turn.
pub(crate) const MAX_CONCURRENT_READS: usize = 4;
/// The newest records read for the last turns.
const TAIL_RECORDS: usize = 512;
/// The most JSON that page may hold: three turns' text is at most 4 KiB, the
/// rest of the page is the tool calls between them.
const TAIL_BYTES: usize = 256 << 10;
/// The most JSON the one-record probe of the newest transcript seq may hold.
const PROBE_BYTES: usize = 64 << 10;
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

/// The folder acpmux keeps its chats' logs in on this Mac
/// (`<ACPMUX_HOME>/sessions/<id>/events/NNNNNN.ndjson`), where a stat tells
/// whether a chat's log moved with no query. None for an acpmux only known by
/// its address (a URL, or an app that named no home): every look is a probe query then.
pub(crate) fn sessions_root(target: &AcpmuxTarget) -> Option<PathBuf> {
    match target {
        AcpmuxTarget::Home(home) => Some(home.join("sessions")),
        // The app names its acpmux's home (`MobileHostLaunch.acpmuxHome`); never a
        // guess: a build other than NIGHTLY keeps its chats under `~/.acpmux/builds/<key>`.
        AcpmuxTarget::Supplied(_) => std::env::var_os("CMUX_MOBILE_ACPMUX_HOME")
            .filter(|home| !home.is_empty())
            .map(|home| PathBuf::from(home).join("sessions")),
        AcpmuxTarget::Fixed { .. } => None,
    }
}

/// What a stat of a chat's log says, compared from one look to the next: a
/// record appended grows the newest segment, a new segment or one sealed
/// changes the folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum LogStamp {
    /// The chat's folder holds no live log (none yet, or archived cold).
    NoLog,
    Segment { folder: Option<SystemTime>, path: PathBuf, len: u64, modified: Option<SystemTime> },
}

/// The stamp of chat `session`'s log under `root`: two stats when the log's
/// folder did not change since `last`, a listing of it when it did. None when
/// the chat has no folder here (another home, an alias): it is probed over
/// acpmux instead.
pub(crate) fn log_stamp(root: &Path, session: &str, last: Option<&LogStamp>) -> Option<LogStamp> {
    if session.is_empty() || session == "." || session == ".." || session.contains(['/', '\\']) {
        return None;
    }
    let chat = root.join(session);
    let events = chat.join("events");
    let Ok(folder) = std::fs::metadata(&events) else {
        return std::fs::metadata(&chat).is_ok_and(|m| m.is_dir()).then_some(LogStamp::NoLog);
    };
    let folder = folder.modified().ok();
    let stamp = |path: PathBuf| {
        let meta = std::fs::metadata(&path).ok()?;
        Some(LogStamp::Segment { folder, path, len: meta.len(), modified: meta.modified().ok() })
    };
    if let Some(LogStamp::Segment { folder: was, path, .. }) = last
        && *was == folder
        && let Some(same) = stamp(path.clone())
    {
        return Some(same);
    }
    Some(newest_segment(&events).and_then(stamp).unwrap_or(LogStamp::NoLog))
}

/// The newest of a log's segments (`NNNNNN.ndjson`, named in order).
fn newest_segment(events: &Path) -> Option<PathBuf> {
    std::fs::read_dir(events)
        .ok()?
        .flatten()
        .map(|entry| entry.file_name())
        .filter(|name| name.to_str().is_some_and(|n| n.ends_with(".ndjson")))
        .max()
        .map(|name| events.join(name))
}

/// One read [`AgentSchedule::due`] asks for: the tab, its chat, its agent's
/// name, and the stamp its log had when the read was asked for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AgentRead {
    pub tab_id: String,
    pub session: String,
    pub agent: String,
    pub stamp: Option<LogStamp>,
}

/// When each agent tab's log is looked at, for one feeder pass. A look is a
/// stat; only a log that moved since its tab's capture is read (a query).
#[derive(Default)]
pub(crate) struct AgentSchedule {
    /// By tab: the chat it shows and its agent's name.
    agents: HashMap<String, (String, String)>,
    /// By tab: when its log was last looked at.
    looked: HashMap<String, Instant>,
    /// By tab: the stamp that look saw (so the next one is two stats).
    observed: HashMap<String, LogStamp>,
    /// Tabs a daemon event named since their last look.
    named: HashSet<String>,
    /// By tab whose log has no stamp: when it was last asked for.
    asked: HashMap<String, Instant>,
}

impl AgentSchedule {
    /// The agent tabs listed now: a new one is looked at on the next tick.
    pub(crate) fn listed(&mut self, agents: HashMap<String, (String, String)>, reads: &AgentReads) {
        self.agents = agents;
        let listed = |id: &String| self.agents.contains_key(id);
        self.looked.retain(|id, _| listed(id));
        self.observed.retain(|id, _| listed(id));
        self.named.retain(|id| listed(id));
        self.asked.retain(|id, _| listed(id));
        reads.retain(&self.agents);
    }

    /// A daemon event named `tab_id`: it is looked at within [`AGENT_EVENT_INTERVAL`].
    pub(crate) fn named(&mut self, tab_id: &str) {
        if self.agents.contains_key(tab_id) {
            self.named.insert(tab_id.to_owned());
        }
    }

    /// The reads due at `now`. A tab is looked at when it was never looked at,
    /// [`AGENT_INTERVAL`] after its last look, or [`AGENT_EVENT_INTERVAL`]
    /// after it when an event named it; a look under `root` that finds its log
    /// as its capture saw it asks for nothing. So idle tabs cost two stats
    /// each per [`AGENT_INTERVAL`] and no query, whatever their number. A
    /// captured tab with no stamp is asked again only when an event names it
    /// or every [`AGENT_UNSTAMPED_INTERVAL`].
    pub(crate) fn due(&mut self, now: Instant, root: Option<&Path>, reads: &AgentReads) -> Vec<AgentRead> {
        let mut due = Vec::new();
        for (id, (session, agent)) in &self.agents {
            let since = self.looked.get(id).map(|at| now.saturating_duration_since(*at));
            let named = self.named.contains(id);
            let look = since.is_none_or(|since| {
                since >= AGENT_INTERVAL || (since >= AGENT_EVENT_INTERVAL && named)
            });
            if !look {
                continue;
            }
            self.named.remove(id);
            self.looked.insert(id.clone(), now);
            let stamp = root.and_then(|root| log_stamp(root, session, self.observed.get(id)));
            match &stamp {
                Some(stamp) => {
                    self.observed.insert(id.clone(), stamp.clone());
                    if reads.captured_at(id).as_ref() == Some(stamp) {
                        continue;
                    }
                }
                None => {
                    let recent = self
                        .asked
                        .get(id)
                        .is_some_and(|at| now.saturating_duration_since(*at) < AGENT_UNSTAMPED_INTERVAL);
                    if !named && recent && reads.captured(id) {
                        continue;
                    }
                    self.asked.insert(id.clone(), now);
                }
            }
            due.push(AgentRead { tab_id: id.clone(), session: session.clone(), agent: agent.clone(), stamp });
        }
        due
    }
}

/// A tab's last capture: the newest transcript seq and the log stamp it was made from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Capture {
    seq: u64,
    stamp: Option<LogStamp>,
}

/// The agent tabs' reads in flight and the capture each tab's text was made
/// from, shared by one feeder pass. Keyed by tab, not chat: two tabs on one
/// chat each get its text.
pub(crate) struct AgentReads {
    inflight: Mutex<HashSet<String>>,
    captures: Mutex<HashMap<String, Capture>>,
    permits: Semaphore,
}

impl Default for AgentReads {
    fn default() -> Self {
        Self {
            inflight: Mutex::default(),
            captures: Mutex::default(),
            permits: Semaphore::new(MAX_CONCURRENT_READS),
        }
    }
}

/// Takes a tab out of the reads in flight when its read ends, however it ends
/// (done, failed, aborted with the feeder, panicked).
struct Inflight<'a> {
    reads: &'a AgentReads,
    tab_id: &'a str,
}

impl Drop for Inflight<'_> {
    fn drop(&mut self) {
        self.reads.inflight.lock().unwrap_or_else(PoisonError::into_inner).remove(self.tab_id);
    }
}

impl AgentReads {
    /// The stamp tab `tab_id`'s capture was made from.
    fn captured_at(&self, tab_id: &str) -> Option<LogStamp> {
        self.captures.lock().unwrap_or_else(PoisonError::into_inner).get(tab_id).and_then(|c| c.stamp.clone())
    }

    /// Whether tab `tab_id` has a capture.
    fn captured(&self, tab_id: &str) -> bool {
        self.captures.lock().unwrap_or_else(PoisonError::into_inner).contains_key(tab_id)
    }

    /// Whether tab `tab_id`'s capture was made from transcript seq `newest`.
    fn fresh(&self, tab_id: &str, newest: u64) -> bool {
        self.captures.lock().unwrap_or_else(PoisonError::into_inner).get(tab_id).is_some_and(|c| c.seq == newest)
    }

    fn record(&self, tab_id: &str, seq: u64, stamp: Option<LogStamp>) {
        self.captures
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(tab_id.to_owned(), Capture { seq, stamp });
    }

    /// Forgets the captures of tabs no longer listed.
    fn retain(&self, agents: &HashMap<String, (String, String)>) {
        self.captures.lock().unwrap_or_else(PoisonError::into_inner).retain(|id, _| agents.contains_key(id));
    }

    /// Reads `read`'s chat again in `tasks`, off the feeder's loop (a slow
    /// acpmux never holds the terminals' screens). The feeder owns `tasks`, so
    /// its reads end with it. One read per tab at a time, at most
    /// [`MAX_CONCURRENT_READS`] at once; the tail is read only when the log
    /// has a newer transcript record than the tab's capture. A read that fails
    /// sets nothing: the last capture stays.
    pub(crate) fn spawn(self: &Arc<Self>, tasks: &mut JoinSet<()>, tabs: &Arc<Tabs>, target: AcpmuxTarget, read: AgentRead) {
        if !self.inflight.lock().unwrap_or_else(PoisonError::into_inner).insert(read.tab_id.clone()) {
            return;
        }
        let (reads, tabs) = (Arc::clone(self), Arc::clone(tabs));
        tasks.spawn(async move {
            let _inflight = Inflight { reads: &reads, tab_id: &read.tab_id };
            let Ok(_permit) = reads.permits.acquire().await else { return };
            reads.read(&tabs, &target, read.clone()).await;
        });
    }

    async fn read(&self, tabs: &Tabs, target: &AcpmuxTarget, read: AgentRead) {
        let AgentRead { tab_id, session, agent, stamp } = read;
        let page = |limit: usize, bytes: usize| {
            json!({"sessionId": session, "limit": limit, "kinds": ["transcript"], "maxBytes": bytes,
                   "beforeSeq": BEFORE_ANY})
        };
        let Some(probe) =
            crate::services::trusted_session_query(target, "_acpmux/events", page(1, PROBE_BYTES)).await
        else {
            return;
        };
        let newest = newest_seq(&probe);
        if self.fresh(&tab_id, newest) {
            // The log moved by records the text does not show: the next look
            // compares with this stamp.
            self.record(&tab_id, newest, stamp);
            return;
        }
        let Some(tail) =
            crate::services::trusted_session_query(target, "_acpmux/events", page(TAIL_RECORDS, TAIL_BYTES))
                .await
        else {
            return;
        };
        let records = tail.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let Some(text) = agent_screen(&turns_of(&records, &agent)) else {
            // Nothing said yet: read again only once the log moves.
            self.record(&tab_id, newest_seq(&tail), stamp);
            return;
        };
        if tabs.set_screen(&tab_id, text) || tabs.has_screen(&tab_id) {
            self.record(&tab_id, newest_seq(&tail), stamp);
        }
    }
}

#[cfg(test)]
#[path = "tab_agent_screen_tests.rs"]
mod tests;
