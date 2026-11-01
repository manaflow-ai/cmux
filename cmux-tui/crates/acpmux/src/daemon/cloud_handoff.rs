//! On a cmux Cloud machine, each session's turns reported to its hand-off
//! (cloud work mode, backend/apps/api/src/handoffs): a turn that begins
//! reports `running`, a permission or question `needs-you` (with what it
//! asks), an answer `running` again, and the turn's end `done` (with the
//! start of its last reply) or `failed` (with why). The owner's app reads
//! them to show and notify the chat's state from anywhere.
//!
//! Reports go to the machine's Cloud agent (cmux-host `cloud/handoff.rs`)
//! as one `{"handoff_report": {...}}` line per connection on its socket. The
//! agent posts it as the machine's VM install, the credential the store
//! accepts for the hand-off's machine, and answers with the hand-off's turn,
//! state, status and `statusAt`; acpmux holds no Cloud credential. A machine
//! without the agent's socket (every machine that is not a Cloud machine)
//! reports nothing and reads nothing.
//!
//! Turns: the owner opens each turn of a hand-off (`POST
//! /v1/handoffs/:id/turns`) and then sends the turn's prompt with a prompt id
//! that names it, `handoff-<turn>-<unique>` (`_meta.acpmux.promptId`, which
//! acpmux carries on the turn's `turn_started` and `turn_result` records). A
//! turn's begin and end each report on exactly the turn their prompt names; a
//! needs-you or running step reports on the turn whose begin was reported. So
//! a report never lands on another turn however long it waited in the queue,
//! and a turn that failed before it started still reports its failure. A
//! prompt that names no turn (one the owner did not open a turn for) is not
//! reported. A turn the store refuses (no hand-off for the session, an older
//! or not-yet-opened turn, its turn already ended, or the hand-off closed)
//! reports nothing more; a closed hand-off gets no more reports. A closed
//! session reports nothing until it reopens.
//!
//! A turn that failed on an error acpmux retries by itself (`hub/auto_resume.rs`:
//! a connection cut, no capacity; a first send a revoked token failed) is not reported failed yet: its continuation
//! (`<prompt id>~resume-<n>`, naming the same turn) goes on with it. It is
//! reported failed once no continuation comes: `auto_resume_settled`,
//! `_exhausted` or `_skipped`, another prompt begins, the session closes, no
//! continuation was scheduled within [`DECIDE_WAIT`], or [`RETRY_WAIT_MAX`]
//! passed since the last one was. A deadline is judged by when each event
//! reached the queue, never by when a busy worker got to it, and the worker
//! reports a due turn by itself only once the queue is empty.
//!
//! The hub's events are only read and queued here; one worker sends the
//! reports in order, one at a time, and reads a finished turn's reply (only
//! that turn's records), so a slow API or disk never holds the event stream.
//! The queue holds at most [`QUEUE_CAP`] steps. Past [`QUEUE_SOFT_CAP`]
//! waiting steps a needs-you or running step is dropped; past [`QUEUE_CAP`]
//! any step is. Then, or when the event stream lags, the queue's steps from
//! before the loss start no turn and report no needs-you or running, and every
//! turn being reported stops being followed (one's end may be lost).

use crate::hub::Hub;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

/// The Cloud agent's socket (cmux-host `cloud/wire.rs` `AGENT_SOCKET`).
const SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// Another socket instead (tests, a machine whose agent listens elsewhere).
const SOCKET_ENV: &str = "ACPMUX_CLOUD_AGENT_SOCKET";
/// Waiting steps past which a needs-you or running step is dropped.
const QUEUE_SOFT_CAP: usize = 4096;
/// Waiting steps at most: past it any step is dropped.
const QUEUE_CAP: usize = 16_384;
/// The prompt id of a hand-off turn's prompt starts with this, then the turn and `-`.
pub(super) const PROMPT_PREFIX: &str = "handoff-";
/// Sessions followed at most; past it a session with no turn being reported is forgotten, and a
/// new session is not followed while every followed one is reporting a turn.
const MAX_TRACKS: usize = 4096;
/// Closed sessions, and sessions whose hand-off closed, remembered at most (the oldest is
/// forgotten first).
const MAX_CLOSED: usize = 4096;
/// The agent answers within its own bounds (a queued ask waits at most 60 s,
/// then up to three API calls of 20 s); past this it is not answering.
const REPLY_TIMEOUT: Duration = Duration::from_secs(150);
/// A fire-and-forget attention line must not hold the hand-off worker on a dead socket.
const NOTIFY_TIMEOUT: Duration = Duration::from_secs(2);
/// The longest reply line read.
const MAX_REPLY: u64 = 64 * 1024;
/// A report that did not reach the store is sent again after these waits.
const RETRY_AFTER: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(10)];
/// An agent that took the line and never answered (one from before hand-off reports reads the
/// line and says nothing) is not asked again for this long: its sessions' steps are skipped.
const SILENT_FOR: Duration = Duration::from_secs(15 * 60);
/// A failed turn acpmux may continue is reported failed when no continuation was scheduled
/// (`auto_resume_scheduled`) this long after it failed: the hub decides at once.
pub(super) const DECIDE_WAIT: Duration = Duration::from_secs(120);
/// ... or this long after its continuation was scheduled (the longest wait `autoResumeDelaysMs`
/// takes is an hour).
pub(super) const RETRY_WAIT_MAX: Duration = Duration::from_secs(65 * 60);
/// A turn's end the store did not get (unreachable past its retries, the agent not answering
/// or gone) is sent again after these waits (about 45 minutes in all), then given up.
const LATER: [Duration; 4] = [
    Duration::from_secs(30),
    Duration::from_secs(120),
    Duration::from_secs(600),
    Duration::from_secs(1800),
];
/// Turn ends waiting to be sent again, at most.
const MAX_LATER: usize = 4096;
/// A finished turn's summary: the start of its last reply.
const DONE_CHARS: usize = 600;
/// A failed turn's summary, and what a permission or question asks.
const NOTE_CHARS: usize = 300;
/// Text read at most before it is masked and cut (a secret longer than the rest of this past
/// the cut is the only one that could be split).
const INPUT_CHARS: usize = 16_384;

