//! The pure part of v1's tap table, not the stateful pre-append normalization stage.
use super::super::background_turn::BackgroundTurns;
use super::super::process::ProcessTable;
use super::super::stream_state::StreamState;
use super::super::subagent::SubagentTree;
use super::super::todo::Watch;
use super::logged_init::{InitSections, LoggedInit};
use super::update_repeats::{Repeats, UpdateRepeats};
use super::{EventRecord, drop_display_lines, logged_bodies, model_copy};
use super::{is_context_answer, times_request};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    In,
    Out,
}

/// RPC entries contain the canonical message from the existing RPC parser, not raw host JSON.
/// Requests and responses retain their envelope; notifications may log only their params.
pub enum Entry<'a> {
    Request { direction: Direction, method: &'a str, value: Value },
    Notification { direction: Direction, method: &'a str, value: Value },
    Response { direction: Direction, value: Value },
    Stderr { text: Value },
    Exit { code: Value },
}

/// Scoped state used while translating one wire entry. Implementations keep
/// each closure's lock scope local; closures may not append or call a hub.
pub trait RecordState {
    fn idle(&self) -> bool;
    fn closed(&self) -> bool;
    fn hibernate(&self) -> bool;
    fn loading(&self) -> bool;
    fn with_awaiting_first_delta<R>(&mut self, f: impl FnOnce(&AtomicBool) -> R) -> R;
    fn with_logged_init<R>(&mut self, f: impl FnOnce(&mut LoggedInit) -> R) -> R;
    fn with_update_repeats<R>(&mut self, f: impl FnOnce(&mut UpdateRepeats) -> R) -> R;
}

/// A chat's record context. Repeat hashes start empty at daemon start, as in v1.
/// The registry must retain them across actor retirement and harness restarts in that run.
/// The timing flag is reset at every harness start, including re-adoption.
#[derive(Default)]
pub struct Context {
    /// True only when v1 status is Idle (no child), not Ready (a live child with no turn).
    pub idle: bool,
    pub closed: bool,
    pub hibernate: bool,
    pub loading: bool,
    pub logged_init: LoggedInit,
    pub update_repeats: UpdateRepeats,
    pub awaiting_first_delta: AtomicBool,
    /// Stateful tap pieces retained by the chat registry across actor/harness retirement.
    pub stream: StreamState,
    pub todo: Option<Watch>,
    pub subagents: SubagentTree,
    pub background: BackgroundTurns,
    pub processes: ProcessTable,
    pub compacting: bool,
    pub compaction_metadata_fenced: bool,
}

impl Context {
    pub fn harness_started(&mut self) {
        self.awaiting_first_delta.store(false, Ordering::Relaxed);
    }
}

impl RecordState for Context {
    fn idle(&self) -> bool {
        self.idle
    }
    fn closed(&self) -> bool {
        self.closed
    }
    fn hibernate(&self) -> bool {
        self.hibernate
    }
    fn loading(&self) -> bool {
        self.loading
    }
    fn with_awaiting_first_delta<R>(&mut self, f: impl FnOnce(&AtomicBool) -> R) -> R {
        f(&self.awaiting_first_delta)
    }
    fn with_logged_init<R>(&mut self, f: impl FnOnce(&mut LoggedInit) -> R) -> R {
        f(&mut self.logged_init)
    }
    fn with_update_repeats<R>(&mut self, f: impl FnOnce(&mut UpdateRepeats) -> R) -> R {
        f(&mut self.update_repeats)
    }
}

/// A prepared line and the hashes to remember only after its append succeeds.
/// Dropping this value after a failed write leaves repeat state unchanged.
#[must_use]
pub struct Record {
    pub dir: &'static str,
    pub kind: String,
    pub msg: Value,
    init: Option<InitSections>,
    repeats: Option<Repeats>,
}

impl Record {
    fn new(dir: &'static str, kind: impl Into<String>, msg: Value) -> Self {
        Self { dir, kind: kind.into(), msg, init: None, repeats: None }
    }

    pub fn event(&self, seq: u64, at: u64, host_seq: Option<u64>) -> EventRecord {
        EventRecord {
            seq,
            at,
            dir: self.dir.into(),
            kind: self.kind.clone(),
            msg: self.msg.clone(),
            host_seq,
        }
    }

    /// Called by the stateful stage with its live-update repeat eligibility decision.
    /// The live-update branch precedes the response-kind fallback, exactly as in v1.
    /// Returns false when the eligible update has nothing left to log.
    pub fn trim_live_update<S: RecordState>(&mut self, context: &mut S, eligible: bool) -> bool {
        if self.dir != "in"
            || self.msg.get("method").and_then(Value::as_str) != Some("session/update")
        {
            return true;
        }
        let update = (eligible && !self.kind.ends_with(".replay"))
            .then(|| self.msg.pointer_mut("/params/update"))
            .flatten();
        if let Some(update) = update {
            let repeats = context.with_update_repeats(|r| r.leave_out_repeats(&self.kind, update));
            if repeats.nothing_left {
                return false;
            }
            self.repeats = Some(repeats);
        } else if self.kind == "response" {
            self.repeats = Some(
                context.with_update_repeats(|r| r.leave_out_repeats(&self.kind, &mut self.msg)),
            );
        }
        true
    }

    pub fn note_logged<S: RecordState>(self, context: &mut S) {
        if let Some(sections) = self.init {
            context.with_logged_init(|i| i.note_logged(sections));
        }
        if let Some(sections) = self.repeats {
            context.with_update_repeats(|r| r.note_logged(sections));
        }
    }
}

/// The pure record table. None means kept nowhere and acknowledged without an append.
/// Hub effects and stateful body normalization belong to the caller's separate stage.
pub fn record_of<S: RecordState>(entry: Entry<'_>, context: &mut S) -> Option<Record> {
    let (direction, mut kind, mut value, notification) = match entry {
        Entry::Stderr { text } => return Some(Record::new("mux", "stderr", json!({"text": text}))),
        Entry::Exit { code } => {
            let hibernating = context.hibernate() && !context.closed();
            let intentional = hibernating || context.idle() || context.closed();
            let body = if hibernating {
                json!({"code": code, "hibernated": true})
            } else {
                json!({"code": code})
            };
            return Some(Record::new("mux", if intentional { "stopped" } else { "exited" }, body));
        }
        Entry::Request { direction, method, value } => (direction, method.to_owned(), value, false),
        Entry::Notification { direction, method, value } => {
            (direction, method.to_owned(), value, true)
        }
        Entry::Response { direction, value } => (direction, "response".into(), value, false),
    };
    // Preserve method predicates before a session/update replaces the logged kind.
    let permission_request = kind == "session/request_permission";
    let session_update = kind == "session/update";
    let dir = if direction == Direction::In { "in" } else { "out" };
    if notification && direction == Direction::In {
        let params = value.get("params");
        if kind == "claude.stream_event"
            && !params.is_some_and(|p| context.with_awaiting_first_delta(|a| times_request(p, a)))
        {
            return None;
        }
        if kind == "claude.control_response" && params.is_some_and(is_context_answer) {
            return None;
        }
        if kind.starts_with("claude.") {
            let mut line = value.get_mut("params").map(Value::take).unwrap_or(Value::Null);
            model_copy::scrub_logged(&mut line);
            logged_bodies::leave_out_bodies(&kind, &mut line);
            let init = Some(context.with_logged_init(|i| i.leave_out_repeats(&kind, &mut line)));
            let repeats = (kind == "claude.control_response")
                .then(|| context.with_update_repeats(|r| r.leave_out_repeats(&kind, &mut line)));
            return Some(Record { dir, kind, msg: line, init, repeats });
        }
        if kind == "session/update" {
            if let Some(update_kind) =
                value.pointer("/params/update/sessionUpdate").and_then(Value::as_str)
            {
                kind = update_kind.to_owned();
            }
            if context.loading() {
                kind.push_str(".replay");
            }
        }
    }
    if notification && direction == Direction::Out && kind == "claude.stdin" {
        value = value.get_mut("params").map(Value::take).unwrap_or(Value::Null);
    }
    model_copy::scrub_logged(&mut value);
    if direction == Direction::Out {
        logged_bodies::leave_out_prompt_bodies(&kind, &mut value);
    } else if permission_request && let Some(params) = value.get_mut("params") {
        drop_display_lines(params);
    }
    let repeats = (direction == Direction::In && kind == "response" && !session_update)
        .then(|| context.with_update_repeats(|r| r.leave_out_repeats(&kind, &mut value)));
    Some(Record { dir, kind, msg: value, init: None, repeats })
}

/// Scoped access to the stateful pieces held by one chat registry entry.
/// Closures must not append records or call hub functions; the caller owns those effects.
pub trait ContextState: RecordState {
    fn stream<R>(&mut self, f: impl FnOnce(&mut StreamState) -> R) -> R;
    fn todo<R>(&mut self, f: impl FnOnce(&mut Option<Watch>) -> R) -> R;
    fn subagents<R>(&mut self, f: impl FnOnce(&mut SubagentTree) -> R) -> R;
    fn background<R>(&mut self, f: impl FnOnce(&mut BackgroundTurns) -> R) -> R;
    fn processes<R>(&mut self, f: impl FnOnce(&mut ProcessTable) -> R) -> R;
    fn set_compacting(&mut self, value: bool);
    fn compacting(&self) -> bool;
    fn set_compaction_metadata_fenced(&mut self, value: bool);
    fn compaction_metadata_fenced(&self) -> bool;
}

impl ContextState for Context {
    fn stream<R>(&mut self, f: impl FnOnce(&mut StreamState) -> R) -> R {
        f(&mut self.stream)
    }
    fn todo<R>(&mut self, f: impl FnOnce(&mut Option<Watch>) -> R) -> R {
        f(&mut self.todo)
    }
    fn subagents<R>(&mut self, f: impl FnOnce(&mut SubagentTree) -> R) -> R {
        f(&mut self.subagents)
    }
    fn background<R>(&mut self, f: impl FnOnce(&mut BackgroundTurns) -> R) -> R {
        f(&mut self.background)
    }
    fn processes<R>(&mut self, f: impl FnOnce(&mut ProcessTable) -> R) -> R {
        f(&mut self.processes)
    }
    fn set_compacting(&mut self, value: bool) {
        self.compacting = value;
    }
    fn compacting(&self) -> bool {
        self.compacting
    }
    fn set_compaction_metadata_fenced(&mut self, value: bool) {
        self.compaction_metadata_fenced = value;
    }
    fn compaction_metadata_fenced(&self) -> bool {
        self.compaction_metadata_fenced
    }
}
