//! One turn (section 7): a fresh acpmux session in the constant session
//! directory, the prompt `[view, new messages]`, and everything the session
//! does folded into the log as it happens. The brain has already settled the
//! view, rendered it and logged the new messages; this runs on its own thread
//! so the brain keeps reading the conversation while the turn works.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{RecvTimeoutError, Sender, TryRecvError, channel};
use std::time::{Duration, Instant};

use optchat_host::{NewMessage, OptChat};
use serde_json::Value;

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::fold::{Entry, TurnFold, Usage, answer_usage, is_cancelled, stop_error};
use crate::harness_gate::Admitted;
use crate::trace::Trace;

/// How often a stop for a newer message is sent again while the turn has
/// not ended: a `session/cancel` that reaches acpmux before the prompt does
/// is lost (audit round 2), and nothing acknowledges it but the turn's end.
pub const CANCEL_RESEND: Duration = Duration::from_secs(1);

/// How long a turn whose `turn_end` is folded waits for the prompt's answer,
/// which acpmux sends after it and which alone carries the token use.
pub const ANSWER_WAIT: Duration = Duration::from_secs(10);

/// A human message arrived during the turn (decision 2026-10-04: interrupt
/// at once, even mid-thinking; a running tool call finishes first). The
/// brain requests it; the turn's runner acts on it.
#[derive(Default)]
pub struct Interrupt {
    wanted: AtomicBool,
    /// The owner stopped the turn: cancel at once, even while a tool call
    /// waits (`request_hard`), never only at the next tool boundary.
    hard: AtomicBool,
    /// The turn carries another person's text: the native engine refuses
    /// its local effects (README "Remote-origin messages").
    gate: AtomicBool,
    /// The running acpmux turn's signals, woken on a request.
    wake: Mutex<Option<Sender<TurnSignal>>>,
    /// Wakes [`Interrupt::wait`] on a request.
    waiting: (Mutex<()>, std::sync::Condvar),
}

impl Interrupt {
    pub fn new() -> Interrupt {
        Interrupt::default()
    }

    pub fn request(&self) {
        self.wanted.store(true, Ordering::SeqCst);
        {
            let _held = self
                .waiting
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            self.waiting.1.notify_all();
        }
        if let Some(tx) = self
            .wake
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            let _ = tx.send(TurnSignal::Noted);
        }
    }

    /// `request`, and the runner does not wait for a running tool call:
    /// the owner's stop. A call that waits for an approval never ran; one
    /// that runs is cut, as the owner asked.
    pub fn request_hard(&self) {
        self.hard.store(true, Ordering::SeqCst);
        self.request();
    }

    pub fn is_hard(&self) -> bool {
        self.hard.load(Ordering::SeqCst)
    }

    pub fn is_set(&self) -> bool {
        self.wanted.load(Ordering::SeqCst)
    }

    /// Waits up to `limit` for a request (a bounded wait, woken by
    /// [`Interrupt::request`], never polled); whether one came.
    pub fn wait(&self, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        let mut held = self
            .waiting
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        while !self.is_set() {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            held = self
                .waiting
                .1
                .wait_timeout(held, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        true
    }

    /// Sets whether the turn's local effects are refused.
    pub fn set_gate(&self, on: bool) {
        self.gate.store(on, Ordering::SeqCst);
    }

    pub fn gated(&self) -> bool {
        self.gate.load(Ordering::SeqCst)
    }

    /// The queued messages were delivered (native engine).
    pub fn clear(&self) {
        self.wanted.store(false, Ordering::SeqCst);
        self.hard.store(false, Ordering::SeqCst);
    }

    fn wake_with(&self, tx: Option<Sender<TurnSignal>>) {
        *self
            .wake
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = tx;
    }
}

/// Everything a turn needs, decided by the brain.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurnStart {
    /// The reply's idempotency key: `turn:optchat:<first new message id>`.
    pub key: String,
    /// The acpmux promptId (acpmux runs one id once).
    pub prompt_id: String,
    pub session: SessionSpec,
    /// The view pieces, then the new messages (prompt::turn_blocks), or the
    /// cached layout's blocks (prompt::cached_layout).
    pub blocks: Vec<Value>,
    /// The cached layout (Claude harnesses): the text the session's preset
    /// (`session.preset`) gets as its system prompt before the session
    /// starts. None: the session starts with what its preset holds.
    pub system_prompt: Option<String>,
    /// Longest a turn may run; past it the session is removed and the turn
    /// fails, so a turn that hangs in the harness cannot block every later
    /// message. None: no limit.
    pub limit: Option<Duration>,
    /// A turn with no harness event for this long ends ([`idle_error`]),
    /// unless a tool call runs (a long tool sends nothing until it ends).
    pub idle_limit: Option<Duration>,
    /// The session the last turn kept, to prompt again with only this turn's
    /// new messages (`Settings::keep_turn_session`). Taken once: a retry of
    /// this turn starts a fresh session with `blocks`.
    pub reuse: Option<Reuse>,
    /// Keep this turn's session when it ends well ([`TurnOutcome::kept`]).
    pub keep: bool,
    /// A kept session this turn does not reuse: ended before it starts.
    pub retire: Option<String>,
}