/// What one of a session's records means for its hand-off.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Step {
    /// A turn began: the hand-off turn its prompt names, if it names one.
    Began(Option<u64>),
    /// A permission or question waits for the person: what it asks, when known.
    Asks(Option<String>),
    /// The session runs again (after an ask was answered).
    Runs,
    /// A turn ended: how, and the hand-off turn its prompt names, if it names one.
    Ended(End, Option<u64>),
    /// A failed turn's automatic continuation will not come (`auto_resume_settled`,
    /// `auto_resume_exhausted`, `auto_resume_skipped`, `auto_resume_stopped`).
    NoRetry,
    /// A terminal retry decision observed after reporter restart, before its failed
    /// turn was seen. Carries the named hand-off turn so it can be closed.
    NoRetryFor { turn: u64, why: String },
    /// A failed turn's automatic continuation is scheduled (`auto_resume_scheduled`).
    RetryScheduled,
    /// A retry restored after a daemon restart, before the reporter has seen its
    /// original failed turn. Carries the named hand-off turn and failure summary
    /// so terminal skip/stop events can close the hand-off after reporter restart.
    RetryRestored { turn: u64, why: String },
    /// The session was closed.
    Closed,
    /// A closed session was opened again.
    Reopened,
}

impl Step {
    /// A turn's begin or end, or a session's close or reopen: never dropped.
    fn lifecycle(&self) -> bool {
        !matches!(self, Step::Asks(_) | Step::Runs)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum End {
    /// Finished, with the start of its last reply when it was read.
    Completed(Option<String>),
    /// Why it failed (masked, cut), and whether acpmux decides on a continuation of it
    /// (`turn_errors::resume_cause`, as `hub/auto_resume.rs` does, or a revoked token, which
    /// a chat's first send is retried on: `hub/auto_resume/first_send.rs`).
    Failed { why: String, retried: bool },
    /// Stopped before it finished.
    Cancelled,
}

/// The step a record is, or `None` for every record a hand-off does not follow. A completed
/// turn's reply is read by the worker (`handoff_loop`), from that turn's records.
pub(super) fn step_of(kind: &str, msg: &Value) -> Option<Step> {
    let named = || named_turn(msg["promptId"].as_str());
    match kind {
        "turn_started" => Some(Step::Began(named())),
        "auto_resume_settled" | "auto_resume_exhausted" => {
            let Some(turn) = named_turn(msg["promptId"].as_str()) else {
                return Some(Step::NoRetry);
            };
            let why = msg["why"].as_str().or_else(|| msg["reason"].as_str()).unwrap_or("policy");
            Some(Step::NoRetryFor { turn, why: format!("Automatic retry settled ({why}).") })
        }
        // A Stop ended the wait (`hub/auto_resume.rs` records only `turnId` and `promptId`):
        // the person stopped it, no policy settled it.
        "auto_resume_stopped" => {
            let Some(turn) = named_turn(msg["promptId"].as_str()) else {
                return Some(Step::NoRetry);
            };
            Some(Step::NoRetryFor { turn, why: "Automatic retry stopped.".to_owned() })
        }
        "auto_resume_skipped" => {
            let Some(turn) = named_turn(msg["promptId"].as_str()) else {
                return Some(Step::NoRetry);
            };
            let skipped = msg["skipped"].as_str().unwrap_or("policy");
            Some(Step::NoRetryFor { turn, why: format!("Automatic retry skipped ({skipped}).") })
        }
        "auto_resume_scheduled" => Some(Step::RetryScheduled),
        "auto_resume_restored" => {
            let turn = named_turn(msg["promptId"].as_str())?;
            let why = match msg["reason"].as_str().unwrap_or("transport") {
                "capacity" => "The provider had no capacity.".to_owned(),
                "agent_exited" => "The agent exited before finishing.".to_owned(),
                _ => "The connection was interrupted.".to_owned(),
            };
            Some(Step::RetryRestored { turn, why })
        }
        "permission_request" => Some(Step::Asks(ask_text(&msg["request"]))),
        "reopened" => Some(Step::Reopened),
        "status" => match msg["status"].as_str()? {
            "waiting" => Some(Step::Asks(None)),
            "running" => Some(Step::Runs),
            "closed" => Some(Step::Closed),
            _ => None,
        },
        "turn_result" => {
            let end = match msg["status"].as_str() {
                Some("completed") => End::Completed(None),
                Some("cancelled") => End::Cancelled,
                _ => {
                    let raw = msg["error"].as_str().unwrap_or("");
                    let why = msg["errorText"].as_str().unwrap_or(raw);
                    // The hub decides on the agent's own error or the recorded one
                    // (`turn_errors::continuation_error`): either may be the cause.
                    let cause = crate::hub::turn_errors::resume_cause;
                    // A first send a revoked token failed may be sent again (`first_send.rs`):
                    // a later turn's is settled `auto_resume_settled` at once.
                    let revoked = crate::claude_auth::is_revoked_token;
                    let retried = cause(raw, raw).is_some()
                        || cause(why, why).is_some()
                        || revoked(raw)
                        || revoked(why);
                    End::Failed { why: cut(why, NOTE_CHARS), retried }
                }
            };
            Some(Step::Ended(end, named()))
        }
        _ => None,
    }
}

/// The hand-off turn a prompt id names (`handoff-<turn>-<unique>`, or `handoff-<turn>`), from 1.
/// An auto-resumed attempt (`<id>~resume-<n>`) names its first attempt's turn.
pub(super) fn named_turn(prompt_id: Option<&str>) -> Option<u64> {
    let rest = prompt_id?.strip_prefix(PROMPT_PREFIX)?;
    let digits = rest.split(['-', '~']).next()?;
    if digits.is_empty() || digits.len() > 15 || digits.starts_with('0') {
        return None;
    }
    digits.parse().ok()
}

/// What a permission request asks, masked and cut: an agent's question, or the tool it asks for.
fn ask_text(request: &Value) -> Option<String> {
    let text = if crate::hub::is_question(request) {
        crate::hub::question_prompt(request).map(str::to_owned)
    } else {
        let title = request.pointer("/toolCall/title").and_then(Value::as_str);
        title.map(|t| format!("Permission: {t}"))
    };
    text.map(|t| cut(&t, NOTE_CHARS)).filter(|t| !t.is_empty())
}

/// `text` with its secrets masked (`secret_scan`), on one line, at most `max` characters. Only
/// the first [`INPUT_CHARS`] are read.
pub(super) fn cut(text: &str, max: usize) -> String {
    let head = match text.char_indices().nth(INPUT_CHARS) {
        // The word the cut goes through is dropped: a secret's head would not be masked.
        Some((at, _)) => {
            let read = text.get(..at).unwrap_or("");
            read.rfind(char::is_whitespace).map_or("", |end| read.get(..end).unwrap_or(""))
        }
        None => text,
    };
    let masked = crate::secret_scan::mask(head);
    let mut out = String::new();
    let mut count = 0;
    for word in masked.split_whitespace() {
        if count > 0 {
            out.push(' ');
            count += 1;
        }
        out.push_str(word);
        count += word.chars().count();
        if count > max {
            break;
        }
    }
    if count <= max && head.len() == text.len() {
        return out;
    }
    let mut cut: String = out.chars().take(max).collect();
    cut.push('…');
    cut
}

/// Converts prompt-owned mux records into attention events without requiring
/// a hand-off row. Background turns never emit `turn_started`, so they are
/// excluded by the active-turn gate in `handoff_loop`.
fn attention_for_record(kind: &str, msg: &Value, session: &str, seq: u64) -> Option<Value> {
    let kind = match kind {
        "permission_request" => {
            if crate::hub::is_question(&msg["request"]) {
                "question"
            } else {
                "permission"
            }
        }
        "turn_result" if msg["status"] == "completed" => "done",
        _ => return None,
    };
    let semantic_id = match kind {
        "question" | "permission" => msg
            .get("permissionId")
            .and_then(Value::as_str)
            .or_else(|| msg.pointer("/request/requestId").and_then(Value::as_str)),
        "done" => msg
            .get("turnId")
            .and_then(Value::as_str)
            .or_else(|| msg.get("promptId").and_then(Value::as_str)),
        _ => None,
    }
    .unwrap_or("record");
    let key =
        if semantic_id == "record" { format!("record-{seq}") } else { semantic_id.to_owned() };
    let digest = Sha256::digest(format!("{session}\0{key}\0{kind}").as_bytes());
    let event_id =
        format!("attn_{}", digest.iter().take(20).map(|b| format!("{b:02x}")).collect::<String>());
    Some(json!({
        "event_id": event_id,
        "kind": kind,
        "session": session,
        "title": "Cloud chat",
        "occurred_at": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
    }))
}

fn attention_for_event(
    active_turn: Option<&str>,
    kind: &str,
    msg: &Value,
    session: &str,
    seq: u64,
) -> Option<Value> {
    let active_turn = active_turn?;
    if kind == "permission_request"
        && let Some(turn_id) = msg.get("turnId").and_then(Value::as_str)
        && !active_turn.is_empty()
        && turn_id != active_turn
    {
        return None;
    }
    attention_for_record(kind, msg, session, seq)
}

#[cfg(test)]
mod attention_tests {
    use super::{attention_for_event, attention_for_record};
    use serde_json::json;

    #[test]
    fn only_prompt_owned_turns_emit_attention() {
        let permission =
            json!({"request": {"toolCall": {"title": "Run tests", "kind": "execute"}}});
        assert_eq!(attention_for_event(None, "permission_request", &permission, "s", 1), None);
        assert_eq!(
            attention_for_event(Some("turn-1"), "permission_request", &permission, "s", 1)
                .expect("permission")["kind"],
            "permission"
        );
        assert_eq!(
            attention_for_event(Some("turn-1"), "background_turn", &json!({}), "s", 2),
            None
        );
        assert_eq!(
            attention_for_event(
                Some("turn-1"),
                "turn_result",
                &json!({"status": "completed"}),
                "s",
                3
            )
            .expect("done")["kind"],
            "done"
        );
    }

    #[test]
    fn question_and_permission_are_distinct() {
        let question = json!({"request": {"toolCall": {"title": "AskUserQuestion",
            "_meta": {"claude": {"tool": "AskUserQuestion"}},
            "rawInput": {"questions": [{"question": "Ship it?"}]}}}});
        let permission =
            json!({"request": {"toolCall": {"title": "Write file", "kind": "execute"}}});
        assert_eq!(
            attention_for_record("permission_request", &question, "s", 1).expect("question")["kind"],
            "question"
        );
        assert_eq!(
            attention_for_record("permission_request", &permission, "s", 2).expect("permission")["kind"],
            "permission"
        );
    }

    #[test]
    fn semantic_ids_survive_record_replay() {
        let permission = json!({"permissionId": "perm-1", "request": {"toolCall": {"title": "Write", "kind": "execute"}}});
        let first = attention_for_record("permission_request", &permission, "s", 1).unwrap();
        let replay = attention_for_record("permission_request", &permission, "s", 99).unwrap();
        assert_eq!(first["event_id"], replay["event_id"]);
        let done = json!({"status": "completed", "turnId": "turn-1"});
        let first = attention_for_record("turn_result", &done, "s", 2).unwrap();
        let replay = attention_for_record("turn_result", &done, "s", 100).unwrap();
        assert_eq!(first["event_id"], replay["event_id"]);
    }

    #[test]
    fn late_permission_from_an_old_turn_is_ignored() {
        let permission = json!({"turnId": "turn-old", "permissionId": "perm-1",
            "request": {"toolCall": {"title": "Write", "kind": "execute"}}});
        assert_eq!(
            attention_for_event(Some("turn-new"), "permission_request", &permission, "s", 1),
            None
        );
    }
}

/// The store's session id shape (`[A-Za-z0-9_.:-]{1,128}`); any other session has no hand-off.
fn valid_session(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

/// What came back for one line to the agent.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Reply {
    /// Its reply line.
    Answer(Value),
    /// It took the line and never answered (an agent from before hand-off reports).
    Silent,
    /// It could not be reached, closed the connection, or answered something unreadable.
    Failed,
}

/// The agent's socket (tests use a fake).
pub(super) trait Io {
    /// Whether this machine has a Cloud agent to report to.
    fn present(&self) -> bool;
    /// One line to the agent and what came back.
    fn send(&self, line: String) -> impl Future<Output = Reply> + Send;
    /// Queue an independent attention event; the Cloud agent owns retries.
    fn notify(&self, line: String) -> impl Future<Output = ()> + Send;
}

/// How the store answered one report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Accepted,
    /// Not this turn (older or newer than the hand-off's, or already ended).
    Refused,
    Closed,
    /// No hand-off for this session.
    NotFound,
    /// Not answered by the store (unreachable, busy, refused for another reason).
    Unsent,
}

/// The outcome, and whether to send again.
fn outcome(reply: &Reply) -> (Outcome, bool) {
    let reply = match reply {
        Reply::Answer(v) => v,
        Reply::Failed => return (Outcome::Unsent, true),
        Reply::Silent => return (Outcome::Unsent, false),
    };
    if reply["ok"] == true {
        return (Outcome::Accepted, false);
    }
    let code = reply.pointer("/error/code").and_then(Value::as_str).unwrap_or("");
    let status = reply["status"].as_u64().unwrap_or(0);
    match code {
        "handoff.stale" | "handoff.turn_out_of_order" | "handoff.turn_finished" => {
            (Outcome::Refused, false)
        }
        "handoff.closed" => (Outcome::Closed, false),
        "handoff.not_found" => (Outcome::NotFound, false),
        // The agent busy or stopping, the API unreachable or failing: worth another try.
        "busy" | "vm.agent_stopping" | "handoff.unreachable" => (Outcome::Unsent, true),
        _ => (Outcome::Unsent, status >= 500 || status == 429),
    }
}

/// One session's place in its hand-off.
#[derive(Debug, Default)]
struct Track {
    now: Now,
    /// The last turn the store refused (or had no hand-off for): its end is not sent.
    refused: Option<u64>,
    /// The newest turn whose end was reported here (sent, or waiting in `later`): a late retry
    /// decision for it or an older turn never replaces that end (hand-off turns only grow).
    ended: Option<u64>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
enum Now {
    /// No turn running here, or one this hand-off does not follow.
    #[default]
    Quiet,
    /// A turn reported on hand-off turn `turn`; `last` is the status the store has from it
    /// (`None`: its begin was not answered).
    Reporting { turn: u64, last: Option<&'static str> },
    /// Turn `turn` failed and acpmux may continue it: `why` is reported once no continuation
    /// comes, at `until` at the latest.
    Retrying { turn: u64, why: String, until: tokio::time::Instant },
}

/// The worker's state: each session's track. Steps come in order, one at a time.
pub(super) struct Reporter<I: Io> {
    io: I,
    tracks: HashMap<String, Track>,
    /// Sessions closed here, until they reopen.
    closed: Remembered,
    /// Sessions whose hand-off the store closed: for good (a session has one hand-off), across
    /// the session's close and reopen and its track's eviction.
    handoff_closed: Remembered,
    /// Until when the agent is not asked: it did not answer the last report.
    silent_until: Option<tokio::time::Instant>,
    /// Turn ends the store did not get, by session: sent again later ([`LATER`]).
    later: HashMap<String, Later>,
}

/// A turn's end to send again.
#[derive(Debug, Clone)]
struct Later {
    turn: u64,
    status: &'static str,
    note: Option<String>,
    /// Tries made after the first.
    tries: usize,
    at: tokio::time::Instant,
}

impl<I: Io> Reporter<I> {
    pub(super) fn new(io: I) -> Self {
        Reporter {
            io,
            tracks: HashMap::new(),
            closed: Remembered::default(),
            handoff_closed: Remembered::default(),
            silent_until: None,
            later: HashMap::new(),
        }
    }

