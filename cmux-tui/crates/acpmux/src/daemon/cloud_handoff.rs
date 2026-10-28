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
//! accepts for the hand-off's machine, and answers with the hand-off's turn
//! and state; acpmux holds no Cloud credential. A machine without the
//! agent's socket (every machine that is not a Cloud machine) reports
//! nothing and reads nothing.
//!
//! Turns: the owner opens each turn of a hand-off before it sends the
//! prompt (`POST /v1/handoffs/:id/turns`), so a turn that begins here
//! reports on the hand-off's current turn. It starts from turn 1, or the
//! last turn the store named; a `handoff.stale` refusal names the current
//! one, and the begin report is sent again on it. Only a begin adopts a turn
//! that way; the later reports of a turn stay on the turn its begin was
//! accepted on, so a late report never lands on a newer turn. A begin the
//! store refuses (no hand-off for the session, its current turn already
//! ended, or it is closed) leaves the turn unreported. The owner closes a
//! hand-off; a closed one gets no more reports.
//!
//! The hub's events are only read and queued here (bounded; a full queue
//! drops the step with a warning); one worker sends the reports in order,
//! one at a time, so a slow API never holds the event stream.

use crate::hub::Hub;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

/// The Cloud agent's socket (cmux-host `cloud/wire.rs` `AGENT_SOCKET`).
const SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// Another socket instead (tests, a machine whose agent listens elsewhere).
const SOCKET_ENV: &str = "ACPMUX_CLOUD_AGENT_SOCKET";
/// Steps waiting for the worker at most.
const QUEUE: usize = 1024;
/// The agent answers within its own bounds (a queued ask waits at most 60 s,
/// then up to three API calls of 20 s); past this the report counts as unsent.
const REPLY_TIMEOUT: Duration = Duration::from_secs(150);
/// The longest reply line read.
const MAX_REPLY: u64 = 64 * 1024;
/// A report that did not reach the store is sent again after these waits.
const RETRY_AFTER: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(10)];
/// An agent that did not answer at all (an agent from before hand-off reports reads the line
/// and says nothing) is not asked again for this long: its sessions' steps are skipped.
const SILENT_FOR: Duration = Duration::from_secs(15 * 60);
/// A finished turn's summary: the start of its last reply.
const DONE_CHARS: usize = 600;
/// A failed turn's summary, and what a permission or question asks.
const NOTE_CHARS: usize = 300;

/// What one of a session's records means for its hand-off.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Step {
    /// A turn began.
    Began,
    /// A permission or question waits for the person: what it asks, when known.
    Asks(Option<String>),
    /// The session runs again (after an ask was answered).
    Runs,
    /// The turn ended.
    Ended(End),
    /// The session was closed.
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum End {
    Completed,
    /// Why it failed (masked, cut).
    Failed(String),
    /// Stopped before it finished.
    Cancelled,
}