/// A turn session kept after its turn (`Settings::keep_turn_session`): the
/// next turn may prompt it again instead of starting a Claude Code process.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Kept {
    /// The acpmux session id.
    pub session: String,
    /// The last event seq the kept turn folded: the next turn folds after it.
    pub after: u64,
}

/// A kept session and the blocks that prompt it again: this turn's new
/// messages only (the session's history holds the rest), with no cache
/// marks (Claude Code places its own).
#[derive(Clone, Debug, Default)]
pub struct Reuse {
    pub kept: Kept,
    pub blocks: Vec<Value>,
    /// Set once a run took the reuse: a retry of the turn (which clones its
    /// start) runs fresh.
    spent: std::sync::Arc<AtomicBool>,
}

impl Reuse {
    pub fn new(kept: Kept, blocks: Vec<Value>) -> Reuse {
        Reuse {
            kept,
            blocks,
            spent: Default::default(),
        }
    }

    /// The reuse, the first time it is asked for.
    fn take(&self) -> Option<&Reuse> {
        (!self.spent.swap(true, Ordering::SeqCst)).then_some(self)
    }
}

impl PartialEq for Reuse {
    fn eq(&self, other: &Reuse) -> bool {
        self.kept == other.kept && self.blocks == other.blocks
    }
}

/// A turn session that kept running after its acpmux connection was lost:
/// its later events are folded into the log, and it is removed, once acpmux
/// is back (section 7: everything the agent does is logged).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Orphan {
    pub session: String,
    /// The last event seq already folded.
    pub after: u64,
}