    async fn notify_attention(&self, attention: Value) {
        if self.io.present() {
            self.io.notify(json!({ "attention": attention }).to_string()).await;
        }
    }

    /// One step queued now (tests).
    #[cfg(test)]
    pub(super) async fn step(&mut self, session: &str, step: Step) {
        self.step_at(session, step, tokio::time::Instant::now()).await;
    }

    /// One step, `queued` when its event reached the queue: a deadline it meets counts even
    /// when the worker gets to it later.
    pub(super) async fn step_at(
        &mut self,
        session: &str,
        step: Step,
        queued: tokio::time::Instant,
    ) {
        if !valid_session(session) {
            return;
        }
        match step {
            Step::Reopened => {
                self.closed.remove(session);
                return;
            }
            Step::Closed => return self.close(session).await,
            _ => {}
        }
        if self.closed.contains(session) || self.handoff_closed.contains(session) {
            return;
        }
        // While the agent is left alone (`silent`) or its socket is gone, steps still move the
        // session's state; `report` sends nothing then, and a turn's end waits in `later`.
        if !self.tracks.contains_key(session) {
            self.make_room();
            if self.tracks.len() >= MAX_TRACKS {
                tracing::warn!(session, "hand-off reports: too many sessions, one not followed");
                return;
            }
        }
        let track = self.tracks.entry(session.to_owned()).or_default();
        let mut now = track.now.clone();
        // A continuation that did not come in time (by when this step's event came).
        if let Now::Retrying { turn, until, .. } = &now
            && *until <= queued
        {
            let turn = *turn;
            self.give_up_retry(session, turn).await;
            now = Now::Quiet;
        }
        match (step, now) {
            (Step::Began(named), now) => {
                // Another prompt took the chat: the failed turn is not continued.
                if let Now::Retrying { turn, .. } = now
                    && named != Some(turn)
                {
                    self.give_up_retry(session, turn).await;
                }
                self.begin(session, named).await;
            }
            (Step::NoRetry, Now::Retrying { turn, .. }) => self.give_up_retry(session, turn).await,
            // A retry decision for a turn that ended here comes late (the automatic retry a
            // manual one overtook): the turn's end stands.
            (Step::NoRetryFor { turn, why }, Now::Quiet) if !self.ended_here(session, turn) => {
                self.finish(session, turn, "failed", Some(why)).await;
            }
            (Step::NoRetryFor { turn, .. }, Now::Retrying { turn: current, .. })
                if turn == current =>
            {
                self.give_up_retry(session, turn).await;
            }
            (Step::RetryScheduled, Now::Retrying { turn, why, .. }) => {
                let until = queued + RETRY_WAIT_MAX;
                self.set_now(session, Now::Retrying { turn, why, until });
            }
            (Step::RetryRestored { turn, why }, Now::Quiet) if !self.ended_here(session, turn) => {
                let until = queued + RETRY_WAIT_MAX;
                self.set_now(session, Now::Retrying { turn, why, until });
            }
            // Only the held turn's own marker renews its wait.
            (Step::RetryRestored { turn, .. }, Now::Retrying { turn: current, why, .. })
                if turn == current =>
            {
                let until = queued + RETRY_WAIT_MAX;
                self.set_now(session, Now::Retrying { turn: current, why, until });
            }
            (Step::Asks(what), Now::Reporting { turn, last })
                if last != Some("needs-you") || what.is_some() =>
            {
                self.follow(session, turn, "needs-you", what).await;
            }
            (Step::Runs, Now::Reporting { turn, last: Some("needs-you") | None }) => {
                self.follow(session, turn, "running", None).await;
            }
            (Step::Ended(end, named), now) => self.end(session, end, named, now, queued).await,
            _ => {}
        }
    }

