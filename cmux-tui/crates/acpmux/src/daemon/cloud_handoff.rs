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
//! /v1/handoffs/:id/turns`) before it sends the prompt, so a turn that
//! begins here reports on the hand-off's current turn. It tries the last
//! turn the store named (1 at first). A `handoff.stale` or
//! `handoff.turn_out_of_order` refusal names the current turn; the begin
//! takes that turn only while nothing has reported on it (`starting`) and
//! the owner opened it before this turn began here (within [`SKEW_MS`] of
//! clock difference), so a begin that waited in the queue never takes a
//! turn opened after it. Later reports of a turn stay on the turn its begin
//! took, so a late report never lands on a newer turn. A begin the store
//! refuses otherwise (no hand-off for the session, its turn already ended,
//! or the hand-off closed) leaves the turn unreported; a closed hand-off
//! gets no more reports. A closed session reports nothing until it reopens.
//!
//! The hub's events are only read and queued here; one worker sends the
//! reports in order, one at a time, so a slow API never holds the event
//! stream. The queue drops a needs-you or running step past
//! [`QUEUE_SOFT_CAP`] waiting steps, never a turn's begin or end or a
//! session's close or reopen.

use crate::hub::Hub;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

/// The Cloud agent's socket (cmux-host `cloud/wire.rs` `AGENT_SOCKET`).
const SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// Another socket instead (tests, a machine whose agent listens elsewhere).
const SOCKET_ENV: &str = "ACPMUX_CLOUD_AGENT_SOCKET";
/// Waiting steps past which a needs-you or running step is dropped.
const QUEUE_SOFT_CAP: usize = 4096;
/// Sessions followed at most; past it a session with no turn being reported is forgotten.
const MAX_TRACKS: usize = 4096;
/// Closed sessions remembered at most (the oldest is forgotten first).
const MAX_CLOSED: usize = 4096;
/// The agent answers within its own bounds (a queued ask waits at most 60 s,
/// then up to three API calls of 20 s); past this it is not answering.
const REPLY_TIMEOUT: Duration = Duration::from_secs(150);
/// The longest reply line read.
const MAX_REPLY: u64 = 64 * 1024;
/// A report that did not reach the store is sent again after these waits.
const RETRY_AFTER: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(10)];
/// An agent that took the line and never answered (one from before hand-off reports reads the
/// line and says nothing) is not asked again for this long: its sessions' steps are skipped.
const SILENT_FOR: Duration = Duration::from_secs(15 * 60);
/// How far this machine's clock may be behind the API's when a begin is matched to the turn
/// the owner opened.
pub(super) const SKEW_MS: u64 = 2_000;
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
    /// A turn began, at this machine's time `at` (ms).
    Began { at: u64 },
    /// A permission or question waits for the person: what it asks, when known.
    Asks(Option<String>),
    /// The session runs again (after an ask was answered).
    Runs,
    /// The turn ended.
    Ended(End),
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
    /// Why it failed (masked, cut).
    Failed(String),
    /// Stopped before it finished.
    Cancelled,
}

