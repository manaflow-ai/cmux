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
    /// The turn session kept for the next turn (`Settings::keep_turn_session`):
    /// a host that restarts ends it (it knows nothing of its history).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kept_session: Option<String>,
    /// E22: what the last turn answered (message ids): a spawn made after
    /// that turn's end still belongs to it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub last_answers: Vec<String>,
    /// E22: what a turn stopped for a newer message answered: the next turn
    /// answers it too.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub carry_answers: Vec<String>,
    /// The Chief conversation's person messages that no posted reply has
    /// answered yet (brain/reply_ledger.rs, user 2026-10-21: "the Chief never
    /// forgets to respond"). Kept across restarts; a message leaves only when
    /// a reply posts, the owner stops its turn, or the failure note posts.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub awaiting: Vec<Awaiting>,
    /// E22: ids a posted reply named in `answers_pending`: the turn that
    /// ends their work answers them even when it says nothing (a done
    /// marker), so a waiting `cmux chief -p` ends.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub open_answers: Vec<String>,
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
    /// `control cap N`: the live cap set at run time (0: no cap); None: the
    /// env's (`OPTCHAT_MAX_LIVE_SUBAGENTS`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live_cap: Option<usize>,
    /// `control cloud PEER|off`: the acpmux peer subagents run on by
    /// default, set at run time (empty: off, local); None: the env's
    /// (`OPTCHAT_SUBAGENT_PEER`). plans/cmux-next/cloud-subagents-DESIGN.md.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud_peer: Option<String>,
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
    /// Turns a host stop cut after their human messages were logged: each
    /// runs again as one resume turn (E23, the reference client's `resume`),
    /// cleared when its note is logged.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub resumes: Vec<Resume>,
    /// The view up to and including the last turn's marked block, by size
    /// and hash (`optchat_core::mark_piece`): saved with that turn's
    /// messages, so the first turn after a restart still marks within the
    /// API's lookback of it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_mark: Option<MarkRecord>,
    /// The frozen view of spec 5a and where its delta starts: the turns'
    /// input repeats it byte for byte until a re-render (optchat_core::turn_input).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frozen: Option<FrozenRecord>,
    /// G9: the floor of each side conversation (not the main one) the
    /// chief's wake queue woke, by conversation id.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub side: BTreeMap<String, SideFloor>,
    /// The compactor's failure notice now in the conversation (cx-1hpt):
    /// a host start whose probe fails again posts none, and a good probe
    /// retracts it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor_notice: Option<PostedNotice>,
    /// The thread root of each user message of the Chief conversation that
    /// is itself a thread reply, by message id (a top-level message is its
    /// own root and has no entry): a reply to it, even a subagent's report
    /// after a restart, goes into that thread. At most
    /// [`MESSAGE_ROOTS_KEPT`], oldest dropped first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub message_roots: Vec<(String, String)>,
    /// Wakes the Chief asked for with `sleep` (brain/wakes.rs), soonest
    /// first. At most [`WAKES_KEPT`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub wakes: Vec<Wake>,
}

/// How many pending wakes `HostState::wakes` keeps.
pub const WAKES_KEPT: usize = 8;

/// One wake the Chief asked for with `sleep`: at `at_ms` (wall clock, ms
/// since the epoch) a note with `note` starts a turn.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Wake {
    /// When it is due (ms since the epoch).
    pub at_ms: u64,
    /// When the Chief asked for it (ms since the epoch).
    pub asked_ms: u64,
    /// Why: the Chief's own words, shown in the wake note.
    #[serde(default)]
    pub note: String,
    /// `until: event`: a turn for a user message or a report that starts
    /// first drops this wake.
    #[serde(default)]
    pub until_event: bool,
}

/// How many thread roots `HostState::message_roots` keeps.
pub const MESSAGE_ROOTS_KEPT: usize = 512;

impl HostState {
    /// Records that user message `id` is a reply in the thread of `root`.
    pub fn note_root(&mut self, id: &str, root: &str) {
        if id == root || self.message_roots.iter().any(|(m, _)| m == id) {
            return;
        }
        self.message_roots.push((id.to_owned(), root.to_owned()));
        let extra = self.message_roots.len().saturating_sub(MESSAGE_ROOTS_KEPT);
        self.message_roots.drain(..extra);
    }

