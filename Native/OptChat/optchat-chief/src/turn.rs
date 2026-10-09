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
    /// The turn has a remote origin and no auto-approve: the native engine
    /// refuses its local effects (README "Remote-origin messages").
    gate: AtomicBool,
    /// The running acpmux turn's signals, woken on a request.
    wake: Mutex<Option<Sender<TurnSignal>>>,
}

impl Interrupt {
    pub fn new() -> Interrupt {
        Interrupt::default()
    }

    pub fn request(&self) {
        self.wanted.store(true, Ordering::SeqCst);
        if let Some(tx) = self
            .wake
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            let _ = tx.send(TurnSignal::Changed);
        }
    }

    pub fn is_set(&self) -> bool {
        self.wanted.load(Ordering::SeqCst)
    }

    /// Sets whether the turn's local effects need an approval.
    pub fn set_gate(&self, on: bool) {
        self.gate.store(on, Ordering::SeqCst);
    }

    pub fn gated(&self) -> bool {
        self.gate.load(Ordering::SeqCst)
    }

    /// The queued messages were delivered (native engine).
    pub fn clear(&self) {
        self.wanted.store(false, Ordering::SeqCst);
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
    )
}

/// `run`, publishing drafts of the reply as it streams (`draft.rs`).
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
) -> TurnOutcome {
    let scope = serde_json::json!({"turn": start.key});
    let began = Instant::now();
    // The limit covers the session's start too: a harness that never
    // initializes must not hold the turn (and every later message) forever.
    let deadline = start.limit.map(|limit| Instant::now() + limit);
    let mut fold = TurnFold::new();
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
    let session = match agents.new_session(&spec) {
        Ok(id) => id,
        Err(e) => {
            return TurnOutcome {
                error: Some(e),
                harness: Some(Box::new(admitted)),
                ..TurnOutcome::default()
            };
        }
    };
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
    folding.replace(Some(session.clone()));
    let drafter = std::cell::RefCell::new(crate::draft::Drafter::new(
        &start.key,
        Some(admitted.profile.clone()),
    ));
    let publish = |fold: &mut TurnFold| {
        let (closed, open) = fold.take_segments();
        for d in drafter.borrow_mut().update(closed, open, Instant::now()) {
            draft(d);
        }
    };
    // The session is on record before it can act: a host that stops from
    // here on folds what it did at the next start, even if the brain never
    // saved the id (it hears of it through `progress`, later).
    append_folded(chat, Some(&session), &[], 0, log);
    progress(&session, 0);
    let (tx, rx) = channel();
    interrupt.wake_with(Some(tx.clone()));
    if let Err(e) = agents.start_prompt(&session, start.blocks.clone(), &start.prompt_id, tx) {
        interrupt.wake_with(None);
        let _ = agents.end_session(&session);
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
        let stopping = interrupt.is_set() && fold.ended().is_none() && !fold.tool_running();
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
        let wake = [deadline, resend, stream_due].into_iter().flatten().min();
        let signal = match wake {
            None => rx.recv().unwrap_or(TurnSignal::Lost),
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(signal) => signal,
                Err(RecvTimeoutError::Timeout)
                    if stream_due.is_some_and(|due| Instant::now() >= due) =>
                {
                    TurnSignal::Changed
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
                        Ok(TurnSignal::Changed | TurnSignal::Streamed) => {}
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
            TurnSignal::Changed => {
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
                append_at(
                    fold.finish(Some(
                        "the acpmux connection was lost during the turn".into(),
                    )),
                    seq,
                );
                break;
            }
        }
    }
    // What the turn's end closed, then the last draft (the brain publishes
    // it once the reply is posted).
    publish(&mut fold);
    let done_draft = Some(drafter.borrow_mut().done());
    // The fold ended on `turn_end`: the answer with the token use follows.
    let until = Instant::now() + ANSWER_WAIT;
    while !answered {
        match rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(TurnSignal::Changed | TurnSignal::Streamed) => {}
            Ok(TurnSignal::Done(answer)) => {
                totals = answer.as_ref().ok().and_then(answer_usage);
                cost = answer.as_ref().ok().and_then(answer_cost);
                answered = true;
            }
            Ok(TurnSignal::Lost) | Err(_) => answered = true,
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
    if orphan.is_none()
        && let Err(e) = agents.end_session(&session)
    {
        log(&format!("ending turn session {}: {e}", start.session.name));
    }
    let error = fold.ended().and_then(|e| e.error.clone());
    let cancelled = is_cancelled(error.as_deref());
    let refused = moved.is_some();
    let error = match (error, moved) {
        (Some(e), Some(m)) => Some(format!("{e}; {m}")),
        (e, m) => e.or(m),
    };
    TurnOutcome {
        reply: fold.final_text().map(str::to_owned),
        done_draft,
        cancelled,
        error,
        orphan,
        harness: Some(Box::new(admitted)),
        refused,
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