/// The step a record is, or `None` for every record a hand-off does not follow. A completed
/// turn's reply is read by the caller (`handoff_loop`), when the turn ends.
pub(super) fn step_of(kind: &str, msg: &Value, at: u64) -> Option<Step> {
    match kind {
        "turn_started" => Some(Step::Began { at }),
        "permission_request" => Some(Step::Asks(ask_text(&msg["request"]))),
        "reopened" => Some(Step::Reopened),
        "status" => match msg["status"].as_str()? {
            "waiting" => Some(Step::Asks(None)),
            "running" => Some(Step::Runs),
            "closed" => Some(Step::Closed),
            _ => None,
        },
        "turn_result" => Some(Step::Ended(match msg["status"].as_str() {
            Some("completed") => End::Completed(None),
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

/// `text` with its secrets masked (`secret_scan`), on one line, at most `max` characters. Only
/// the first [`INPUT_CHARS`] are read.
pub(super) fn cut(text: &str, max: usize) -> String {
    let head = match text.char_indices().nth(INPUT_CHARS) {
        Some((at, _)) => text.get(..at).unwrap_or(text),
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
}

/// The hand-off's current turn, as a refusal names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Current {
    turn: u64,
    /// When the owner opened it (API time, ms), while nothing has reported on it.
    starting_since: Option<u64>,
}

/// How the store answered one report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Accepted(u64),
    /// An older turn: the store's current turn.
    Stale(Current),
    /// A turn not begun: the store's current turn.
    Early(Current),
    /// The turn already ended; the store's current turn.
    Finished(u64),
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
    let turn = reply.pointer("/handoff/turn").and_then(Value::as_u64);
    if reply["ok"] == true {
        return (turn.map_or(Outcome::Unsent, Outcome::Accepted), false);
    }
    let current = turn.map(|turn| Current {
        turn,
        starting_since: (reply.pointer("/handoff/status").and_then(Value::as_str)
            == Some("starting"))
        .then(|| reply.pointer("/handoff/statusAt").and_then(Value::as_str))
        .flatten()
        .and_then(crate::server::machine_health::rfc3339_ms),
    });
    let code = reply.pointer("/error/code").and_then(Value::as_str).unwrap_or("");
    let status = reply["status"].as_u64().unwrap_or(0);
    match (code, current) {
        ("handoff.stale", Some(c)) => (Outcome::Stale(c), false),
        ("handoff.turn_out_of_order", Some(c)) => (Outcome::Early(c), false),
        ("handoff.turn_finished", Some(c)) => (Outcome::Finished(c.turn), false),
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
    /// The hand-off is closed: nothing more is reported.
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
    /// Sessions closed here (oldest first), until they reopen.
    closed: HashSet<String>,
    closed_order: VecDeque<String>,
    /// Until when the agent is not asked: it did not answer the last report.
    silent_until: Option<tokio::time::Instant>,
}

impl<I: Io> Reporter<I> {
    pub(super) fn new(io: I) -> Self {
        Reporter {
            io,
            tracks: HashMap::new(),
            closed: HashSet::new(),
            closed_order: VecDeque::new(),
            silent_until: None,
        }
    }

    pub(super) async fn step(&mut self, session: &str, step: Step) {
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
        if self.closed.contains(session) || !self.io.present() {
            return;
        }
        if self.silent_until.is_some_and(|until| tokio::time::Instant::now() < until) {
            if let Some(track) = self.tracks.get_mut(session) {
                track.now = Now::Quiet;
            }
            return;
        }
        if !self.tracks.contains_key(session) {
            self.make_room();
        }
        let track = self.tracks.entry(session.to_owned()).or_default();
        if track.closed {
            return;
        }
        let now = track.now;
        match (step, now) {
            (Step::Began { at }, _) => self.begin(session, at).await,
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
                    End::Completed(reply) => ("done", reply.filter(|r| !r.is_empty())),
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

    /// The session closed: a turn still reported ends failed, and the session reports nothing
    /// until it reopens.
    async fn close(&mut self, session: &str) {
        if self.closed.insert(session.to_owned()) {
            self.closed_order.push_back(session.to_owned());
            while self.closed_order.len() > MAX_CLOSED {
                if let Some(old) = self.closed_order.pop_front() {
                    self.closed.remove(&old);
                }
            }
        }
        let Some(track) = self.tracks.remove(session) else { return };
        let silent = self.silent_until.is_some_and(|until| tokio::time::Instant::now() < until);
        if let Now::Reporting { turn, last } = track.now
            && !track.closed
            && !silent
            && self.io.present()
            && !matches!(last, Some("done" | "failed"))
        {
            let note = Some("The session was closed before the turn finished.".to_owned());
            self.report(session, turn, "failed", note).await;
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

    /// A turn began at `at` (this machine's ms): reported on the hand-off's current turn.
    async fn begin(&mut self, session: &str, at: u64) {
        let tried = self.tracks.get(session).map_or(1, |t| t.turn.max(1));
        let mut target = tried;
        let mut answer = self.report(session, tried, "running", None).await;
        if let Outcome::Stale(current) | Outcome::Early(current) = answer
            && current.turn != tried
            && current.starting_since.is_some_and(|since| at.saturating_add(SKEW_MS) >= since)
        {
            target = current.turn;
            answer = self.report(session, target, "running", None).await;
        }
        let Some(track) = self.tracks.get_mut(session) else { return };
        track.now = match answer {
            Outcome::Accepted(turn) => Now::Reporting { turn, last: Some("running") },
            // The store did not answer: the turn's later reports go to the turn it was sent on.
            Outcome::Unsent => Now::Reporting { turn: target, last: None },
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
            Outcome::Accepted(t) | Outcome::Finished(t) => self.learn(session, t),
            Outcome::Stale(c) | Outcome::Early(c) => self.learn(session, c.turn),
            Outcome::Closed => {
                if let Some(track) = self.tracks.get_mut(session) {
                    track.closed = true;
                    track.now = Now::Quiet;
                }
            }
            // Not handed off: nothing to remember.
            Outcome::NotFound => {
                self.tracks.remove(session);
            }
            Outcome::Unsent => tracing::warn!(session, turn, status, "hand-off report not sent"),
        }
        answer
    }

    fn learn(&mut self, session: &str, turn: u64) {
        if let Some(track) = self.tracks.get_mut(session) {
            track.turn = turn;
        }
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
}

/// Follows this daemon's own sessions (never a peer's) and reports their turns to their
/// hand-offs while the Cloud agent's socket is there.
pub(super) async fn handoff_loop(hub: Arc<Hub>) {
    let path = std::env::var_os(SOCKET_ENV).map_or_else(|| PathBuf::from(SOCKET), PathBuf::from);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(String, Step)>();
    let waiting = Arc::new(AtomicUsize::new(0));
    let mut reporter = Reporter::new(AgentSocket { path: path.clone() });
    let taken = waiting.clone();
    tokio::spawn(async move {
        while let Some((session, step)) = rx.recv().await {
            taken.fetch_sub(1, Ordering::SeqCst);
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
        let Some(mut step) = step_of(&ev.record.kind, &ev.record.msg, ev.record.at) else {
            continue;
        };
        // Off a Cloud machine only a session's close and reopen are kept (a few bytes each).
        let cloud = path.exists();
        if !cloud && !matches!(step, Step::Closed | Step::Reopened) {
            continue;
        }
        // The reply of the turn that just ended, read now: a later turn's never stands in for it.
        if let Step::Ended(End::Completed(reply)) = &mut step {
            let (hub, id) = (hub.clone(), ev.session_id.clone());
            let read = move || hub.resolve(&id).ok().and_then(|s| hub.last_reply(&s));
            *reply =
                tokio::task::spawn_blocking(read).await.ok().flatten().map(|r| cut(&r, DONE_CHARS));
        }
        if !step.lifecycle() && waiting.load(Ordering::SeqCst) >= QUEUE_SOFT_CAP {
            tracing::warn!(session = %ev.session_id, "hand-off reports: queue full, a step dropped");
            continue;
        }
        waiting.fetch_add(1, Ordering::SeqCst);
        if tx.send((ev.session_id.clone(), step)).is_err() {
            break;
        }
    }
}

#[cfg(test)]
#[path = "cloud_handoff_tests.rs"]
mod tests;
