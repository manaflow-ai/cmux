//! The host's durable state, its only writer being the host. Each entry is
//! a to-do whose effect an owner dedupes (the conversation owner by
//! idempotency key), so a lost write costs a replay, never a duplicate reply.
//!
//! Since 2026-10-06 it lives in the `state` table of the Chief home's memory
//! database (`$MUX_HOME/optchat/memory.sqlite3`), one row per top-level
//! field (`host/<field>`, its JSON value), next to the log it describes, so
//! the brain can move it in the same transaction as the messages it logs
//! (`OptChat::append_with`). The old `host.json` is read into the database
//! once (see `StateFile::attach`).

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use cmux_conversation::Op;
use optchat_host::{OptChat, StateWrite};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The prefix of the host state's keys in the `state` table.
pub const HOST_PREFIX: &str = "host/";
/// The prefix of the fold positions (`fold/<acpmux session id>`): the last
/// event seq of a turn session already in the log, written in the same
/// transaction as the entries folded from it.
pub const FOLD_PREFIX: &str = "fold/";

/// The state key of a session's fold position.
pub fn fold_key(session: &str) -> String {
    format!("{FOLD_PREFIX}{session}")
}

/// The write that records `after` as `session`'s fold position.
pub fn fold_write(session: &str, after: u64) -> StateWrite {
    (fold_key(session), Some(after.to_string()))
}

/// How far `session`'s events are in the log (0: none recorded).
pub fn folded(chat: &OptChat, session: &str) -> u64 {
    chat.state(&fold_key(session))
        .ok()
        .flatten()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HostState {
    /// The Chief conversation (from conversation-create).
    #[serde(default)]
    pub conversation: Option<String>,
    /// Highest conversation seq whose waking message is in the OptChat log
    /// (or which needed none). The read cursor follows it, so a message is
    /// logged once even across restarts.
    #[serde(default)]
    pub logged_seq: u64,
    /// Conversation ops not yet confirmed by the owner, in order.
    #[serde(default)]
    pub outbox: Vec<OutboxEntry>,
    /// The turn whose messages are logged but whose reply is not posted yet.
    #[serde(default)]
    pub turn: Option<PendingTurn>,
    /// Child sessions (acpmux session id) the Chief started.
    #[serde(default)]
    pub children: BTreeMap<String, ChildRecord>,
    /// Turn sessions whose connection was lost mid-turn: folded and removed
    /// at the next acpmux connect.
    #[serde(default)]
    pub orphans: Vec<crate::turn::Orphan>,
    /// Section 9: each `spawn` call and its subagents, by spawn id.
    #[serde(default)]
    pub spawns: BTreeMap<String, SpawnRecord>,
    /// The number of the next subagent id (`a<N>`), unique for this home.
    #[serde(default)]
    pub next_subagent: u64,
    /// The engine the last turn ran on (`TurnEngine::describe`): a change
    /// is logged as a note.
    #[serde(default)]
    pub engine: Option<String>,
    /// Logged turn images whose description note is not written yet: the
    /// next connect reads them from the owner again and describes them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub undescribed: Vec<crate::brain::images::ImageRef>,
    /// G9: the floor of each side conversation (not the main one) the
    /// chief's wake queue woke, by conversation id.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub side: BTreeMap<String, SideFloor>,
}

/// A side conversation's floor is dropped after this many days without a
/// wake (its conversation is quiet or gone; a later wake starts a new floor
/// at that wake).
pub const FLOOR_RETENTION_DAYS: u64 = 30;

/// How many handled message ids a side floor keeps (crash dedupe by id).
pub const FLOOR_IDS: usize = 64;

/// A side conversation's saved floor: every message at or below `seq` (or
/// with an id in `ids`) is in the OptChat log or needed none, so a wake
/// repeated after a crash never logs or answers it twice. It moves in the
/// same transaction as the messages it covers.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SideFloor {
    /// Highest seq handled.
    pub seq: u64,
    /// The ids of the last handled messages, newest last (at most `FLOOR_IDS`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ids: Vec<String>,
    /// When the last wake for this conversation arrived (ms since the epoch).
    #[serde(default)]
    pub touched_ms: u64,
}

impl SideFloor {
    /// Records a handled message.
    pub fn handled(&mut self, seq: u64, id: &str) {
        self.seq = self.seq.max(seq);
        if !id.is_empty() && !self.ids.iter().any(|i| i == id) {
            self.ids.push(id.to_owned());
            let extra = self.ids.len().saturating_sub(FLOOR_IDS);
            self.ids.drain(..extra);
        }
    }
}