    /// A turn ended: reported on the turn its prompt names, unless the store refused that turn,
    /// or acpmux may continue it.
    async fn end(
        &mut self,
        session: &str,
        end: End,
        named: Option<u64>,
        now: Now,
        queued: tokio::time::Instant,
    ) {
        let refused = self.tracks.get(session).and_then(|t| t.refused);
        let Some(turn) = named.filter(|turn| refused != Some(*turn)) else {
            // A prompt that names no hand-off turn, or one the store refused.
            self.set_now(session, Now::Quiet);
            return;
        };
        if let Now::Retrying { turn: other, .. } = now
            && other != turn
        {
            self.give_up_retry(session, other).await;
        }
        let (status, note) = match end {
            End::Completed(reply) => ("done", reply.filter(|r| !r.is_empty())),
            End::Failed { why, retried: true } => {
                let until = queued + DECIDE_WAIT;
                return self.set_now(session, Now::Retrying { turn, why, until });
            }
            End::Failed { why, retried: false } => ("failed", Some(why).filter(|w| !w.is_empty())),
            End::Cancelled => ("failed", Some("Stopped before it finished.".to_owned())),
        };
        self.finish(session, turn, status, note).await;
        self.set_now(session, Now::Quiet);
    }

    /// A turn's end: sent now, or again later if the store did not get it.
    async fn finish(
        &mut self,
        session: &str,
        turn: u64,
        status: &'static str,
        note: Option<String>,
    ) {
        // An older turn's end than one reported here is stale: the store keeps one turn, and a
        // newer end waiting to be sent again stays.
        let newest = self.tracks.get(session).and_then(|t| t.ended);
        if newest.max(self.later.get(session).map(|l| l.turn)) > Some(turn) {
            return;
        }
        // A newer end of the session replaces one still waiting (the store keeps one turn).
        self.later.remove(session);
        if let Some(track) = self.tracks.get_mut(session) {
            track.ended = track.ended.max(Some(turn));
        }
        if self.report(session, turn, status, note.clone()).await == Outcome::Unsent {
            self.send_later(
                session,
                Later { turn, status, note, tries: 0, at: tokio::time::Instant::now() },
            );
        }
    }