    /// The thread root of user message `id`: its recorded root, else itself.
    pub fn root_of(&self, id: &str) -> String {
        self.message_roots
            .iter()
            .find(|(m, _)| m == id)
            .map(|(_, r)| r.clone())
            .unwrap_or_else(|| id.to_owned())
    }
}

/// A notice the host posted and may take back.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PostedNotice {
    /// Its idempotency key and client_msg_id.
    pub key: String,
    /// Its message id, once the owner confirmed it (what a retract names).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
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
    /// E22: the messages that turn answered; each turn its reports cause
    /// answers them too, and says while a subagent of it still works.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answers: Vec<String>,
}

impl SubRecord {
    /// Starting or running and not cancelled: a cancelled one whose session
    /// never ends its turn is not at work (#7).
    pub fn at_work(&self) -> bool {
        matches!(self.status, SubStatus::Starting | SubStatus::Running) && !self.cancelled
    }
}

impl SpawnRecord {
    /// A subagent still works or has a report waiting that starts a turn.
    pub fn working(&self) -> bool {
        self.subs
            .iter()
            .any(|s| s.status != SubStatus::Reported && !(s.status == SubStatus::Done && s.stopped))
    }

    /// A subagent still works for user message `id`: its own `answers` (a
    /// tell) name it, or it has none and the spawn's do.
    pub fn working_for(&self, id: &str) -> bool {
        self.subs.iter().any(|s| {
            let for_it = if s.answers.is_empty() {
                self.answers.iter().any(|a| a == id)
            } else {
                s.answers.iter().any(|a| a == id)
            };
            for_it && s.status != SubStatus::Reported && !(s.status == SubStatus::Done && s.stopped)
        })
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubStatus {
    /// Its session is being created.
    #[default]
    Starting,
    /// It waits for a free slot (`OPTCHAT_MAX_LIVE_SUBAGENTS` run at once;
    /// no cap by default).
    Queued,
    /// A turn runs, or one ended and was not read yet.
    Running,
    /// It ended a turn; `report` holds its last reply, not logged yet.
    Done,
    /// Its last report is in the log.
    Reported,
}

/// What opens a subagent's workspace later (`control show`): the key it
/// opens under, its sidebar group and its terminal's folder on this machine.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceSlot {
    /// The key it opens under: at first the one its session carries as
    /// CMUX_WORKSPACE_ID; a fresh one after `control hide` closed it (the
    /// daemon replays a mutation id it has seen, so a closed key never
    /// opens again).
    pub key: String,
    pub group: String,
    pub cwd: std::path::PathBuf,
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
    /// Where `control show` opens its workspace while it has none (hidden,
    /// `subagents.showWorkspaces` off, #26386, or closed by `control hide`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_slot: Option<WorkspaceSlot>,
    /// The acpmux peer (a cloud VM) it runs on; None: this machine. Only
    /// local subagents count against the live cap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
    /// Its own sandbox key's public id (`vmk_...`, agent_keys.rs) until it is
    /// revoked; the key itself is never stored here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_key: Option<String>,
    /// Its own VM (`peer` chief-sub-<id>) was deleted after it finished and
    /// its work was pushed: a tell can no longer reach it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vm_deleted: bool,
    /// When its own VM was last seen with this subagent not live (ms since
    /// the epoch); the VM is deleted `cloud.deleteAfterPausedDays` after
    /// it. Saved, so a host restart does not start the wait again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_idle_since: Option<u64>,
    /// The fleet jobs its last report waits on (`fleet-wait: JOB` lines,
    /// fleet_wait.rs): its VM stays paused until one ends.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fleet_wait: Vec<String>,
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
    /// `ask` when it was spawned under the spawn floor (a turn another
    /// person started, or a live ask child): the host refuses its local
    /// effects.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<String>,
    /// A queued subagent's launch, saved so a restarted host still starts it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued_launch: Option<QueuedLaunch>,
    /// Automatic continues in a row after error stops (auto_resume.rs);
    /// 0 again after a run that ends with a real report.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub resume_attempts: u32,
    /// Landing follow-ups the host sent it (sub_watch `unlanded`, a676):
    /// a report that says its work is not landed gets one before the Chief
    /// hears of it.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub land_followups: u32,
    /// The harness it moves to (its account hit a usage limit) once the
    /// brain takes the move; saved, so a restart still moves it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moving: Option<String>,
    /// It was moved off a harness whose account hit a usage limit, and has
    /// not ended a run with a real report since: it is not moved again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub moved: bool,
    /// Messages the Chief sent it that it has not got yet (queued or
    /// starting, or held while paused), oldest first. Saved, so a restart
    /// never drops one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub inbox: Vec<InboxMessage>,
    /// Keys of the tells already taken (newest last, at most
    /// [`TELL_KEYS_KEPT`]): a repeat with one of them is not sent again.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tell_keys: Vec<String>,
    /// The prompt to send the moment the interrupted turn stops
    /// (`control interrupt|restart` with a message).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_stop: Option<String>,
    /// `control pause`: no auto-resume, the inbox is held until `resume`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub paused: bool,
    /// `control cancel`: it is over; nothing starts or resumes it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cancelled: bool,
    /// `control priority`: a queued one with a higher value starts first.
    #[serde(default, skip_serializing_if = "is_zero_i64")]
    pub priority: i64,
    /// Its pending permission request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<PendingPermission>,
    /// The user messages the turn that last told it answered (`tell` during
    /// a turn): its next report answers them, and goes into their thread.
    /// Empty: the spawn's own (`SpawnRecord::answers`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answers: Vec<String>,
    /// When its session last changed (ms since the epoch): stuck detection.
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub active_ms: u64,
    /// The stuck note of this run was sent.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stuck_noted: bool,
    /// Its task as spawned (the start, for `control status`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub task: String,
    /// Automatic continues of a silent run (sub_watch.rs) in this run.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub auto_continues: u32,
    /// When the last automatic continue was sent (ms since the epoch).
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub continued_ms: u64,
    /// Its session exists but its first prompt (view and task) is not sent
    /// yet: tells wait in the inbox so they never arrive before the task.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub awaiting_task: bool,
}

/// How many tell keys a subagent keeps for dedupe.
pub const TELL_KEYS_KEPT: usize = 64;

/// A message for a subagent that has not reached it yet.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxMessage {
    pub text: String,
    /// When the Chief sent it (ms since the epoch).
    #[serde(default)]
    pub at_ms: u64,
}