/// One `spawn(tasks)` call (section 9): each subagent reports as it finishes.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnRecord {
    pub subs: Vec<SubRecord>,
    /// A report of this spawn is in the log.
    #[serde(default)]
    pub delivered: bool,
    /// When the spawn was made (ms since the epoch).
    #[serde(default)]
    pub started_ms: u64,
    /// The turn that spawned it (its reply key), for the trace.
    #[serde(default)]
    pub turn: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubStatus {
    /// Its session is being created.
    #[default]
    Starting,
    /// It waits for a free slot (`subagents::MAX_LIVE` run at once).
    Queued,
    /// A turn runs, or one ended and was not read yet.
    Running,
    /// It ended a turn; `report` holds its last reply, not logged yet.
    Done,
    /// Its last report is in the log.
    Reported,
}

/// One subagent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubRecord {
    /// `a<N>`: what the Chief calls it (`tell`, `[id] report`).
    pub id: String,
    /// Its acpmux session, once created.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Its cmux workspace, once created.
    #[serde(default)]
    pub workspace: Option<String>,
    pub status: SubStatus,
    /// The report waiting for the log.
    #[serde(default)]
    pub report: Option<String>,
    /// The waiting report is of a run the user stopped: it starts no turn.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stopped: bool,
    /// The session's event seq at its last read turn end.
    #[serde(default)]
    pub floor: u64,
    /// When its current run began (ms since the epoch), for the trace.
    #[serde(default)]
    pub run_ms: u64,
    /// The task's first characters (the workspace title).
    #[serde(default)]
    pub title: String,
    /// `ask` when it was spawned under the spawn floor (a remote-origin turn
    /// or a live ask child): a person answers its permission requests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OutboxEntry {
    pub conversation: String,
    pub idempotency_key: String,
    pub op: Op,
    /// Set after one retry of an `agent_rate` reject.
    #[serde(default)]
    pub rate_retried: bool,
    /// Not sent before this time (ms since the epoch); set with `rate_retried`.
    #[serde(default)]
    pub not_before: Option<u64>,
    /// Sent to the owner at least once: its key's content is fixed (never coalesced).
    #[serde(default)]
    pub attempted: bool,
    /// `agent_rate` refusals so far; the backoff grows with them (G11).
    #[serde(default)]
    pub rate_attempts: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingTurn {
    /// The reply's idempotency key and client_msg_id. Empty while the turn's
    /// messages are being logged (the key needs the first one's stamp).
    pub key: String,
    pub conversation: Option<String>,
    /// The turn's acpmux session name.
    pub session: String,
    /// The turn's acpmux session id, once the worker created it: a host that
    /// stops mid-turn folds what the session did since `after` at the next
    /// start (section 7: everything the agent does is logged), instead of
    /// killing it unread.
    #[serde(default)]
    pub session_id: Option<String>,
    /// The last event seq of the session already folded into the log.
    #[serde(default)]
    pub after: u64,
    /// The log length before the turn's messages were appended. Saved before
    /// the first append, so a restart can tell which of them reached the log
    /// and never logs one twice.
    #[serde(default)]
    pub first_id: Option<u64>,
    /// Hosts before audit round 2 saved only each item's conversation seq;
    /// read when `items` is empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub seqs: Vec<Option<u64>>,
    /// Where each item the turn started with came from, in log order.
    #[serde(default)]
    pub items: Vec<Item>,
    /// Items delivered between tool calls (section 7), each batch logged at
    /// its own position.
    #[serde(default)]
    pub mid: Vec<Batch>,
}

impl PendingTurn {
    /// The items the turn started with (the old `seqs` form included).
    pub fn opening(&self) -> Vec<Item> {
        if !self.items.is_empty() {
            return self.items.clone();
        }
        self.seqs
            .iter()
            .map(|seq| Item {
                seq: *seq,
                ..Item::default()
            })
            .collect()
    }
}

/// One logged item's source, so a restart can finish its bookkeeping: a
/// human message moves the read cursor, a child's report marks the child
/// reported (else reconcile would queue the same report again).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    /// The conversation seq of a human message.
    #[serde(default)]
    pub seq: Option<u64>,
    /// A child's report.
    #[serde(default)]
    pub child: Option<ChildRef>,
    /// Subagents' reports (section 9): the spawn and each subagent's floor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn: Option<SpawnRef>,
    /// The human message's images (never their bytes): the pending turn
    /// keeps them so a restart can still describe them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<crate::brain::images::ImageRef>,
    /// The side conversation of a human message (None: the main one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    /// The human message's id (a side floor's crash dedupe).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnRef {
    pub spawn: String,
    /// (subagent id, its floor once this report is logged).
    pub subs: Vec<(String, u64)>,
    /// The user stopped the subagent: its report is logged with the next
    /// turn and starts none (the reference client's stopped report).
    #[serde(default)]
    pub quiet: bool,
}