    fn send_later(&mut self, session: &str, mut later: Later) {
        let Some(wait) = LATER.get(later.tries) else {
            tracing::warn!(session, turn = later.turn, "hand-off report given up");
            return;
        };
        if self.later.len() >= MAX_LATER && !self.later.contains_key(session) {
            tracing::warn!(session, "hand-off reports: too many waiting, a turn's end dropped");
            return;
        }
        later.at = tokio::time::Instant::now() + *wait;
        self.later.insert(session.to_owned(), later);
    }

    /// Whether the end of `turn`, or of a newer turn, was reported here or waits to be sent
    /// again: a decision for `turn` comes late then.
    fn ended_here(&self, session: &str, turn: u64) -> bool {
        self.tracks.get(session).is_some_and(|t| t.ended >= Some(turn))
            || self.later.get(session).is_some_and(|l| l.turn >= turn)
    }

    /// A failed turn acpmux was to continue gets no continuation: reported failed now.
    async fn give_up_retry(&mut self, session: &str, turn: u64) {
        let Some(Now::Retrying { why, .. }) = self.tracks.get(session).map(|t| t.now.clone())
        else {
            return;
        };
        self.finish(session, turn, "failed", Some(why).filter(|w| !w.is_empty())).await;
        self.set_now(session, Now::Quiet);
    }