/// What a turn used, for the trace's `turn.end`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurnStats {
    /// The turn's first model request (reads what another turn cached).
    pub first: Option<Usage>,
    /// The turn's total (Claude Code) or its last request (codex-acp).
    pub totals: Option<(Usage, &'static str)>,
    /// What the harness says the turn cost (Claude Code's `cost_usd`).
    pub cost: Option<f64>,
    pub requests: usize,
    pub tools: usize,
    pub tool_errors: usize,
    /// From the turn's start (the settled view) to its prompt going out:
    /// the harness session's start, ms.
    pub start_ms: Option<u64>,
    /// The first request's time to first token (`fold::Request::ttft_ms`).
    pub ttft_ms: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurnOutcome {
    /// The turn's final assistant text.
    pub reply: Option<String>,
    pub error: Option<String>,
    pub orphan: Option<Orphan>,
    /// The turn ended with stop reason `cancelled` (stopped for a newer message).
    pub cancelled: bool,
    pub stats: TurnStats,
    /// The harness the turn ran on (harness_gate); None before admission.
    /// Boxed: the outcome travels in `Input::TurnEnded`.
    pub harness: Option<Box<Admitted>>,
    /// The gate refused the harness (`error` says why): nothing ran on it,
    /// or acpmux moved the session onto a refused profile.
    pub refused: bool,
    /// The turn's last draft (`done`), published after its reply is posted.
    pub done_draft: Option<crate::draft::Draft>,
    /// The session this turn left running for the next turn (`TurnStart::keep`
    /// and a clean end); None: the session was ended.
    pub kept: Option<Kept>,
}

/// The error of a turn whose acpmux connection was lost while it ran.
pub const CONNECTION_LOST: &str = "the acpmux connection was lost during the turn";

/// The waits before each new try of a turn's `session/new` that failed for
/// a passing reason: about 7 s in all, inside the turn's limit.
const NEW_SESSION_BACKOFF: [Duration; 3] = [
    Duration::from_millis(500),
    Duration::from_secs(2),
    Duration::from_secs(4),
];

/// Errors of a turn's `session/new` that a new try can cure: the harness
/// process closed as it started (`sr2 claude` exits while the sr2 gateway
/// answers 502 or refuses), the agent host missed its hello, the acpmux link
/// was between daemons (an update relaunch hands the daemon off), or the
/// upstream answered a passing error. A setup error (a refused env key, a
/// login) fails at once.
const TRANSIENT_SESSION_FAILURES: [&str; 13] = [
    "agent process closed",
    "agent host did not answer hello",
    "agent host exited before it was ready",
    "connection closed",
    "not connected",
    "is shutting down",
    "Connection refused",
    "ECONNREFUSED",
    "ECONNRESET",
    "502",
    "503",
    "504",
    "the CLI exited",
];

/// Whether a turn's `session/new` error is worth a new try.
pub fn is_transient_session_failure(error: &str) -> bool {
    TRANSIENT_SESSION_FAILURES.iter().any(|t| error.contains(t))
}

/// `session/new`, tried again after each [`NEW_SESSION_BACKOFF`] wait while
/// it fails for a passing reason. A stop request, the turn's deadline or a
/// setup error ends the tries with the last error.
fn new_session_with_retry(
    agents: &dyn AgentPort,
    spec: &SessionSpec,
    interrupt: &Interrupt,
    deadline: Option<Instant>,
    note: &dyn Fn(&str, Duration),
) -> Result<String, String> {
    let mut waits = NEW_SESSION_BACKOFF.iter();
    loop {
        let error = match agents.new_session(spec) {
            Ok(id) => return Ok(id),
            Err(e) => e,
        };
        let Some(&wait) = waits.next() else {
            return Err(error);
        };
        if !is_transient_session_failure(&error)
            || interrupt.is_set()
            || deadline.is_some_and(|d| Instant::now() + wait >= d)
        {
            return Err(error);
        }
        note(&error, wait);
        // A bounded wait that a stop request ends early (never a poll).
        if interrupt.wait(wait) {
            return Err(error);
        }
        // A start that failed halfway can leave its name taken.
        if let Ok(Some(old)) = agents.find(&spec.name) {
            let _ = agents.end_session(&old);
        }
    }
}

/// A turn the harness gate refused: traced, and posted as its error.
fn refused(trace: &Trace, start: &TurnStart, reason: &str) -> TurnOutcome {
    crate::harness_gate::trace_refusal(trace, "turn", &start.session.harness, reason);
    TurnOutcome {
        error: Some(crate::harness_gate::refusal(reason)),
        refused: true,
        ..TurnOutcome::default()
    }
}

/// Runs the turn to its end; never panics on a port failure (it becomes the
/// outcome's error, and the brain posts it). `progress` hears the session id
/// once it exists and the fold position after each fetch that moved it.
pub fn run(
    agents: &dyn AgentPort,
    chat: &OptChat,
    start: &TurnStart,
    interrupt: &Interrupt,
    log: &dyn Fn(&str),
    progress: &dyn Fn(&str, u64),
    trace: &Trace,
) -> TurnOutcome {
    run_with_drafts(
        agents,
        chat,
        start,
        interrupt,
        log,
        progress,
        trace,
        &|_| {},
        &|_| {},
    )
}

/// `run`, publishing drafts of the reply as it streams (`draft.rs`) and the
/// turn's run record as it changes (`run.rs`).
#[allow(clippy::too_many_arguments)]
pub fn run_with_drafts(
    agents: &dyn AgentPort,
    chat: &OptChat,
    start: &TurnStart,
    interrupt: &Interrupt,
    log: &dyn Fn(&str),
    progress: &dyn Fn(&str, u64),
    trace: &Trace,
    draft: &dyn Fn(crate::draft::Draft),
    run: &dyn Fn(crate::run::RunUpdate),
) -> TurnOutcome {
    let scope = serde_json::json!({"turn": start.key});
    let began = Instant::now();
    // The limit covers the session's start too: a harness that never
    // initializes must not hold the turn (and every later message) forever.
    let deadline = start.limit.map(|limit| Instant::now() + limit);
    // Set once the session exists: entries folded from it carry its fold
    // position in their transaction.
    let folding: std::cell::RefCell<Option<String>> = std::cell::RefCell::new(None);
    let append_at = |entries: Vec<Entry>, seq: u64| {
        let session = folding.borrow().clone();
        append_folded(chat, session.as_deref(), &entries, seq, log);
    };
    // Claude only through acpmux's own Claude Code adapter: the profile is
    // found by kind and command, never by the name alone.
    let admitted = match crate::harness_gate::admit_live(agents, &start.session.harness) {
        Ok(admitted) => admitted,
        Err(reason) => {
            log(&format!("turn {}: {reason}", start.key));
            return refused(trace, start, &reason);
        }
    };
    let spec = SessionSpec {
        harness: admitted.profile.clone(),
        ..start.session.clone()
    };
    if let Some(old) = &start.retire {
        let _ = agents.end_session(old);
    }
    // The kept session, while acpmux still has it and nothing waits in it.
    let reused = start.reuse.as_ref().and_then(Reuse::take).and_then(|r| {
        use cmux_chief::acp::SessionStatus as S;
        let alive = matches!(
            agents.session(&r.kept.session),
            Ok(Some(s)) if !matches!(s.status, S::Closed | S::Disconnected | S::Waiting)
        );
        if !alive {
            log(&format!(
                "turn {}: the kept session {} is gone; starting a new one",
                start.key, r.kept.session
            ));
            let _ = agents.end_session(&r.kept.session);
        }
        alive.then_some(r)
    });
    let session = match reused {
        Some(r) => r.kept.session.clone(),
        None => {
            // A session of this name is left from a host that stopped mid-turn.
            if let Ok(Some(old)) = agents.find(&start.session.name) {
                let _ = agents.end_session(&old);
            }
            // The cached layout: the stable prefix (system text and view head) is
            // the preset's system prompt, which acpmux writes into its own preset
            // directory and checks by sha256 when the session starts.
            if let Some(text) = &start.system_prompt {
                let set = match &start.session.preset {
                    Some(preset) => agents.set_system_prompt(preset, text),
                    None => Err("the cached layout needs the turn preset".to_owned()),
                };
                if let Err(e) = set {
                    return TurnOutcome {
                        error: Some(format!("setting the turn's system prompt: {e}")),
                        ..TurnOutcome::default()
                    };
                }
            }
            match new_session_with_retry(agents, &spec, interrupt, deadline, &|e, wait| {
                log(&format!(
                    "turn {}: {e}; the session starts again in {} ms",
                    start.key,
                    wait.as_millis()
                ))
            }) {
                Ok(id) => id,
                Err(e) => {
                    return TurnOutcome {
                        error: Some(e),
                        harness: Some(Box::new(admitted)),
                        ..TurnOutcome::default()
                    };
                }
            }
        }
    };
    // A kept session's earlier turns are in the log already.
    let after = reused.map_or(0, |r| r.kept.after);
    let mut fold = TurnFold::after(after);
    // acpmux resolves a name that is also a family through its preference
    // list: the session's own harness is what answers.
    let admitted = match crate::harness_gate::session_harness(agents, &session, &admitted) {
        Ok(actual) => actual,
        Err(reason) => {
            log(&format!("turn {}: {reason}", start.key));
            let _ = agents.end_session(&session);
            return refused(trace, start, &reason);
        }
    };
    // codex under approve-all: no workspace-write sandbox, so the turn's
    // cmux calls reach the app and daemon sockets (E6). Before the prompt.
    if let Some(mode) = crate::acpmux::chief_session_mode(admitted.family, &start.session.policy)
        && let Err(e) = agents.set_mode(&session, mode)
    {
        log(&format!(
            "turn {}: {e}; its cmux calls may be sandboxed",
            start.key
        ));
    }
    folding.replace(Some(session.clone()));
    let drafter = std::cell::RefCell::new(crate::draft::Drafter::new(
        &start.key,
        Some(admitted.profile.clone()),
    ));
    // Steps in appends the owner takes, then the summary on its own: a refused step append
    // never loses the run's start or end.
    let send_run = |summary: serde_json::Map<String, Value>,
                    steps: Vec<Value>,
                    images: Vec<crate::run::RunImage>| {
        let mut images = Some(images);
        for chunk in crate::run::chunks(steps) {
            run(crate::run::RunUpdate {
                turn: start.key.clone(),
                run: serde_json::Map::new(),
                steps: chunk,
                images: images.take().unwrap_or_default(),
                live: Vec::new(),
            });
        }
        if !summary.is_empty() {
            run(crate::run::RunUpdate {
                turn: start.key.clone(),
                run: summary,
                steps: Vec::new(),
                images: Vec::new(),
                live: Vec::new(),
            });
        }
    };
    let publish = |fold: &mut TurnFold| {
        let (closed, open) = fold.take_segments();
        for d in drafter.borrow_mut().update(closed, open, Instant::now()) {
            draft(d);
        }
        // The live frames first: a step's last delta before its row.
        let live = fold.take_run_live();
        if !live.is_empty() {
            run(crate::run::RunUpdate {
                turn: start.key.clone(),
                run: serde_json::Map::new(),
                steps: Vec::new(),
                images: Vec::new(),
                live,
            });
        }
        let steps = fold.take_run_steps(Instant::now(), false);
        if !steps.is_empty() {
            let images = fold.take_run_images();
            send_run(serde_json::Map::new(), steps, images);
        }
    };
    // The run is on the conversation before the harness acts.
    send_run(
        crate::run::started(
            &session,
            &admitted.profile,
            spec.model.as_deref(),
            crate::run::epoch_ms(),
        ),
        Vec::new(),
        Vec::new(),
    );
    // The session is on record before it can act: a host that stops from
    // here on folds what it did at the next start, even if the brain never
    // saved the id (it hears of it through `progress`, later).
    append_folded(chat, Some(&session), &[], after, log);
    progress(&session, after);
    let (tx, rx) = channel();
    interrupt.wake_with(Some(tx.clone()));
    let blocks = reused.map_or_else(|| start.blocks.clone(), |r| r.blocks.clone());
    if let Err(e) = agents.start_prompt(&session, blocks, &start.prompt_id, tx) {
        interrupt.wake_with(None);
        let _ = agents.end_session(&session);
        if reused.is_some() {
            // The kept session refused the prompt: a fresh one takes the turn.
            log(&format!(
                "turn {}: the kept session {session} refused the prompt ({e}); starting a new one",
                start.key
            ));
            return run_with_drafts(
                agents, chat, start, interrupt, log, progress, trace, draft, run,
            );
        }
        return TurnOutcome {
            error: Some(e),
            ..TurnOutcome::default()
        };
    }
    let start_ms = Some(began.elapsed().as_millis() as u64);
    let fetch = |fold: &mut TurnFold| -> Result<(), String> {
        let before = fold.seq();
        let mut entries = Vec::new();
        for event in agents.events(&session, fold.seq())? {
            entries.extend(fold.apply(&event));
        }
        crate::trace::tools(trace, &scope, fold.take_tool_traces());
        if fold.seq() != before {
            // The entries and the position they reach, in one transaction.
            append_at(entries, fold.seq());
            optchat_host::fault("turn:after-fold");
            progress(&session, fold.seq());
            publish(fold);
        }
        Ok(())
    };
    let mut last_fetch = Instant::now();
    let mut stream_due: Option<Instant> = None;
    let mut orphan = None;
    let mut totals = None;
    let mut cost = None;
    // The prompt's answer arrived (or never will: lost, past the limit).
    let mut answered = false;
    let mut last_cancel: Option<Instant> = None;
    // The prompt's answer was an error (even one after the fold ended on
    // `turn_end`): the session is not kept.
    let mut answer_failed = false;
    let mut last_event = Instant::now();
    loop {
        // A newer human message: stop the model at once, but let a running
        // tool call finish (Claude Code's interrupt would abort it), and
        // send the stop again until the turn ends. Read the newest events
        // first: a tool may have started since the last fetch.
        if interrupt.is_set()
            && last_cancel.is_none()
            && fold.ended().is_none()
            && let Err(e) = fetch(&mut fold)
        {
            log(&format!("turn {}: {e}", start.key));
        }
        let stopping = interrupt.is_set()
            && fold.ended().is_none()
            && (interrupt.is_hard() || !fold.tool_running());
        if stopping && last_cancel.is_none_or(|t| t.elapsed() >= CANCEL_RESEND) {
            if last_cancel.is_none() {
                log(&format!(
                    "turn {}: a new message arrived; interrupting session {session}",
                    start.key
                ));
            }
            if let Err(e) = agents.cancel(&session) {
                log(&format!("turn {}: interrupting: {e}", start.key));
            }
            last_cancel = Some(Instant::now());
        }
        let resend = last_cancel.filter(|_| stopping).map(|t| t + CANCEL_RESEND);
        // A turn that waits on a permission request is idle too: its
        // running tool is not at work, and nobody may ever answer.
        let idle_at = start
            .idle_limit
            .filter(|_| (!fold.tool_running() || fold.awaits_permission()) && last_cancel.is_none())
            .map(|limit| last_event + limit);
        if idle_at.is_some_and(|at| Instant::now() >= at) {
            answered = true;
            let _ = agents.cancel(&session);
            let _ = fetch(&mut fold);
            let limit = start.idle_limit.unwrap_or_default();
            log(&format!("turn {}: {}", start.key, idle_error(limit)));
            let seq = fold.seq();
            append_at(fold.finish(Some(idle_error(limit))), seq);
            break;
        }
        let wake = [deadline, resend, stream_due, idle_at]
            .into_iter()
            .flatten()
            .min();
        let signal = match wake {
            None => rx.recv().unwrap_or(TurnSignal::Lost),
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(signal) => signal,
                Err(RecvTimeoutError::Timeout)
                    if stream_due.is_some_and(|due| Instant::now() >= due) =>
                {
                    TurnSignal::Noted
                }
                Err(RecvTimeoutError::Timeout) if deadline.is_none_or(|d| Instant::now() < d) => {
                    continue;
                }
                Err(RecvTimeoutError::Timeout) => {
                    answered = true;
                    let _ = fetch(&mut fold);
                    let limit = start.limit.unwrap_or_default();
                    let seq = fold.seq();
                    append_at(
                        fold.finish(Some(format!(
                            "the turn ran past its limit of {} minutes and was stopped",
                            limit.as_secs() / 60
                        ))),
                        seq,
                    );
                    break;
                }
                Err(RecvTimeoutError::Disconnected) => TurnSignal::Lost,
            },
        };
        // Only the harness's own events are progress: our steers' echoes,
        // a stop request and the draft timer are not (the idle watchdog).
        if matches!(signal, TurnSignal::Changed | TurnSignal::Streamed) {
            last_event = Instant::now();
        }
        let signal = match signal {
            TurnSignal::Noted => TurnSignal::Changed,
            other => other,
        };
        // Streamed text is read at most every STREAM_GAP; a change at once.
        let signal = match signal {
            TurnSignal::Streamed if last_fetch.elapsed() < crate::draft::STREAM_GAP => {
                stream_due.get_or_insert(last_fetch + crate::draft::STREAM_GAP);
                continue;
            }
            TurnSignal::Streamed => TurnSignal::Changed,
            other => other,
        };
        // Coalesce a burst of change signals into one fetch.
        let signal = match signal {
            TurnSignal::Changed => {
                let mut last = TurnSignal::Changed;
                loop {
                    match rx.try_recv() {
                        Ok(TurnSignal::Changed | TurnSignal::Streamed) => {
                            last_event = Instant::now();
                        }
                        Ok(TurnSignal::Noted) => {}
                        Ok(other) => {
                            last = other;
                            break;
                        }
                        Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                    }
                }
                last
            }
            other => other,
        };
        match signal {
            TurnSignal::Streamed => {}
            TurnSignal::Changed | TurnSignal::Noted => {
                stream_due = None;
                last_fetch = Instant::now();
                if let Err(e) = fetch(&mut fold) {
                    log(&format!("turn {}: {e}", start.key));
                }
                if fold.ended().is_some() {
                    break;
                }
            }
            TurnSignal::Done(answer) => {
                answered = true;
                answer_failed = answer.is_err();
                totals = answer.as_ref().ok().and_then(answer_usage);
                cost = answer.as_ref().ok().and_then(answer_cost);
                let stopped = answer
                    .as_ref()
                    .ok()
                    .and_then(|v| v.get("stopReason"))
                    .and_then(Value::as_str)
                    .and_then(stop_error);
                let fetched = fetch(&mut fold);
                let error = answer.err().or_else(|| fetched.err()).or(stopped);
                let seq = fold.seq();
                append_at(fold.finish(error), seq);
                break;
            }
            TurnSignal::Lost => {
                answered = true;
                // The session may still run and act: it cannot be ended now
                // (no connection), so the brain keeps it as an orphan. What
                // can still be read is folded now (a fetch fails harmlessly
                // when the connection is really gone).
                let _ = fetch(&mut fold);
                orphan = Some(Orphan {
                    session: session.clone(),
                    after: fold.seq(),
                });
                let seq = fold.seq();
                append_at(fold.finish(Some(CONNECTION_LOST.into())), seq);
                break;
            }
        }
    }
    // What the turn's end closed (every streaming step's last live frame,
    // before the run's end and the reply: the reply replaces the streaming
    // text with no jump), then the last draft (the brain publishes it once
    // the reply is posted).
    fold.close_run_steps();
    publish(&mut fold);
    let done_draft = Some(drafter.borrow_mut().done());
    // The fold ended on `turn_end`: the answer with the token use follows.
    let until = Instant::now() + ANSWER_WAIT;
    while !answered {
        match rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(TurnSignal::Changed | TurnSignal::Noted | TurnSignal::Streamed) => {}
            Ok(TurnSignal::Done(answer)) => {
                totals = answer.as_ref().ok().and_then(answer_usage);
                cost = answer.as_ref().ok().and_then(answer_cost);
                answer_failed = answer.is_err();
                answered = true;
            }
            Ok(TurnSignal::Lost) | Err(_) => {
                answer_failed = true;
                answered = true;
            }
        }
    }
    interrupt.wake_with(None);
    log(&usage_line(&start.key, fold.first_usage(), totals));
    crate::trace::tools(trace, &scope, fold.take_tool_traces());
    let mut requests = fold.requests().to_vec();
    // codex-acp reports no per-request lines: its last request stands in.
    if requests.is_empty()
        && let Some((u, "last request")) = totals
    {
        requests.push(crate::fold::Request {
            id: String::new(),
            model: start.session.model.clone(),
            usage: u,
            ..crate::fold::Request::default()
        });
    }
    crate::trace::requests(trace, &scope, &requests);
    let (tools, tool_errors) = fold.tool_counts();
    // A fallback can move a session onto another profile mid-turn: what it
    // ran on at the end is recorded, and a refused one is said.
    let (admitted, moved) = match &orphan {
        Some(_) => (admitted, None),
        None => match crate::harness_gate::session_harness(agents, &session, &admitted) {
            Ok(actual) => (actual, None),
            Err(reason) => {
                log(&format!("turn {}: {reason}", start.key));
                crate::harness_gate::trace_refusal(trace, "turn", &start.session.harness, &reason);
                (admitted, Some(crate::harness_gate::refusal(&reason)))
            }
        },
    };
    let error = fold.ended().and_then(|e| e.error.clone());
    let cancelled = is_cancelled(error.as_deref());
    // Only a clean end keeps the session: a failed, stopped or moved one may
    // hold a half-done step, and the next turn starts from the view again.
    let kept = (start.keep
        && orphan.is_none()
        && moved.is_none()
        && error.is_none()
        && !answer_failed
        && !cancelled
        && fold.ended().is_some())
    .then(|| Kept {
        session: session.clone(),
        after: fold.seq(),
    });
    if orphan.is_none()
        && kept.is_none()
        && let Err(e) = agents.end_session(&session)
    {
        log(&format!("ending turn session {}: {e}", start.session.name));
    }
    // The run's end: what is left of its steps, its use and cost.
    send_run(
        // A turn cut by a lost acpmux link (an update relaunch) runs again
        // on the resume note: its run ends stopped, never "failed" with the
        // link's error (user 2026-10-20 "every time i update cmux").
        crate::run::ended(
            error
                .as_deref()
                .filter(|_| orphan.is_none())
                .or(moved.as_deref()),
            cancelled || orphan.is_some(),
            totals.map(|(u, _)| u),
            cost,
            requests.last().and_then(|r| r.model.as_deref()),
        ),
        fold.take_run_steps(Instant::now(), true),
        fold.take_run_images(),
    );
    let refused = moved.is_some();
    let error = match (error, moved) {
        (Some(e), Some(m)) => Some(format!("{e}; {m}")),
        (e, m) => e.or(m),
    };
    TurnOutcome {
        reply: fold.final_text(),
        done_draft,
        cancelled,
        error,
        orphan,
        harness: Some(Box::new(admitted)),
        refused,
        kept,
        stats: TurnStats {
            first: fold.first_usage(),
            totals,
            cost,
            requests: requests.len(),
            tools,
            tool_errors,
            start_ms,
            ttft_ms: requests.first().and_then(|r| r.ttft_ms),
        },
    }
}