/// A subagent's permission request that waits for an answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingPermission {
    pub id: String,
    pub request: Value,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_zero_i64(n: &i64) -> bool {
    *n == 0
}

fn is_zero_u64(n: &u64) -> bool {
    *n == 0
}

/// What a queued subagent starts with: its task, directory, effort and
/// security floor (`Some("ask")` under the spawn floor).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueuedLaunch {
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub floor: Option<String>,
    /// The harness it starts on (a subagent moved off a harness whose
    /// account hit a usage limit); None: the engine of now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
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
    /// A reply with link cards waits for their previews until this time (ms
    /// since the epoch), or until they arrive; then it goes as it is (a card
    /// without a preview carries its URL only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previews_until: Option<u64>,
    /// A reply split into link cards keeps its original text here: when the
    /// owner refuses the cards, that text goes instead, unchanged, under a
    /// new key (a reply is never dropped).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plain_text: Option<String>,
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
    /// E22: the ids of the messages the reply answers: the turn's own and
    /// the steered ones, and for a subagent's report the messages of the
    /// turn that spawned it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answers: Vec<String>,
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
                // This pre-provenance format names no other person: the
                // owner's (the Chief never asks, 2026-10-20).
                ..Item::default()
            })
            .collect()
    }
}

/// One logged item's source, so a restart can finish its bookkeeping: a
/// human message moves the read cursor, a child's report marks the child
/// reported (else reconcile would queue the same report again).
/// `requires_approval` (another person's text: its turn's local effects
/// are refused) is stored as `other_person`. Records of older builds stored
/// `requires_approval`, true also for the owner's own turns that only had
/// unknown provenance; a resume carried it forward, so one old record gated
/// every turn after each restart (2026-10-20). Their key is ignored: they
/// read as the owner's.
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
    /// A paired device sent the message (or the resume note of such a turn).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub remote: bool,
    /// The message came from someone other than the Chief's owner, or the
    /// resumed turn otherwise required approval for effects.
    #[serde(
        default,
        rename = "other_person",
        skip_serializing_if = "std::ops::Not::not"
    )]
    pub requires_approval: bool,
    /// The resume note of a cut turn: a cut resume turn resumes again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub resume: bool,
    /// The resume note's cut messages (their full text), for a resume turn
    /// that is cut again.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cut: Vec<String>,
}