    /// When the next failed turn waiting for its continuation is to be reported failed: not
    /// before the agent is asked again, if it is left alone now.
    pub(super) fn next_deadline(&self) -> Option<tokio::time::Instant> {
        let retrying = self.tracks.values().filter_map(|t| match t.now {
            Now::Retrying { until, .. } => Some(until),
            _ => None,
        });
        let due = retrying.chain(self.later.values().map(|l| l.at)).min()?;
        Some(match self.silent_until {
            Some(quiet) if quiet > due => quiet,
            _ => due,
        })
    }

    /// Reports failed every turn whose continuation did not come in time. The worker calls it
    /// only with nothing queued, so no step that came in time waits behind it.
    pub(super) async fn expire(&mut self) {
        let now = tokio::time::Instant::now();
        let due: Vec<(String, u64)> = self
            .tracks
            .iter()
            .filter_map(|(id, t)| match t.now {
                Now::Retrying { turn, until, .. } if until <= now => Some((id.clone(), turn)),
                _ => None,
            })
            .collect();
        for (session, turn) in due {
            // An agent that stopped answering is not asked again for each due turn.
            if self.silent() {
                return;
            }
            self.give_up_retry(&session, turn).await;
        }
        let again: Vec<String> =
            self.later.iter().filter(|(_, l)| l.at <= now).map(|(id, _)| id.clone()).collect();
        for session in again {
            if self.silent() {
                return;
            }
            let Some(later) = self.later.remove(&session) else { continue };
            if self.handoff_closed.contains(&session) {
                continue;
            }
            let answer = self.report(&session, later.turn, later.status, later.note.clone()).await;
            if answer == Outcome::Unsent {
                self.send_later(&session, Later { tries: later.tries + 1, ..later });
            }
        }
    }

    /// The agent did not answer lately and is left alone ([`SILENT_FOR`]).
    fn silent(&self) -> bool {
        self.silent_until.is_some_and(|until| tokio::time::Instant::now() < until)
    }

    fn set_now(&mut self, session: &str, now: Now) {
        if let Some(track) = self.tracks.get_mut(session) {
            track.now = now;
        }
    }

    /// The session closed: a turn still reported ends failed, and the session reports nothing
    /// until it reopens.
    async fn close(&mut self, session: &str) {
        self.closed.insert(session);
        let Some(track) = self.tracks.remove(session) else { return };
        if self.handoff_closed.contains(session) {
            return;
        }
        let closed = || Some("The session was closed before the turn finished.".to_owned());
        let ended = match track.now {
            Now::Reporting { turn, last } if !matches!(last, Some("done" | "failed")) => {
                Some((turn, closed()))
            }
            Now::Retrying { turn, why, .. } => Some((turn, Some(why).filter(|w| !w.is_empty()))),
            _ => None,
        };
        if let Some((turn, note)) = ended {
            self.finish(session, turn, "failed", note).await;
        }
    }

    /// Keeps the tracks under [`MAX_TRACKS`]: sessions with no turn being reported go first.
    fn make_room(&mut self) {
        if self.tracks.len() < MAX_TRACKS {
            return;
        }
        let quiet: Vec<String> = self
            .tracks
            .iter()
            .filter(|(_, t)| t.now == Now::Quiet)
            .map(|(id, _)| id.clone())
            .take(self.tracks.len() / 4 + 1)
            .collect();
        for id in quiet {
            self.tracks.remove(&id);
        }
    }

    /// A turn began: reported on the turn its prompt names, or not at all.
    async fn begin(&mut self, session: &str, turn: Option<u64>) {
        let answer = match turn {
            Some(turn) => Some((turn, self.report(session, turn, "running", None).await)),
            None => None,
        };
        let Some(track) = self.tracks.get_mut(session) else { return };
        // A new attempt of the newest ended turn, one the store may have taken: its end is to
        // come again. A stale begin (refused) or one of an older turn reopens nothing.
        if let Some((turn, Outcome::Accepted | Outcome::Unsent)) = answer
            && track.ended == Some(turn)
        {
            track.ended = turn.checked_sub(1);
        }
        track.now = match answer {
            Some((turn, Outcome::Accepted)) => Now::Reporting { turn, last: Some("running") },
            // The store did not answer: the turn's later reports still go to its turn.
            Some((turn, Outcome::Unsent)) => Now::Reporting { turn, last: None },
            _ => Now::Quiet,
        };
    }

    /// Whether the session holds `turn`, failed, for a continuation.
    pub(super) fn holds(&self, session: &str, turn: Option<u64>) -> bool {
        matches!(self.tracks.get(session).map(|t| &t.now),
            Some(Now::Retrying { turn: held, .. }) if Some(*held) == turn)
    }

    /// Ends the session's hold on `turn` for its continuation, reporting nothing.
    pub(super) fn release(&mut self, session: &str, turn: Option<u64>) {
        if self.holds(session, turn) {
            self.set_now(session, Now::Quiet);
        }
    }

    /// Stops following every reported turn (the queue dropped steps, so one's end may be lost).
    /// A failed turn waiting for its continuation stays: its own records name it.
    pub(super) fn forget_turns(&mut self) {
        for track in self.tracks.values_mut() {
            if matches!(track.now, Now::Reporting { .. }) {
                track.now = Now::Quiet;
            }
        }
    }