impl HostState {
    /// Marks the subagents of a logged report reported.
    pub fn spawn_logged(&mut self, r: &SpawnRef) {
        if let Some(record) = self.spawns.get_mut(&r.spawn) {
            record.delivered = true;
            for (id, floor) in &r.subs {
                if let Some(sub) = record.subs.iter_mut().find(|s| &s.id == id)
                    && sub.status == SubStatus::Done
                {
                    sub.status = SubStatus::Reported;
                    sub.report = None;
                    sub.stopped = false;
                    sub.floor = *floor;
                }
            }
        }
    }

    /// The subagent `id` and its spawn id.
    pub fn sub(&self, id: &str) -> Option<(&String, &SubRecord)> {
        self.spawns
            .iter()
            .find_map(|(k, r)| r.subs.iter().find(|s| s.id == id).map(|s| (k, s)))
    }

    pub fn sub_mut(&mut self, id: &str) -> Option<&mut SubRecord> {
        self.spawns
            .values_mut()
            .find_map(|r| r.subs.iter_mut().find(|s| s.id == id))
    }

    /// The subagent whose session is `session_id`.
    pub fn sub_by_session(&self, session_id: &str) -> Option<String> {
        self.spawns.values().find_map(|r| {
            r.subs
                .iter()
                .find(|s| s.session_id.as_deref() == Some(session_id))
                .map(|s| s.id.clone())
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChildRef {
    pub session_id: String,
    /// The child's floor once this report is logged.
    pub floor: u64,
}

/// Items logged together between two tool calls of a running turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Batch {
    /// The log length before the batch's first append.
    pub at: u64,
    pub items: Vec<Item>,
    /// Every item is in the log.
    #[serde(default)]
    pub done: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChildStatus {
    /// A turn runs, or ended and its report is not in the log yet.
    Running,
    /// Its last report is in the log.
    Reported,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChildRecord {
    pub name: String,
    pub status: ChildStatus,
    /// The session's event seq at its previous turn end: the next report is
    /// folded from the events after it.
    #[serde(default)]
    pub floor: u64,
}

/// Where `HostState` is kept. Attached to a chat (`attach`, which the brain
/// does), it is the chat database's `state` table; before that, `path` is
/// the old `host.json`: `save` writes it (tests use that to build an old
/// home) and `attach` imports it once.
pub struct StateFile {
    path: PathBuf,
    chat: Option<Arc<OptChat>>,
    /// The JSON of each stored field, as last committed: `writes` sends only
    /// the fields that changed.
    saved: Mutex<BTreeMap<String, String>>,
}

impl std::fmt::Debug for StateFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StateFile")
            .field("path", &self.path)
            .field("attached", &self.chat.is_some())
            .finish()
    }
}

/// The state's fields as `(host/<field>, JSON)`.
fn fields(state: &HostState) -> BTreeMap<String, String> {
    match serde_json::to_value(state) {
        Ok(Value::Object(map)) => map
            .into_iter()
            .map(|(k, v)| (format!("{HOST_PREFIX}{k}"), v.to_string()))
            .collect(),
        _ => BTreeMap::new(),
    }
}

impl StateFile {
    pub fn new(path: &Path) -> StateFile {
        StateFile {
            path: path.to_owned(),
            chat: None,
            saved: Mutex::new(BTreeMap::new()),
        }
    }

    /// Keeps the state in `chat`'s database from now on. A database with no
    /// host state yet takes the old `host.json` (when there is one) in one
    /// transaction, and the file is renamed `host.json.imported`; a later
    /// start finds the state in the database and leaves any file alone.
    pub fn attach(mut self, chat: Arc<OptChat>) -> StateFile {
        let rows = match chat.state_prefix(HOST_PREFIX) {
            Ok(rows) => rows,
            Err(e) => {
                crate::log::log(format!(
                    "reading the host state: {e}; starting from it empty"
                ));
                Vec::new()
            }
        };
        let mut saved: BTreeMap<String, String> = rows.into_iter().collect();
        if saved.is_empty() && self.path.exists() {
            let old = self.load_json();
            let writes: Vec<StateWrite> = fields(&old)
                .into_iter()
                .map(|(k, v)| (k, Some(v)))
                .collect();
            match chat.put_state(&writes) {
                Ok(()) => {
                    saved = writes
                        .into_iter()
                        .filter_map(|(k, v)| Some((k, v?)))
                        .collect();
                    let kept = self.path.with_extension("json.imported");
                    if let Err(e) = std::fs::rename(&self.path, &kept) {
                        crate::log::log(format!("renaming {}: {e}", self.path.display()));
                    }
                    crate::log::log(format!(
                        "moved the host state from {} into the memory database",
                        self.path.display()
                    ));
                }
                Err(e) => crate::log::log(format!(
                    "moving {} into the memory database failed: {e}",
                    self.path.display()
                )),
            }
        }
        self.saved = Mutex::new(saved);
        self.chat = Some(chat);
        self
    }

    /// The saved state; nothing saved is the empty state, an unreadable
    /// field is reported and the state starts empty (every entry is
    /// replayable).
    pub fn load(&self) -> HostState {
        if self.chat.is_none() {
            return self.load_json();
        }
        let saved = self
            .saved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut object = serde_json::Map::new();
        for (k, v) in saved.iter() {
            let Some(field) = k.strip_prefix(HOST_PREFIX) else {
                continue;
            };
            match serde_json::from_str::<Value>(v) {
                Ok(value) => {
                    object.insert(field.to_owned(), value);
                }
                Err(e) => crate::log::log(format!("host state field {field} is unreadable ({e})")),
            }
        }
        serde_json::from_value(Value::Object(object)).unwrap_or_else(|e| {
            crate::log::log(format!(
                "the host state is unreadable ({e}); starting from an empty state"
            ));
            HostState::default()
        })
    }

    /// The writes that bring the stored state to `state`: changed fields
    /// only, removed ones deleted. Pure; `committed` records them once the
    /// caller's transaction is in.
    pub fn writes(&self, state: &HostState) -> Vec<StateWrite> {
        let saved = self
            .saved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = fields(state);
        let mut out: Vec<StateWrite> = now
            .iter()
            .filter(|(k, v)| saved.get(*k) != Some(*v))
            .map(|(k, v)| (k.clone(), Some(v.clone())))
            .collect();
        out.extend(
            saved
                .keys()
                .filter(|k| !now.contains_key(*k))
                .map(|k| (k.clone(), None)),
        );
        out
    }

    /// `writes` reached the database.
    pub fn committed(&self, writes: &[StateWrite]) {
        let mut saved = self
            .saved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for (k, v) in writes {
            if !k.starts_with(HOST_PREFIX) {
                continue;
            }
            match v {
                Some(v) => saved.insert(k.clone(), v.clone()),
                None => saved.remove(k),
            };
        }
    }

    /// Saves `state` (and `extra` writes, such as fold positions) in one
    /// transaction; before `attach`, writes the old `host.json`.
    pub fn save_with(&self, state: &HostState, extra: Vec<StateWrite>) -> io::Result<()> {
        let Some(chat) = &self.chat else {
            return self.save_json(state);
        };
        let mut writes = self.writes(state);
        writes.extend(extra);
        if writes.is_empty() {
            return Ok(());
        }
        chat.put_state(&writes).map_err(io::Error::other)?;
        self.committed(&writes);
        Ok(())
    }

    pub fn save(&self, state: &HostState) -> io::Result<()> {
        self.save_with(state, Vec::new())
    }

    fn load_json(&self) -> HostState {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                crate::log::log(format!(
                    "{} is unreadable ({e}); starting from an empty state",
                    self.path.display()
                ));
                HostState::default()
            }),
            Err(e) if e.kind() == io::ErrorKind::NotFound => HostState::default(),
            Err(e) => {
                crate::log::log(format!(
                    "reading {}: {e}; starting from an empty state",
                    self.path.display()
                ));
                HostState::default()
            }
        }
    }

