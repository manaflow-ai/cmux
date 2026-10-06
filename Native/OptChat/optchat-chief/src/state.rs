//! The host's durable state (`$MUX_HOME/optchat/host.json`), its only writer
//! being the host. Each entry is a to-do whose effect an owner dedupes (the
//! conversation owner by idempotency key), so a lost write costs a replay,
//! never a duplicate reply.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use cmux_conversation::Op;
use serde::{Deserialize, Serialize};

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
    /// Logged turn images whose description note is not written yet: the
    /// next connect reads them from the owner again and describes them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub undescribed: Vec<crate::brain::images::ImageRef>,
}

/// One `spawn(tasks)` call (section 9): its subagents report together.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnRecord {
    pub subs: Vec<SubRecord>,
    /// The combined report is in the log; later reports come one by one.
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
    /// The session's event seq at its last read turn end.
    #[serde(default)]
    pub floor: u64,
    /// When its current run began (ms since the epoch), for the trace.
    #[serde(default)]
    pub run_ms: u64,
    /// The task's first characters (the workspace title).
    #[serde(default)]
    pub title: String,
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
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnRef {
    pub spawn: String,
    /// (subagent id, its floor once this report is logged).
    pub subs: Vec<(String, u64)>,
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

/// The file behind `HostState`.
#[derive(Clone, Debug)]
pub struct StateFile {
    path: PathBuf,
}

impl StateFile {
    pub fn new(path: &Path) -> StateFile {
        StateFile {
            path: path.to_owned(),
        }
    }

    /// The saved state; a missing file is the empty state, an unreadable one
    /// is reported and replaced (every entry is replayable).
    pub fn load(&self) -> HostState {
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

    /// Writes through a temporary file (mode 0600: it holds the outbox,
    /// replies included), fsyncs it, renames it into place, then fsyncs the
    /// directory so the rename itself survives a power loss.
    pub fn save(&self, state: &HostState) -> io::Result<()> {
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
        });
        file.save(&state).unwrap();
        assert_eq!(file.load(), state);
        std::fs::write(dir.path().join("host.json"), b"{torn").unwrap();
        assert_eq!(file.load(), HostState::default());
    }
}
