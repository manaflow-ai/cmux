//! The pure part of v1's tap table, not the stateful pre-append normalization stage.
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
}

impl Context {
    pub fn harness_started(&mut self) {
        self.awaiting_first_delta.store(false, Ordering::Relaxed);
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
    pub fn trim_live_update(&mut self, context: &Context, eligible: bool) -> bool {
        if self.dir != "in"
            || self.msg.get("method").and_then(Value::as_str) != Some("session/update")
        {
            return true;
        }
        let update = (eligible && !self.kind.ends_with(".replay"))
            .then(|| self.msg.pointer_mut("/params/update"))
            .flatten();
        if let Some(update) = update {
            let repeats = context.update_repeats.leave_out_repeats(&self.kind, update);
            if repeats.nothing_left {
                return false;
            }
            self.repeats = Some(repeats);
        } else if self.kind == "response" {
            self.repeats =
                Some(context.update_repeats.leave_out_repeats(&self.kind, &mut self.msg));
        }
        true
    }

    pub fn note_logged(self, context: &mut Context) {
        if let Some(sections) = self.init {
            context.logged_init.note_logged(sections);
        }
        if let Some(sections) = self.repeats {
            context.update_repeats.note_logged(sections);
        }
    }
}

/// The pure record table. None means kept nowhere and acknowledged without an append.
/// Hub effects and stateful body normalization belong to the caller's separate stage.
pub fn record_of(entry: Entry<'_>, context: &mut Context) -> Option<Record> {
    let (direction, mut kind, mut value, notification) = match entry {
        Entry::Stderr { text } => return Some(Record::new("mux", "stderr", json!({"text": text}))),
        Entry::Exit { code } => {
            let hibernating = context.hibernate && !context.closed;
            let intentional = hibernating || context.idle || context.closed;
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
            && !params.is_some_and(|p| times_request(p, &context.awaiting_first_delta))
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
            let init = Some(context.logged_init.leave_out_repeats(&kind, &mut line));
            let repeats = (kind == "claude.control_response")
                .then(|| context.update_repeats.leave_out_repeats(&kind, &mut line));
            return Some(Record { dir, kind, msg: line, init, repeats });
        }
        if kind == "session/update" {
            if let Some(update_kind) =
                value.pointer("/params/update/sessionUpdate").and_then(Value::as_str)
            {
                kind = update_kind.to_owned();
            }
            if context.loading {
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
        .then(|| context.update_repeats.leave_out_repeats(&kind, &mut value));
    Some(Record { dir, kind, msg: value, init: None, repeats })
}