    /// A later report of a reported turn: on that turn only.
    async fn follow(
        &mut self,
        session: &str,
        turn: u64,
        status: &'static str,
        note: Option<String>,
    ) {
        let answer = self.report(session, turn, status, note).await;
        let Some(track) = self.tracks.get_mut(session) else { return };
        match answer {
            Outcome::Accepted => track.now = Now::Reporting { turn, last: Some(status) },
            // It may have reached the store: its status is not known, so the next step reports.
            Outcome::Unsent => track.now = Now::Reporting { turn, last: None },
            _ => track.now = Now::Quiet,
        }
    }

    /// Sends one report (again after a failure worth retrying) and learns from its answer
    /// whether the hand-off closed or does not exist.
    async fn report(
        &mut self,
        session: &str,
        turn: u64,
        status: &str,
        note: Option<String>,
    ) -> Outcome {
        let mut fields = Map::new();
        fields.insert("session".into(), json!(session));
        fields.insert("turn".into(), json!(turn));
        fields.insert("status".into(), json!(status));
        if let Some(note) = note {
            fields.insert("summary".into(), json!(note));
        }
        let line = json!({ "handoff_report": Value::Object(fields) }).to_string();
        let mut answer = Outcome::Unsent;
        if self.silent() || !self.io.present() {
            return answer;
        }
        for wait in std::iter::once(None).chain(RETRY_AFTER.iter().map(Some)) {
            if let Some(wait) = wait {
                tokio::time::sleep(*wait).await;
            }
            let reply = self.io.send(line.clone()).await;
            if reply == Reply::Silent {
                self.silent_until = Some(tokio::time::Instant::now() + SILENT_FOR);
            }
            let (got, again) = outcome(&reply);
            answer = got;
            if !again {
                break;
            }
        }
        match answer {
            Outcome::Accepted => {}
            Outcome::Closed => {
                self.handoff_closed.insert(session);
                self.set_now(session, Now::Quiet);
            }
            // Not this turn, or no hand-off for the session: its end is not sent.
            Outcome::Refused => {
                if let Some(track) = self.tracks.get_mut(session) {
                    track.refused = Some(turn);
                }
            }
            Outcome::NotFound => {
                if let Some(track) = self.tracks.get_mut(session) {
                    track.refused = Some(turn);
                }
            }
            Outcome::Unsent => tracing::warn!(session, turn, status, "hand-off report not sent"),
        }
        answer
    }
}

/// The Cloud agent's socket.
struct AgentSocket {
    path: PathBuf,
}

impl Io for AgentSocket {
    fn present(&self) -> bool {
        self.path.exists()
    }

    async fn send(&self, line: String) -> Reply {
        let Ok(mut stream) = tokio::net::UnixStream::connect(&self.path).await else {
            return Reply::Failed;
        };
        if stream.write_all(format!("{line}\n").as_bytes()).await.is_err() {
            return Reply::Failed;
        }
        let mut reply = String::new();
        let mut reader = tokio::io::BufReader::new(stream.take(MAX_REPLY));
        match tokio::time::timeout(REPLY_TIMEOUT, reader.read_line(&mut reply)).await {
            Err(_) => Reply::Silent,
            Ok(Ok(n)) if n > 0 => serde_json::from_str(&reply).map_or(Reply::Failed, Reply::Answer),
            Ok(_) => Reply::Failed,
        }
    }