/// What a prompt's answer says it cost (Claude Code's `_meta.claude.cost_usd`).
pub fn answer_cost(answer: &Value) -> Option<f64> {
    answer
        .pointer("/_meta/claude/cost_usd")
        .and_then(Value::as_f64)
}

/// One host.log line per turn with its cache use (section 8: verify with the
/// usage fields). The first request shows what this turn read of the view
/// another turn cached; the totals cover the whole tool loop.
pub fn usage_line(
    key: &str,
    first: Option<Usage>,
    totals: Option<(Usage, &'static str)>,
) -> String {
    let show = |u: Option<Usage>| match u {
        Some(u) => format!(
            "read {} written {} uncached {} output {}",
            u.cache_read, u.cache_write, u.input, u.output
        ),
        None => "not reported".to_owned(),
    };
    let (scope, totals) = match totals {
        Some((u, scope)) => (scope, Some(u)),
        None => ("turn total", None),
    };
    format!(
        "turn {key} cache: first request {}; {scope} {}",
        show(first),
        show(totals)
    )
}

/// Logs folded entries; with a session, its fold position `seq` commits in
/// the same transaction (a restart resumes after it, so no entry is logged
/// twice and none is skipped).
fn append_folded(
    chat: &OptChat,
    session: Option<&str>,
    entries: &[Entry],
    seq: u64,
    log: &dyn Fn(&str),
) {
    let messages: Vec<NewMessage<'_>> = entries
        .iter()
        .map(|e| NewMessage::new(e.kind, &e.text))
        .collect();
    if messages.is_empty() && session.is_none() {
        return;
    }
    let result = chat.append_with(&messages, |_| {
        session
            .map(|s| vec![crate::state::fold_write(s, seq)])
            .unwrap_or_default()
    });
    if let Err(e) = result {
        let kinds: Vec<&str> = entries.iter().map(|e| e.kind.as_str()).collect();
        log(&format!(
            "logging {} entries ({}) failed: {e}",
            entries.len(),
            kinds.join(", ")
        ));
    }
}

/// Folds the rest of an orphaned turn into the log, then removes its
/// session. Err leaves the orphan for the next connect. It resumes after
/// the later of the orphan's saved position and the stored fold position.
pub fn adopt_orphan(
    agents: &dyn AgentPort,
    chat: &OptChat,
    orphan: &Orphan,
    log: &dyn Fn(&str),
) -> Result<(), String> {
    let after = orphan
        .after
        .max(crate::state::folded(chat, &orphan.session));
    let mut fold = TurnFold::after(after);
    let mut entries = Vec::new();
    for event in agents.events(&orphan.session, after)? {
        entries.extend(fold.apply(&event));
    }
    // Whatever it was still saying when it was removed.
    entries.extend(fold.finish(None));
    append_folded(chat, Some(&orphan.session), &entries, fold.seq(), log);
    agents.end_session(&orphan.session)?;
    if let Err(e) = chat.put_state(&[(crate::state::fold_key(&orphan.session), None)]) {
        log(&format!(
            "forgetting orphan {}'s fold position: {e}",
            orphan.session
        ));
    }
    Ok(())
}

/// The wait before a capacity refusal names no retry-after.
pub const CAPACITY_DEFAULT_WAIT: Duration = Duration::from_secs(60);
/// The longest a turn waits for capacity in all (the turn limit still
/// applies); past it the refusal is the turn's error.
pub const CAPACITY_MAX_WAIT: Duration = Duration::from_secs(2 * 60 * 60);

/// How long to wait before a turn that the model route refused for want of
/// capacity runs again: the subrouter's "no non-exhausted ... accounts"
/// (503) and the API's overload (529), at their "retry after Ns", else
/// [`CAPACITY_DEFAULT_WAIT`]. None for any other error.
pub fn capacity_retry_after(error: &str) -> Option<Duration> {
    let lower = error.to_ascii_lowercase();
    // An overload without a retry-after stays the turn's error (the shared
    // corpus, cmux-chief-corpus/1, pins "(turn failed: ...)" for it).
    let capacity = lower.contains("no non-exhausted")
        || ((lower.contains("overloaded")
            || lower.contains("api error: 529")
            || lower.contains("api error: 503"))
            && lower.contains("retry after"));
    if !capacity {
        return None;
    }
    let seconds = lower.find("retry after ").and_then(|at| {
        let digits: String = lower[at + 12..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        digits.parse::<u64>().ok()
    });
    Some(seconds.map_or(CAPACITY_DEFAULT_WAIT, Duration::from_secs))
}

/// Runs `outcome`'s turn again while its route refuses it for want of
/// capacity or cannot be reached ([`transient_retry_after`]): each time it
/// waits (a newer message ends the
/// wait, and the turn then stops as for that message), with one log line
/// and one trace event, and never posts the refusal. Past
/// [`CAPACITY_MAX_WAIT`] in all, the refusal stays the turn's error.
pub fn run_after_capacity_waits(
    mut outcome: TurnOutcome,
    start: &TurnStart,
    interrupt: &Interrupt,
    log: &dyn Fn(&str),
    trace: &Trace,
    mut again: impl FnMut(&TurnStart) -> TurnOutcome,
) -> TurnOutcome {
    let mut waited = Duration::ZERO;
    let mut attempt = 0u32;
    loop {
        let error = outcome.error.clone().unwrap_or_default();
        let Some(wait) = transient_retry_after(&error, attempt) else {
            return outcome;
        };
        let why = if capacity_retry_after(&error).is_some() {
            "the model route has no capacity now"
        } else if is_idle_error(&error) {
            "the harness stopped sending events"
        } else {
            "the model API cannot be reached now"
        };
        if outcome.reply.is_some() || waited + wait > CAPACITY_MAX_WAIT || interrupt.is_set() {
            return outcome;
        }
        attempt += 1;
        log(&format!(
            "turn {}: {why}; running the turn again in {} s (attempt {attempt})",
            start.key,
            wait.as_secs()
        ));
        trace.emit(
            "turn.capacity_wait",
            serde_json::json!({"turn": start.key, "seconds": wait.as_secs(), "attempt": attempt}),
        );
        if interrupt.wait(wait) {
            return outcome;
        }
        waited += wait;
        let mut next = start.clone();
        next.prompt_id = format!("{}:capacity{attempt}", start.prompt_id);
        outcome = again(&next);
    }
}

/// Tries a turn gets after a connection error before the error stands.
pub const CONNECTION_TRIES: u32 = 8;
/// The longest wait between two tries after a connection error.
pub const CONNECTION_MAX_WAIT: Duration = Duration::from_secs(60);

/// Whether `error` says the model API could not be reached at all (DNS,
/// refused or reset connections, Claude Code's "Can't reach the API
/// server" once its own retries end).
pub fn is_connection_error(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    [
        "can't reach the api",
        "connection error",
        "enotfound",
        "econnrefused",
        "econnreset",
        "etimedout",
        "eai_again",
        "getaddrinfo",
        "fetch failed",
        "socket hang up",
        "network error",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

/// The wait before try `attempt` (0-based) runs a turn again after a
/// transient error: a capacity refusal's own retry-after, or for a
/// connection error 1 s doubling to [`CONNECTION_MAX_WAIT`] for
/// [`CONNECTION_TRIES`] tries. None for any other error, and once the tries
/// are spent.
pub fn transient_retry_after(error: &str, attempt: u32) -> Option<Duration> {
    if let Some(wait) = capacity_retry_after(error) {
        return Some(wait);
    }
    // A turn the idle watchdog stopped runs once again, at once.
    if is_idle_error(error) {
        return (attempt == 0).then_some(Duration::ZERO);
    }
    if !is_connection_error(error) || attempt >= CONNECTION_TRIES {
        return None;
    }
    Some(Duration::from_secs(1u64 << attempt.min(16)).min(CONNECTION_MAX_WAIT))
}

/// The idle watchdog's default: a turn with no harness event for this long
/// ends (`OPTCHAT_CHIEF_TURN_IDLE_MIN`; 0 turns it off).
pub const DEFAULT_TURN_IDLE: Duration = Duration::from_secs(10 * 60);

/// The idle watchdog's turn error.
pub fn idle_error(limit: Duration) -> String {
    let minutes = limit.as_secs() / 60;
    if minutes > 0 {
        format!("the turn made no progress for {minutes} minutes and was stopped")
    } else {
        format!(
            "the turn made no progress for {} ms and was stopped",
            limit.as_millis()
        )
    }
}

/// Whether `error` is the idle watchdog's.
pub fn is_idle_error(error: &str) -> bool {
    error.contains("the turn made no progress for")
}