/// A cut turn to run again (`HostState::resumes`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resume {
    /// The side conversation (None: the main one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
    /// The cut turn had a paired device's message: the resume turn asks for
    /// every local effect, as that turn did.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub remote: bool,
    /// The cut turn carried another person's text: the resume turn refuses
    /// its local effects too.
    #[serde(
        default,
        rename = "other_person",
        skip_serializing_if = "std::ops::Not::not"
    )]
    pub requires_approval: bool,
    /// The full text of the cut turn's human messages, in log order: the
    /// resume turn's new messages carry them after the note (they are in
    /// the log already and are not logged again).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub messages: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnRef {
    pub spawn: String,
    /// (subagent id, its floor once this report is logged).
    pub subs: Vec<(String, u64)>,
    /// The report came from a subagent spawned under the spawn floor
    /// (another person's turn): the turn that reads it refuses local effects.
    #[serde(
        default,
        rename = "other_person",
        skip_serializing_if = "std::ops::Not::not"
    )]
    pub requires_approval: bool,
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

    /// Subagents whose automatic continue (auto_resume.rs) was planned but
    /// not sent, with the planned attempt: the run ended, `resume_attempts`
    /// is set, and the Chief has not paused or cancelled it. The plan's
    /// backoff or network wait is a thread that dies with the host, so a
    /// restarted host re-arms these.
    pub fn pending_auto_resumes(&self) -> Vec<(String, u32)> {
        let mut pending: Vec<(String, u32)> = self
            .spawns
            .values()
            .flat_map(|r| &r.subs)
            .filter(|s| {
                s.resume_attempts > 0
                    && matches!(s.status, SubStatus::Done | SubStatus::Reported)
                    && !s.paused
                    && !s.cancelled
            })
            .map(|s| (s.id.clone(), s.resume_attempts))
            .collect();
        pending.sort();
        pending
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
    /// Where a turn's attached files are saved (`brain::files`): the
    /// `attachments` folder beside the state, in the Chief's home.
    pub fn attachments_dir(&self) -> PathBuf {
        self.path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("attachments")
    }

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

/// A turn's marked view prefix: its byte length and `trace::hash`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarkRecord {
    pub bytes: usize,
    pub hash: String,
}

impl MarkRecord {
    pub fn of(prefix: &str) -> MarkRecord {
        MarkRecord {
            bytes: prefix.len(),
            hash: crate::trace::hash(prefix),
        }
    }

    /// The same prefix of `view`, when `view` still starts with it.
    pub fn prefix_of<'a>(&self, view: &'a str) -> Option<&'a str> {
        let prefix = view.get(..self.bytes)?;
        (crate::trace::hash(prefix) == self.hash).then_some(prefix)
    }
}

/// `optchat_core::Frozen` as saved: the view's parts and its unbuilt parts by
/// name (`id+n`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrozenRecord {
    pub parts: Vec<String>,
    pub front: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unbuilt: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cuts: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub starts: Vec<u64>,
}

fn node_names(parts: &[optchat_core::NodeId]) -> Vec<String> {
    parts.iter().map(|p| p.name()).collect()
}

/// Parts by name; None when one does not parse.
pub fn parse_nodes(names: &[String]) -> Option<Vec<optchat_core::NodeId>> {
    names
        .iter()
        .map(|name| {
            let (id, n) = name.split_once('+')?;
            optchat_core::NodeId::from_name(id.parse().ok()?, n.parse().ok()?)
        })
        .collect()
}

impl FrozenRecord {
    pub fn of(frozen: &optchat_core::Frozen) -> FrozenRecord {
        FrozenRecord {
            parts: node_names(&frozen.parts),
            front: frozen.front,
            unbuilt: node_names(&frozen.unbuilt),
            cuts: frozen.cuts.clone(),
            starts: frozen.starts.clone(),
        }
    }