    async fn notify(&self, line: String) {
        let Ok(Ok(mut stream)) =
            tokio::time::timeout(NOTIFY_TIMEOUT, tokio::net::UnixStream::connect(&self.path)).await
        else {
            return;
        };
        let _ =
            tokio::time::timeout(NOTIFY_TIMEOUT, stream.write_all(format!("{line}\n").as_bytes()))
                .await;
    }
}

/// Follows this daemon's own sessions (never a peer's) and reports their turns to their
/// hand-offs while the Cloud agent's socket is there.
/// The Cloud agent's socket: `ACPMUX_CLOUD_AGENT_SOCKET`, else [`SOCKET`].
fn agent_socket() -> PathBuf {
    std::env::var_os(SOCKET_ENV).map_or_else(|| PathBuf::from(SOCKET), PathBuf::from)
}

/// The Cloud agent's socket was seen, by the census or by [`handoff_loop`] as it queued a report.
static SEEN: AtomicBool = AtomicBool::new(false);

/// Whether this machine has a Cloud agent to report to: its reports wait in memory, so a daemon
/// here never stops for being unused (`unused_exit.rs`, which asks at each census). Once seen, for
/// the rest of the daemon's life: the agent's restart removes its socket for a while, and the
/// reports wait for it (`handoff_loop`).
pub(super) fn reports_here() -> bool {
    reports_to(&agent_socket(), &SEEN)
}

fn reports_to(socket: &std::path::Path, seen: &AtomicBool) -> bool {
    if seen.load(Ordering::SeqCst) {
        return true;
    }
    let here = cfg!(target_os = "linux") && socket.exists();
    if here {
        seen.store(true, Ordering::SeqCst);
    }
    here
}

pub(super) async fn handoff_loop(hub: Arc<Hub>) {
    let path = agent_socket();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Queued>(QUEUE_CAP);
    // Bumped when steps were lost (a full queue, a lagging event stream).
    let losses = Arc::new(AtomicU64::new(0));
    let mut reporter = Reporter::new(AgentSocket { path: path.clone() });
    let (lost, reader) = (losses.clone(), hub.clone());
    tokio::spawn(async move {
        let mut seen = 0;
        loop {
            let deadline = reporter.next_deadline();
            let next = tokio::select! {
                // Queued steps first: a due turn is reported only with nothing queued.
                biased;
                queued = rx.recv() => queued,
                () = sleep_until(deadline), if deadline.is_some() => {
                    reporter.expire().await;
                    continue;
                }
            };
            let Some(mut queued) = next else { break };
            let now = lost.load(Ordering::SeqCst);
            if now != seen {
                reporter.forget_turns();
                seen = now;
            }
            // Queued before a loss: it may follow a lost turn's end, so it starts no turn and
            // reports no needs-you or running (ends, closes and reopens name their own).
            // A begin of the failed turn a session holds for its continuation only ends the hold
            // (else it would report a running turn failed); the session follows no turn, since a
            // later prompt's begin may be lost, and the turn's named end still reports.
            if queued.losses != now
                && matches!(queued.step, Step::Began(_) | Step::Asks(_) | Step::Runs)
            {
                if let Step::Began(named) = queued.step {
                    reporter.release(&queued.session, named);
                }
                continue;
            }
            if let (Step::Ended(End::Completed(reply), _), Some((after, upto))) =
                (&mut queued.step, queued.reply)
            {
                let (hub, id) = (reader.clone(), queued.session.clone());
                let read =
                    move || hub.resolve(&id).ok().and_then(|s| hub.reply_between(&s, after, upto));
                *reply = tokio::task::spawn_blocking(read)
                    .await
                    .ok()
                    .flatten()
                    .map(|r| cut(&r, DONE_CHARS));
            }
            if let Some(attention) = queued.attention {
                reporter.notify_attention(attention).await;
            }
            reporter.step_at(&queued.session, queued.step, queued.at).await;
        }
    });
    let mut events = hub.subscribe();
    let mut cloud = false;
    let mut active_turns = HashMap::<String, String>::new();
    loop {
        let ev = match events.recv().await {
            Ok(ev) => ev,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!(missed = n, "hand-off reports: the event stream lagged");
                losses.fetch_add(1, Ordering::SeqCst);
                active_turns.clear();
                continue;
            }
            Err(_) => break,
        };
        if ev.remote.is_some() || ev.record.dir != "mux" {
            continue;
        }
        let Some(step) = step_of(&ev.record.kind, &ev.record.msg) else {
            continue;
        };
        // Off a Cloud machine only a session's close and reopen are kept (a few bytes each).
        // Once the socket was seen, steps are kept while it is gone (an agent restart).
        // The same latch the unused exit reads, so a report queued here keeps the daemon.
        cloud = cloud || reports_to(&path, &SEEN);
        if !cloud && !matches!(step, Step::Closed | Step::Reopened) {
            continue;
        }
        if ev.record.kind == "turn_started" {
            if active_turns.len() >= MAX_TRACKS {
                active_turns.clear();
            }
            active_turns.insert(
                ev.session_id.clone(),
                ev.record.msg.get("turnId").and_then(Value::as_str).unwrap_or("").to_owned(),
            );
        }
        let attention = attention_for_event(
            active_turns.get(&ev.session_id).map(String::as_str),
            &ev.record.kind,
            &ev.record.msg,
            &ev.session_id,
            ev.record.seq,
        );
        if ev.record.kind == "turn_result" || matches!(step, Step::Closed | Step::Reopened) {
            active_turns.remove(&ev.session_id);
        }
        if !step.lifecycle() && tx.capacity() <= QUEUE_CAP - QUEUE_SOFT_CAP {
            tracing::warn!(session = %ev.session_id, "hand-off reports: queue long, a step dropped");
            continue;
        }
        // A completed turn's reply: its records from its `turn_started` to this `turn_result`.
        let reply = matches!(step, Step::Ended(End::Completed(_), Some(_)))
            .then(|| ev.record.msg["turnSeq"].as_u64())
            .flatten()
            .filter(|from| *from > 0 && *from < ev.record.seq)
            .map(|from| (from, ev.record.seq));
        let queued = Queued {
            session: ev.session_id.clone(),
            step,
            attention,
            reply,
            losses: losses.load(Ordering::SeqCst),
            at: tokio::time::Instant::now(),
        };
        match tx.try_send(queued) {
            Ok(()) => {}
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                tracing::warn!(session = %ev.session_id, "hand-off reports: queue full, a step dropped");
                losses.fetch_add(1, Ordering::SeqCst);
            }
            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => break,
        }
    }
}

async fn sleep_until(deadline: Option<tokio::time::Instant>) {
    if let Some(deadline) = deadline {
        tokio::time::sleep_until(deadline).await;
    }
}

/// One step waiting for the worker.
struct Queued {
    session: String,
    step: Step,
    /// A prompt-owned durable attention transition, independent of hand-offs.
    attention: Option<Value>,
    /// A completed turn's records to read its reply from: after this seq, up to that one.
    reply: Option<(u64, u64)>,
    /// The loss count when it was queued.
    losses: u64,
    /// When it was queued.
    at: tokio::time::Instant,
}

/// A bounded set of session ids, the oldest forgotten first.
#[derive(Default)]
pub(super) struct Remembered {
    ids: HashSet<String>,
    order: VecDeque<String>,
}

impl Remembered {
    fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    fn insert(&mut self, id: &str) {
        if !self.ids.insert(id.to_owned()) {
            return;
        }
        self.order.push_back(id.to_owned());
        while self.order.len() > MAX_CLOSED {
            if let Some(old) = self.order.pop_front() {
                self.ids.remove(&old);
            }
        }
    }

    fn remove(&mut self, id: &str) {
        if self.ids.remove(id) {
            self.order.retain(|s| s != id);
        }
    }

    #[cfg(test)]
    pub(super) fn count(&self, id: &str) -> usize {
        self.order.iter().filter(|s| *s == id).count()
    }
}

#[cfg(test)]
#[path = "cloud_handoff_tests.rs"]
mod tests;