    /// The old format: through a temporary file (0600), fsynced, renamed
    /// into place, the directory fsynced.
    fn save_json(&self, state: &HostState) -> io::Result<()> {
        let tmp = self
            .path
            .with_extension(format!("json.{}.tmp", std::process::id()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&serde_json::to_vec(state).map_err(io::Error::other)?)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&tmp, &self.path)?;
        if let Some(dir) = self.path.parent() {
            std::fs::File::open(dir)?.sync_all()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::Part;

    #[test]
    fn state_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let file = StateFile::new(&dir.path().join("host.json"));
        assert_eq!(file.load(), HostState::default());
        let mut state = HostState {
            conversation: Some("conv_a".into()),
            logged_seq: 4,
            ..Default::default()
        };
        state.outbox.push(OutboxEntry {
            conversation: "conv_a".into(),
            idempotency_key: "turn:optchat:3".into(),
            op: Op::MessageSend {
                client_msg_id: "turn:optchat:3".into(),
                parts: vec![Part::Text {
                    text: "hi".into(),
                    runs: None,
                }],
                reply_to: None,
            },
            rate_retried: false,
            not_before: None,
            attempted: false,
            rate_attempts: 0,
        });
        file.save(&state).unwrap();
        assert_eq!(file.load(), state);
        std::fs::write(dir.path().join("host.json"), b"{torn").unwrap();
        assert_eq!(file.load(), HostState::default());
    }
}
