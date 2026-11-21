//! The typed, versioned records of `acpmux monitor`: a read-only observer's view of one chat.
//!
//! This is the "typed ACPMUX progression" of the personal-orchestration plan
//! (manaflow-ai/cmuxterm-hq `plans/feat-personal-orchestration/README.md`), Phase 0 and 1:
//! one envelope per line, tagged by `type`:
//!
//! - `snapshot`: the chat as the daemon reports it now (`_acpmux/info`), with the cursor to
//!   follow from: `(generation, sequence)`. `generation` is the session receipt's
//!   ownership/liveness generation; `sequence` is the event log's seq.
//! - `event`: one log record past the cursor, redacted to its kind, time and (for a mux
//!   `status` record) the state it names. Prompts, replies and tool payloads never appear.
//! - `gap`: the follower could not account for what it was handed (a skipped seq, a new
//!   generation, a lost connection). The monitor re-snapshots after one and marks that
//!   snapshot `resyncing`; it never fills the hole from memory.
//! - `complete`: a terminal operation receipt. The monitor never infers one from a quiet
//!   stream, so today it only parses them (fixtures); fan-out emits them later.
//!
//! Readers tolerate unknown fields and unknown event kinds (no `deny_unknown_fields`), and
//! [`Follower`] rejects records from an older generation.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The schema every envelope carries; a breaking change is a new version.
pub(crate) const SCHEMA: &str = "acpmux.monitor.v1";

/// One line of monitor output.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum Envelope {
    Snapshot(Snapshot),
    Event(Event),
    Gap(Gap),
    Complete(Complete),
}