/// The step a record is, or `None` for every record a hand-off does not follow.
pub(super) fn step_of(kind: &str, msg: &Value) -> Option<Step> {
    match kind {
        "turn_started" => Some(Step::Began),
        "permission_request" => Some(Step::Asks(ask_text(&msg["request"]))),
        "status" => match msg["status"].as_str()? {
            "waiting" => Some(Step::Asks(None)),
            "running" => Some(Step::Runs),
            "closed" => Some(Step::Closed),
            _ => None,
        },
        "turn_result" => Some(Step::Ended(match msg["status"].as_str() {
            Some("completed") => End::Completed,
            Some("cancelled") => End::Cancelled,
            _ => {
                let why = msg["errorText"].as_str().or(msg["error"].as_str()).unwrap_or("");
                End::Failed(cut(why, NOTE_CHARS))
            }
        })),
        _ => None,
    }
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

/// `text` with its secrets masked (`secret_scan`), on one line, at most `max` characters.
fn cut(text: &str, max: usize) -> String {
    let one_line = crate::secret_scan::mask(text).split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let mut out: String = one_line.chars().take(max).collect();
    out.push('…');
    out
}

/// The store's session id shape (`[A-Za-z0-9_.:-]{1,128}`); any other session has no hand-off.
fn valid_session(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

/// What the reporter reads and sends through: the agent's socket and the hub (tests use fakes).
pub(super) trait Io {
    /// Whether this machine has a Cloud agent to report to.
    fn present(&self) -> bool;
    /// One line to the agent and its one reply line; `None` when none came.
    fn send(&self, line: String) -> impl Future<Output = Option<Value>> + Send;
    /// The session's last reply (masked).
    fn last_reply(&self, session: &str) -> impl Future<Output = Option<String>> + Send;
}

/// How the store answered one report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Accepted(u64),
    /// An older turn; the store's current turn.
    Stale(u64),
    /// A turn not begun; the store's current turn.
    Early(u64),
    /// The turn already ended; the store's current turn.
    Finished(u64),
    Closed,
    /// No hand-off for this session.
    NotFound,
    /// Not answered by the store (unreachable, busy, refused for another reason).
    Unsent,
}

fn outcome(reply: Option<&Value>) -> (Outcome, bool) {
    // No answer at all is not retried (`SILENT_FOR`).
    let Some(reply) = reply else { return (Outcome::Unsent, false) };
    let turn = reply.pointer("/handoff/turn").and_then(Value::as_u64);
    if reply["ok"] == true {
        return (turn.map_or(Outcome::Unsent, Outcome::Accepted), false);
    }
    let code = reply.pointer("/error/code").and_then(Value::as_str).unwrap_or("");
    let status = reply["status"].as_u64().unwrap_or(0);
    match (code, turn) {
        ("handoff.stale", Some(t)) => (Outcome::Stale(t), false),
        ("handoff.turn_out_of_order", Some(t)) => (Outcome::Early(t), false),
        ("handoff.turn_finished", Some(t)) => (Outcome::Finished(t), false),
        ("handoff.closed", _) => (Outcome::Closed, false),
        ("handoff.not_found", _) => (Outcome::NotFound, false),
        // The agent busy or stopping, the API unreachable or failing: worth another try.
        ("busy" | "vm.agent_stopping" | "handoff.unreachable", _) => (Outcome::Unsent, true),
        _ => (Outcome::Unsent, status >= 500 || status == 429),
    }
}

/// One session's place in its hand-off.
#[derive(Debug, Default)]
struct Track {
    /// The hand-off's turn as last learned (0: not yet, so a begin tries turn 1).
    turn: u64,
    now: Now,
    closed: bool,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum Now {
    /// No turn running here, or one this hand-off does not follow.
    #[default]
    Quiet,
    /// A turn reported on hand-off turn `turn`; `last` is the status the store has from it.
    Reporting { turn: u64, last: Option<&'static str> },
}

/// The worker's state: each session's track. Steps come in order, one at a time.
pub(super) struct Reporter<I: Io> {
    io: I,
    tracks: HashMap<String, Track>,
    /// Until when the agent is not asked: it did not answer the last report.
    silent_until: Option<tokio::time::Instant>,
}

impl<I: Io> Reporter<I> {
    pub(super) fn new(io: I) -> Self {
        Reporter { io, tracks: HashMap::new(), silent_until: None }
    }

    pub(super) async fn step(&mut self, session: &str, step: Step) {
        if !valid_session(session) || !self.io.present() {
            return;
        }
        if self.silent_until.is_some_and(|until| tokio::time::Instant::now() < until) {
            if step == Step::Closed {
                self.tracks.remove(session);
            } else if let Some(track) = self.tracks.get_mut(session) {
                track.now = Now::Quiet;
            }
            return;
        }
        if step == Step::Closed {
            // A turn still reported when its session closed ends failed; the session is forgotten.
            if let Some(track) = self.tracks.remove(session)
                && let Now::Reporting { turn, last } = track.now
                && !track.closed
                && !matches!(last, Some("done" | "failed"))
            {
                let note = Some("The session was closed before the turn finished.".to_owned());
                self.report(session, turn, "failed", note).await;
            }
            return;
        }
        let track = self.tracks.entry(session.to_owned()).or_default();
        if track.closed {
            return;
        }
        let now = track.now;
        match (step, now) {
            (Step::Began, _) => self.begin(session).await,
            (Step::Asks(what), Now::Reporting { turn, last })
                if last != Some("needs-you") || what.is_some() =>
            {
                self.follow(session, turn, "needs-you", what).await;
            }
            (Step::Runs, Now::Reporting { turn, last: Some("needs-you") }) => {
                self.follow(session, turn, "running", None).await;
            }
            (Step::Ended(end), Now::Reporting { turn, .. }) => {
                let (status, note) = match end {
                    End::Completed => {
                        ("done", self.io.last_reply(session).await.map(|r| cut(&r, DONE_CHARS)))
                    }
                    End::Failed(why) => ("failed", Some(why).filter(|w| !w.is_empty())),
                    End::Cancelled => ("failed", Some("Stopped before it finished.".to_owned())),
                };
                self.follow(session, turn, status, note).await;
                if let Some(track) = self.tracks.get_mut(session) {
                    track.now = Now::Quiet;
                }
            }
            _ => {}
        }
    }

    /// A turn began: reported on the hand-off's current turn, learned from a stale refusal.
    async fn begin(&mut self, session: &str) {
        let tried = self.tracks.get(session).map_or(1, |t| t.turn.max(1));
        let mut answer = self.report(session, tried, "running", None).await;
        if let Outcome::Stale(current) | Outcome::Early(current) = answer
            && current != tried
        {
            answer = self.report(session, current, "running", None).await;
        }
        let Some(track) = self.tracks.get_mut(session) else { return };
        track.now = match answer {
            Outcome::Accepted(turn) => Now::Reporting { turn, last: Some("running") },
            // The store did not answer: the turn's later reports try the turn tried.
            Outcome::Unsent => Now::Reporting { turn: tried, last: None },
            _ => Now::Quiet,
        };
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
            Outcome::Accepted(_) => track.now = Now::Reporting { turn, last: Some(status) },
            Outcome::Unsent => {}
            _ => track.now = Now::Quiet,
        }
    }

    /// Sends one report (again after a failure worth retrying) and learns the store's turn
    /// and whether the hand-off closed from its answer.
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
        for wait in std::iter::once(None).chain(RETRY_AFTER.iter().map(Some)) {
            if let Some(wait) = wait {
                tokio::time::sleep(*wait).await;
            }
            let reply = self.io.send(line.clone()).await;
            if reply.is_none() {
                self.silent_until = Some(tokio::time::Instant::now() + SILENT_FOR);
            }
            let (got, again) = outcome(reply.as_ref());
            answer = got;
            if !again {
                break;
            }
        }
        if let Some(track) = self.tracks.get_mut(session) {
            match answer {
                Outcome::Accepted(t)
                | Outcome::Stale(t)
                | Outcome::Early(t)
                | Outcome::Finished(t) => {
                    track.turn = t;
                }
                Outcome::Closed => {
                    track.closed = true;
                    track.now = Now::Quiet;
                }
                Outcome::NotFound | Outcome::Unsent => {}
            }
        }
        if answer == Outcome::Unsent {
            tracing::warn!(session, turn, status, "hand-off report not sent");
        }
        answer
    }
}

/// The Cloud agent's socket and the hub.
struct AgentSocket {
    path: PathBuf,
    hub: Arc<Hub>,
}

impl Io for AgentSocket {
    fn present(&self) -> bool {
        self.path.exists()
    }

    async fn send(&self, line: String) -> Option<Value> {
        let exchange = async {
            let mut stream = tokio::net::UnixStream::connect(&self.path).await.ok()?;
            stream.write_all(format!("{line}\n").as_bytes()).await.ok()?;
            let mut reply = String::new();
            let mut reader = tokio::io::BufReader::new(stream.take(MAX_REPLY));
            reader.read_line(&mut reply).await.ok()?;
            serde_json::from_str(&reply).ok()
        };
        tokio::time::timeout(REPLY_TIMEOUT, exchange).await.ok().flatten()
    }

    async fn last_reply(&self, session: &str) -> Option<String> {
        let (hub, id) = (self.hub.clone(), session.to_owned());
        let read = move || hub.resolve(&id).ok().and_then(|s| hub.last_reply(&s));
        tokio::task::spawn_blocking(read).await.ok().flatten()
    }
}

/// Follows this daemon's own sessions (never a peer's) and reports their turns to their
/// hand-offs while the Cloud agent's socket is there.
pub(super) async fn handoff_loop(hub: Arc<Hub>) {
    let path = std::env::var_os(SOCKET_ENV).map_or_else(|| PathBuf::from(SOCKET), PathBuf::from);
    let (tx, mut rx) = tokio::sync::mpsc::channel::<(String, Step)>(QUEUE);
    let mut reporter = Reporter::new(AgentSocket { path, hub: hub.clone() });
    tokio::spawn(async move {
        while let Some((session, step)) = rx.recv().await {
            reporter.step(&session, step).await;
        }
    });
    let mut events = hub.subscribe();
    loop {
        let ev = match events.recv().await {
            Ok(ev) => ev,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!(missed = n, "hand-off reports: the event stream lagged");
                continue;
            }
            Err(_) => break,
        };
        if ev.remote.is_some() || ev.record.dir != "mux" {
            continue;
        }
        let Some(step) = step_of(&ev.record.kind, &ev.record.msg) else { continue };
        if tx.try_send((ev.session_id.clone(), step)).is_err() {
            tracing::warn!(session = %ev.session_id, "hand-off reports: queue full, a step dropped");
        }
    }
}

#[cfg(test)]
#[path = "cloud_handoff_tests.rs"]
mod tests;