    /// The record as optchat-core takes it; None when a part does not parse
    /// (then the turn renders a new view).
    pub fn frozen(&self) -> Option<optchat_core::Frozen> {
        Some(optchat_core::Frozen {
            parts: parse_nodes(&self.parts)?,
            front: self.front,
            unbuilt: parse_nodes(&self.unbuilt)?,
            cuts: self.cuts.clone(),
            starts: self.starts.clone(),
        })
    }
}

#[cfg(test)]
mod auto_resume_tests {
    use super::{HostState, SpawnRecord, SubRecord, SubStatus};

    fn sub(id: &str, status: SubStatus, attempts: u32) -> SubRecord {
        SubRecord {
            id: id.to_owned(),
            status,
            resume_attempts: attempts,
            ..SubRecord::default()
        }
    }

    #[test]
    fn a_planned_continue_survives_a_host_restart() {
        let mut state = HostState::default();
        let mut paused = sub("a5", SubStatus::Done, 1);
        paused.paused = true;
        let mut cancelled = sub("a6", SubStatus::Reported, 1);
        cancelled.cancelled = true;
        state.spawns.insert(
            "spawn-1".to_owned(),
            SpawnRecord {
                subs: vec![
                    sub("a1", SubStatus::Done, 2),
                    sub("a2", SubStatus::Reported, 1),
                    sub("a3", SubStatus::Running, 1),
                    sub("a4", SubStatus::Done, 0),
                    paused,
                    cancelled,
                ],
                ..SpawnRecord::default()
            },
        );
        let saved = serde_json::to_vec(&state).unwrap();
        let restarted: HostState = serde_json::from_slice(&saved).unwrap();
        assert_eq!(
            restarted.pending_auto_resumes(),
            vec![("a1".to_owned(), 2), ("a2".to_owned(), 1)]
        );
    }
}

#[cfg(test)]
mod security_tests {
    use super::{Item, PendingTurn, Resume, SpawnRef};

    #[test]
    fn old_approval_flags_are_dropped_and_another_person_round_trips() {
        // Records of older builds: an explicit old flag and a missing one.
        let old_item: Item = serde_json::from_str(r#"{"seq":1,"requires_approval":true}"#).unwrap();
        let old_resume: Resume =
            serde_json::from_str(r#"{"messages":["continue"],"requires_approval":true}"#).unwrap();
        let old_spawn: SpawnRef =
            serde_json::from_str(r#"{"spawn":"spawn-1","subs":[],"quiet":false}"#).unwrap();
        assert!(!old_item.requires_approval);
        assert!(!old_resume.requires_approval);
        assert!(!old_spawn.requires_approval);
        let legacy_turn = PendingTurn {
            seqs: vec![Some(7), None],
            ..PendingTurn::default()
        };
        assert!(
            legacy_turn
                .opening()
                .iter()
                .all(|item| !item.requires_approval)
        );

        let item = Item {
            requires_approval: true,
            ..Item::default()
        };
        let resume = Resume {
            requires_approval: true,
            ..Resume::default()
        };
        let spawn = SpawnRef {
            spawn: "spawn-1".to_owned(),
            subs: Vec::new(),
            requires_approval: true,
            quiet: false,
        };
        let item_again: Item = serde_json::from_slice(&serde_json::to_vec(&item).unwrap()).unwrap();
        let resume_again: Resume =
            serde_json::from_slice(&serde_json::to_vec(&resume).unwrap()).unwrap();
        let spawn_again: SpawnRef =
            serde_json::from_slice(&serde_json::to_vec(&spawn).unwrap()).unwrap();
        assert!(item_again.requires_approval);
        assert!(resume_again.requires_approval);
        assert!(spawn_again.requires_approval);
    }
}

/// A person message of the Chief conversation that waits for a reply
/// (brain/reply_ledger.rs).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Awaiting {
    /// The message's id in the conversation.
    pub id: String,
    pub seq: u64,
    /// When it arrived (ms since the epoch).
    pub since_ms: u64,
    /// The start of its text, for the retry note and the failure note.
    #[serde(default)]
    pub preview: String,
    /// Retry turns started for it so far.
    #[serde(default)]
    pub tries: u32,
    /// When the next check is due (ms since the epoch); None while a turn
    /// that sees it is queued or running.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_ms: Option<u64>,
    /// Why the last turn left it unanswered (`NO_REPLY`, a silent end, an
    /// error, a refused post), for the retry note and the failure note.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}