/// Where a follower stands: everything through `sequence` of `generation` is accounted for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Cursor {
    pub generation: u64,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub schema: String,
    pub session_id: String,
    /// The owning host in the daemon's own view (`local` for its own chats).
    pub host_role: String,
    pub generation: u64,
    pub captured_at: u64,
    /// The daemon's status word (`ready`, `running`, `idle`, ...), as reported.
    pub state: String,
    pub agent: Agent,
    #[serde(default)]
    pub pending_permissions: u64,
    #[serde(default)]
    pub children: u64,
    pub freshness: Freshness,
    /// Always true: prompts, replies, titles, paths and tool payloads are left out.
    pub redacted: bool,
    /// True when this snapshot follows a `gap`: the interval before it is unknown.
    #[serde(default)]
    pub resyncing: bool,
    pub cursor: Cursor,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Agent {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Freshness {
    /// The daemon's last update of the chat (ms since the epoch), when it said.
    #[serde(default)]
    pub updated_at: Option<u64>,
    /// `captured_at - updated_at`, when both are known.
    #[serde(default)]
    pub age_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Event {
    /// `<sessionId>:<seq>`, the same cursor `session tail --since` takes.
    pub id: String,
    pub session_id: String,
    pub generation: u64,
    pub sequence: u64,
    #[serde(default)]
    pub at: Option<u64>,
    /// The record's kind as the daemon wrote it; unknown kinds pass through untouched.
    pub kind: String,
    /// For a mux `status` record, the status it names.
    #[serde(default)]
    pub state: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum GapReason {
    /// A record's seq skipped past the cursor's next one.
    Sequence,
    /// The session's generation moved on (a restart or a new owner).
    Generation,
    /// The daemon connection was lost.
    Disconnect,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Gap {
    pub schema: String,
    pub session_id: String,
    pub reason: GapReason,
    /// The cursor the follower held.
    pub cursor: Cursor,
    /// What arrived instead: the seq or generation that did not follow.
    #[serde(default)]
    pub got: Option<u64>,
    /// Always `resyncing`: the next line is a fresh snapshot.
    pub state: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Complete {
    pub schema: String,
    pub operation_id: String,
    pub session_id: String,
    pub generation: u64,
    pub state: String,
    pub completed_at: u64,
    #[serde(default)]
    pub children: Vec<Value>,
    #[serde(default)]
    pub result_summary: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    pub receipt_ref: String,
}

impl Snapshot {
    /// The snapshot of one `_acpmux/info` reply, redacted. `None` when the reply lacks the
    /// session receipt's generation or the log's seq: the monitor reports that rather than
    /// guess a cursor.
    pub(crate) fn from_info(info: &Value, captured_at: u64, resyncing: bool) -> Option<Self> {
        let receipt = info.get("sessionReceipt")?;
        let generation = receipt.get("generation")?.as_u64()?;
        let session_id = receipt
            .get("muxSessionId")
            .or_else(|| info.get("sessionId"))
            .and_then(Value::as_str)?
            .to_owned();
        let sequence = info.get("lastSeq")?.as_u64()?;
        let s = |k: &str| info.get(k).and_then(Value::as_str).map(str::to_owned);
        let updated_at = info.get("updatedAt").and_then(Value::as_u64);
        Some(Self {
            schema: SCHEMA.to_owned(),
            session_id,
            host_role: receipt.get("hostId").and_then(Value::as_str).unwrap_or("local").to_owned(),
            generation,
            captured_at,
            state: s("status").or_else(|| s("state")).unwrap_or_else(|| "unknown".to_owned()),
            agent: Agent { name: s("name"), harness: s("harness"), model: s("model") },
            pending_permissions: info
                .get("pendingPermissions")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            children: info.get("children").and_then(Value::as_u64).unwrap_or(0),
            freshness: Freshness {
                updated_at,
                age_ms: updated_at.map(|u| captured_at.saturating_sub(u)),
            },
            redacted: true,
            resyncing,
            cursor: Cursor { generation, sequence },
        })
    }
}

impl Event {
    /// The redacted event of one `_acpmux/events` record: kind, time, seq and, for a mux
    /// `status` record, its status. `None` for a record without a seq.
    pub(crate) fn from_record(session_id: &str, generation: u64, rec: &Value) -> Option<Self> {
        let sequence = rec.get("seq")?.as_u64()?;
        let kind = rec.get("kind").and_then(Value::as_str).unwrap_or("unknown").to_owned();
        let state = (kind == "status")
            .then(|| rec.pointer("/msg/status").and_then(Value::as_str).map(str::to_owned))
            .flatten();
        Some(Self {
            id: format!("{session_id}:{sequence}"),
            session_id: session_id.to_owned(),
            generation,
            sequence,
            at: rec.get("at").and_then(Value::as_u64),
            kind,
            state,
        })
    }
}

/// What a follower makes of one event.
#[derive(Debug, PartialEq)]
pub(crate) enum Step {
    /// The next one: the cursor moved to it.
    Apply,
    /// Already accounted for (a page and a live note overlap): skipped.
    Duplicate,
    /// From an older generation: rejected, the cursor stays.
    Stale,
    /// It does not follow: re-snapshot before going on.
    Gap(Gap),
}

/// The cursor-keeping half of the monitor, with no I/O: it decides, for each event, whether
/// it is the next one, a repeat, stale, or a gap.
#[derive(Debug, Clone)]
pub(crate) struct Follower {
    pub session_id: String,
    pub cursor: Cursor,
}

impl Follower {
    pub(crate) fn new(snapshot: &Snapshot) -> Self {
        Self { session_id: snapshot.session_id.clone(), cursor: snapshot.cursor }
    }

    pub(crate) fn accept(&mut self, e: &Event) -> Step {
        let c = self.cursor;
        if e.generation < c.generation {
            return Step::Stale;
        }
        if e.generation > c.generation {
            return Step::Gap(self.gap(GapReason::Generation, Some(e.generation)));
        }
        if e.sequence <= c.sequence {
            return Step::Duplicate;
        }
        if e.sequence != c.sequence + 1 {
            return Step::Gap(self.gap(GapReason::Sequence, Some(e.sequence)));
        }
        self.cursor.sequence = e.sequence;
        Step::Apply
    }

    /// A gap if the daemon's current generation is not the cursor's (tests; a live check of
    /// `ownershipEpoch` is a follow-up).
    #[cfg(test)]
    pub(crate) fn check_generation(&self, generation: u64) -> Option<Gap> {
        (generation != self.cursor.generation)
            .then(|| self.gap(GapReason::Generation, Some(generation)))
    }

    pub(crate) fn gap(&self, reason: GapReason, got: Option<u64>) -> Gap {
        Gap {
            schema: SCHEMA.to_owned(),
            session_id: self.session_id.clone(),
            reason,
            cursor: self.cursor,
            got,
            state: "resyncing".to_owned(),
        }
    }
}
