//! Section 9 in the brain: the spawns and their subagents (state.rs
//! `SpawnRecord`), each subagent's turn ends read from its acpmux session,
//! and the reports: each subagent's report reaches the chat as its own
//! message, `[id] report`, when it finishes (the reference client's `work`
//! message), queued like a human message (so on acpmux it stops a working
//! Chief between its tool calls, and the next turn takes it; otherwise it
//! starts a turn). Reports queued while the Chief is busy go into one turn.
//! The report of a run the user stopped (`session/cancel` in its pane) is
//! queued quiet: the next turn logs it, and it starts none.
//!
//! A report is the subagent's last finished reply: its final reply is its
//! report to the Chief (section 9's subagent prompt).

use cmux_chief::acp::{AcpmuxEvent, SessionStatus, SessionSummary};
use serde_json::{Value, json};

use super::children::{ended_replies, report_of};
use super::{Brain, Queued, Source};
use crate::fold::TurnFold;
use crate::state::{SpawnRecord, SpawnRef, SubRecord, SubStatus};
use crate::subagents::{PROMPT_PREFIX, SpawnPlan};

fn busy(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Running | SessionStatus::Waiting)
}

fn now_ms() -> u64 {
    super::now_ms()
}

impl Brain {
    /// Gives a spawn its id and its subagents theirs (`a<N>`, unique per home).
    pub(super) fn register_spawn(&mut self, tasks: &[String]) -> Result<SpawnPlan, String> {
        if tasks.is_empty() {
            return Err("spawn needs at least one task".into());
        }
        let mut free = self
            .live_cap()
            .map_or(usize::MAX, |n| n.saturating_sub(self.live_subs()));
        let first = self.state.next_subagent.max(1);
        let ids: Vec<String> = (0..tasks.len() as u64)
            .map(|k| format!("a{}", first + k))
            .collect();
        self.state.next_subagent = first + tasks.len() as u64;
        let spawn = format!("s{first}");
        let record = SpawnRecord {
            subs: ids
                .iter()
                .zip(tasks)
                .map(|(id, task)| {
                    // Over the cap it waits for a free slot.
                    let status = if free > 0 {
                        free -= 1;
                        SubStatus::Starting
                    } else {
                        SubStatus::Queued
                    };
                    SubRecord {
                        id: id.clone(),
                        title: crate::workspaces::name(id, task),
                        run_ms: now_ms(),
                        status,
                        ..SubRecord::default()
                    }
                })
                .collect(),
            delivered: false,
            started_ms: now_ms(),
            turn: self.state.turn.as_ref().map(|t| t.key.clone()),
            answers: match self.state.turn.as_ref() {
                Some(turn) => turn.answers.clone(),
                None => self.state.last_answers.clone(),
            },
        };
        let queued: Vec<String> = record
            .subs
            .iter()
            .filter(|s| s.status == SubStatus::Queued)
            .map(|s| s.id.clone())
            .collect();
        self.state.spawns.insert(spawn.clone(), record);
        self.save();
        (self.log)(&format!("spawn {spawn}: {}", ids.join(", ")));
        Ok(SpawnPlan {
            spawn,
            ids,
            queued,
            limit: self.live_cap(),
            engine: self.spawn_engine(),
        })
    }

    pub(super) fn sub_queued(&mut self, id: &str, launch: crate::state::QueuedLaunch) {
        if let Some(sub) = self.state.sub_mut(id)
            && sub.status == SubStatus::Queued
        {
            sub.queued_launch = Some(launch);
            self.save();
        }
    }

    pub(super) fn sub_started(&mut self, id: &str, session_id: String, policy: Option<String>) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.session_id = Some(session_id);
            sub.policy = policy;
            if sub.status == SubStatus::Starting {
                sub.status = SubStatus::Running;
            }
            sub.active_ms = now_ms();
            sub.stuck_noted = false;
            // Tells wait until its task is sent (`sub_prompted`).
            sub.awaiting_task = true;
            self.save();
        }
    }

    /// Its first prompt is sent: messages told while it was starting
    /// follow it, in order.
    pub(super) fn sub_prompted(&mut self, id: &str) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.awaiting_task = false;
        }
        self.save();
        self.flush_inbox(id);
    }

    pub(super) fn sub_workspace(&mut self, id: &str, key: String, name: String) {
        let done = if let Some(sub) = self.state.sub_mut(id) {
            sub.workspace = Some(key);
            sub.title = name;
            matches!(sub.status, SubStatus::Done | SubStatus::Reported)
        } else {
            false
        };
        self.save();
        // It finished before its workspace was made.
        if done {
            self.mark_workspace(id, true);
        }
    }

    pub(super) fn sub_failed(&mut self, id: &str, error: &str) {
        let Some(sub) = self.state.sub_mut(id) else {
            return;
        };
        sub.status = SubStatus::Done;
        sub.awaiting_task = false;
        sub.report = Some(format!("(did not start: {error})"));
        sub.stopped = false;
        let spawn = self.state.sub(id).map(|(s, _)| s.clone());
        self.save();
        if let Some(spawn) = spawn {
            self.deliver(&spawn);
        }
        self.start_queued();
    }

    pub(super) fn sub_answer(&mut self, id: &str, answer: &Result<Value, String>) {
        let mut fields = crate::subagents::answer_fields(answer);
        fields["id"] = json!(id);
        if let Some((spawn, _)) = self.state.sub(id) {
            fields["spawn"] = json!(spawn);
        }
        self.trace.emit("subagent.answer", fields);
        // A prompt the harness failed ends the run with a failure report,
        // never a subagent that runs forever.
        if let Err(e) = answer
            && self
                .state
                .sub(id)
                .is_some_and(|(_, s)| s.status == SubStatus::Running)
        {
            self.sub_done(id, format!("(failed: {e})"), false, None, None);
        }
    }

    /// A session changed: when it is a subagent's, its runs and turn ends
    /// are followed here. True when it was one.
    pub(super) fn sub_changed(&mut self, session: &SessionSummary) -> bool {
        let Some(id) = self.state.sub_by_session(&session.session_id) else {
            return false;
        };
        let Some(status) = self.state.sub(&id).map(|(_, s)| s.status) else {
            return true;
        };
        if let Some(sub) = self.state.sub_mut(&id) {
            sub.active_ms = now_ms();
            if session.pending_permissions == 0 {
                sub.permission = None;
            }
        }
        if busy(session.status) {
            // Running again: a tell, or the user writing in its chat.
            if matches!(status, SubStatus::Done | SubStatus::Reported) {
                if let Some(sub) = self.state.sub_mut(&id) {
                    sub.status = SubStatus::Running;
                    sub.run_ms = now_ms();
                    sub.stuck_noted = false;
                }
                self.save();
                self.mark_workspace(&id, false);
                self.trace.emit("subagent.resume", json!({"id": id}));
            }
            return true;
        }
        if status != SubStatus::Running {
            return true;
        }
        match session.status {
            SessionStatus::Idle | SessionStatus::Ready => self.finish_sub(&id, &session.session_id),
            SessionStatus::Closed | SessionStatus::Disconnected => {
                let report = format!(
                    "(stopped without a report: its session is {:?})",
                    session.status
                );
                self.sub_done(&id, report, false, None, None);
            }
            _ => {}
        }
        true
    }

    /// Reads a subagent's turn ends since its floor; when one ended, its
    /// last reply is its report.
    fn finish_sub(&mut self, id: &str, session_id: &str) {
        let floor = self.state.sub(id).map_or(0, |(_, s)| s.floor);
        let events = match self.agents.events(session_id, floor) {
            Ok(events) => events,
            Err(e) => {
                (self.log)(&format!("subagent {id}: its report could not be read: {e}"));
                return;
            }
        };
        let (replies, last_end, cancelled) = ended_replies(&events);
        // Idle before its prompt started (a new session is ready first).
        let Some(last_end) = last_end else { return };
        self.trace_sub_events(id, &events, floor);
        let report = report_of(&replies, cancelled);
        self.sub_done(id, report, cancelled, Some(last_end), Some(&events));
    }

    fn sub_done(
        &mut self,
        id: &str,
        report: String,
        stopped: bool,
        floor: Option<u64>,
        events: Option<&[AcpmuxEvent]>,
    ) {
        let Some((spawn, held)) = self
            .state
            .sub(id)
            .map(|(s, sub)| (s.clone(), sub.paused || sub.cancelled))
        else {
            return;
        };
        // control interrupt|restart with a message: the cut run reports
        // nothing; the message is its next prompt, sent now that it stopped.
        let follow = self.state.sub_mut(id).and_then(|s| s.after_stop.take());
        if let Some(message) = follow {
            if let Some(sub) = self.state.sub_mut(id) {
                if let Some(floor) = floor {
                    sub.floor = floor;
                }
                sub.status = SubStatus::Done;
            }
            self.save();
            match self.tell(id, &message) {
                Ok(_) => {
                    self.trace.emit("subagent.after_stop", json!({"id": id}));
                    return;
                }
                Err(e) => (self.log)(&format!("subagent {id}: its follow-up failed: {e}")),
            }
        }
        // A run that stopped on an error: its report becomes "stopped: ..."
        // (quiet while an auto-resume is planned) and the continue is set up.
        // Never for one the Chief paused or cancelled.
        let planned = if held {
            None
        } else {
            self.plan_auto_resume(id, &report, stopped)
        };
        let (report, stopped) = match planned {
            Some((note, quiet)) => (note, quiet),
            None => (report, stopped),
        };
        let run_ms = if let Some(sub) = self.state.sub_mut(id) {
            sub.status = SubStatus::Done;
            sub.awaiting_task = false;
            sub.report = Some(report.clone());
            sub.stopped = stopped;
            if let Some(floor) = floor {
                sub.floor = floor;
            }
            sub.run_ms
        } else {
            0
        };
        self.save();
        let (tools, tool_errors) = events.map_or((0, 0), |events| {
            let mut fold = TurnFold::new();
            for e in events {
                fold.apply(e);
            }
            fold.tool_counts()
        });
        self.trace.emit(
            "subagent.done",
            json!({
                "id": id,
                "spawn": spawn,
                "ms": now_ms().saturating_sub(run_ms),
                "report": self.trace.text(&report),
                "tools": tools,
                "tool_errors": tool_errors,
                "stopped": stopped,
            }),
        );
        (self.log)(&format!("subagent {id} finished"));
        self.mark_workspace(id, true);
        self.deliver(&spawn);
        self.start_queued();
    }

    /// Auto-resume (auto_resume.rs) of subagent `id`, whose run just ended
    /// with `report`: None when there is nothing to do (a real report, a
    /// user stop, or auto-resume off); else the note that replaces its
    /// report (`stopped: ...`) and whether it is quiet (a continue is
    /// planned, so the Chief need not act).
    fn plan_auto_resume(
        &mut self,
        id: &str,
        report: &str,
        stopped: bool,
    ) -> Option<(String, bool)> {
        use crate::auto_resume::{Decision, StopKind, chief_note, classify, decide};
        let policy = self.resume_policy?;
        let kind = classify(report, stopped);
        let attempts = self.state.sub(id).map_or(0, |(_, s)| s.resume_attempts);
        if matches!(kind, StopKind::Done | StopKind::UserStopped) {
            if attempts != 0
                && let Some(sub) = self.state.sub_mut(id)
            {
                sub.resume_attempts = 0;
            }
            return None;
        }
        // A network stop always waits on the probe (off this thread); it
        // returns at once when the endpoint answers.
        let decision = decide(&kind, attempts, &policy, false);
        let note = chief_note(&decision)?;
        self.trace.emit(
            "subagent.auto_resume",
            json!({"id": id, "kind": format!("{kind:?}"), "attempts": attempts, "decision": format!("{decision:?}")}),
        );
        // WARN: the error journal (`cmux errors`) harvests host.log lines by level word.
        (self.log)(&format!("WARN subagent {id}: {note}"));
        match decision {
            Decision::Report { .. } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = 0;
                }
                Some((note, false))
            }
            Decision::Retry {
                reason,
                attempt,
                delay,
            } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = attempt;
                }
                let (tx, id) = (self.tx.clone(), id.to_owned());
                std::thread::spawn(move || {
                    // A bounded backoff before the retry (auto_resume.rs).
                    std::thread::sleep(delay);
                    let _ = tx.send(super::Input::AutoResume {
                        id,
                        attempt,
                        reason,
                        after_network: false,
                        online: true,
                    });
                });
                Some((note, true))
            }
            Decision::WaitOnline { reason, attempt } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = attempt;
                }
                let (tx, id, reach) = (self.tx.clone(), id.to_owned(), self.reach.clone());
                let settle = policy.backoff(1).min(std::time::Duration::from_secs(15));
                std::thread::spawn(move || {
                    let online = crate::auto_resume::wait_online(
                        &*reach,
                        crate::auto_resume::NETWORK_POLL,
                        crate::auto_resume::NETWORK_WAIT_MAX,
                        std::thread::sleep,
                    );
                    if online {
                        // Let the link settle before the request.
                        std::thread::sleep(settle);
                    }
                    let _ = tx.send(super::Input::AutoResume {
                        id,
                        attempt,
                        reason,
                        after_network: true,
                        online,
                    });
                });
                Some((note, true))
            }
        }
    }

    /// An auto-resume of `id` is due: it is told to continue (its chat shows
    /// the `[auto-resume N]` message), unless it runs again already, a newer
    /// stop replaced this one, or the network never came back (then the
    /// stop is reported).
    pub(super) fn auto_resume_due(
        &mut self,
        id: &str,
        attempt: u32,
        reason: &str,
        after_network: bool,
        online: bool,
    ) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let current = sub.resume_attempts == attempt
            && matches!(sub.status, SubStatus::Done | SubStatus::Reported);
        if !current {
            self.trace.emit(
                "subagent.auto_resume.skip",
                json!({"id": id, "attempt": attempt, "status": format!("{:?}", sub.status)}),
            );
            return;
        }
        if !online {
            let spawn = self.state.sub(id).map(|(s, _)| s.clone());
            if let Some(sub) = self.state.sub_mut(id) {
                sub.resume_attempts = 0;
                sub.status = SubStatus::Done;
                sub.stopped = false;
                sub.report = Some(format!(
                    "stopped: {reason}. The model endpoint did not answer for {} min, so auto-resume stopped waiting; tell it to continue when the network is back.",
                    crate::auto_resume::NETWORK_WAIT_MAX.as_secs() / 60
                ));
            }
            self.save();
            if let Some(spawn) = spawn {
                self.deliver(&spawn);
            }
            return;
        }
        let message = crate::auto_resume::continue_prompt(reason, attempt, after_network);
        match self.tell(id, &message) {
            Ok(_) => {
                (self.log)(&format!("subagent {id}: auto-resume {attempt} sent"));
                self.trace.emit(
                    "subagent.auto_resume.sent",
                    json!({"id": id, "attempt": attempt, "after_network": after_network}),
                );
            }
            Err(e) => (self.log)(&format!("subagent {id}: auto-resume {attempt} failed: {e}")),
        }
    }

    /// The subagent's tool calls, model requests and the messages the user
    /// typed into its chat, into the trace (never into the memory).
    fn trace_sub_events(&self, id: &str, events: &[AcpmuxEvent], floor: u64) {
        if !self.trace.is_on() {
            return;
        }
        let scope = json!({"subagent": id});
        let mut fold = TurnFold::after(floor);
        for e in events {
            fold.apply(e);
            if e.dir == "mux" && e.kind == "user_message" {
                let prompt_id = e.msg.get("promptId").and_then(Value::as_str).unwrap_or("");
                if !prompt_id.starts_with(PROMPT_PREFIX) {
                    let text = user_text(&e.msg);
                    self.trace.emit(
                        "subagent.input",
                        json!({"id": id, "from": "user", "text": self.trace.text(&text)}),
                    );
                }
            }
        }
        crate::trace::tools(&self.trace, &scope, fold.take_tool_traces());
        crate::trace::requests(&self.trace, &scope, fold.requests());
    }

    /// Renames a subagent's workspace: done mark on, or off when it runs
    /// again; or, under the close setting, closes it when it finishes.
    fn mark_workspace(&mut self, id: &str, done: bool) {
        let (Some(workspaces), Some((_, sub))) = (self.workspaces.clone(), self.state.sub(id))
        else {
            return;
        };
        let Some(key) = sub.workspace.clone() else {
            return;
        };
        let title = sub.title.clone();
        if done && self.sub_close_on_finish {
            if let Some(sub) = self.state.sub_mut(id) {
                sub.workspace = None;
            }
            self.save();
            let (log, id) = (self.log.clone(), id.to_owned());
            std::thread::spawn(move || {
                if let Err(e) = workspaces.close(&key) {
                    log(&format!("subagent {id}: closing its workspace: {e}"));
                }
            });
            return;
        }
        let name = if done {
            crate::workspaces::done_name(&title)
        } else {
            title.clone()
        };
        let log = self.log.clone();
        let id = id.to_owned();
        std::thread::spawn(move || {
            if let Err(e) = workspaces.rename(&key, &name) {
                log(&format!("subagent {id}: renaming its workspace: {e}"));
            }
        });
    }

    /// Queues each finished subagent's report of `spawn` as its own item
    /// (or updates the one still queued). A stopped run's is quiet.
    pub(super) fn deliver(&mut self, spawn: &str) {
        let Some(record) = self.state.spawns.get(spawn) else {
            return;
        };
        let done: Vec<(String, String, u64, bool)> = record
            .subs
            .iter()
            .filter(|s| s.status == SubStatus::Done)
            .map(|s| {
                let report = s.report.as_deref().unwrap_or("");
                let footer = crate::agent_chat::footer(&s.id);
                (
                    s.id.clone(),
                    format!("[{}] {report}\n{footer}", s.id),
                    s.floor,
                    s.stopped,
                )
            })
            .collect();
        for (id, text, floor, quiet) in done {
            let source = Source::Spawn(SpawnRef {
                spawn: spawn.to_owned(),
                subs: vec![(id.clone(), floor)],
                quiet,
            });
            // On its way into the running turn (a steer not read yet): it is
            // logged when the harness reads it, never queued twice.
            let steering = self.steering.iter().any(|st| {
                st.items.iter().any(|q| {
                    matches!(&q.source, Source::Spawn(r) if r.spawn == spawn && r.subs.iter().any(|(s, _)| *s == id))
                })
            });
            if steering {
                continue;
            }
            let queued = self.queue.iter().position(|q| {
                matches!(&q.source, Source::Spawn(r) if r.spawn == spawn && r.subs.iter().any(|(s, _)| *s == id))
            });
            match queued {
                Some(k) => {
                    self.queue[k] = Queued {
                        text,
                        source,
                        images: Vec::new(),
                        conversation: None,
                        logged: false,
                    }
                }
                None => {
                    (self.log)(&format!("subagent {id}: queued its report"));
                    self.queue(text, source);
                }
            }
        }
    }

    /// The report reached the log (as `user`): the trace's `spawn.report`.
    pub(super) fn trace_report_logged(&self, r: &SpawnRef, text: &str) {
        let started = self.state.spawns.get(&r.spawn).map_or(0, |s| s.started_ms);
        self.trace.emit(
            "spawn.report",
            json!({
                "spawn": r.spawn,
                "ids": r.subs.iter().map(|(id, _)| id).collect::<Vec<_>>(),
                "text": self.trace.text(text),
                "ms_since_spawn": now_ms().saturating_sub(started),
            }),
        );
    }

    /// `tell(id, message, key)`: never fails for a known subagent. One that
    /// has no session yet (queued or starting) or is paused keeps it in its
    /// saved inbox, delivered in order the moment it can take it; a queued
    /// one gets it with its task. A repeat of `key` is not sent again.
    pub(super) fn tell_keyed(
        &mut self,
        id: &str,
        message: &str,
        key: Option<&str>,
    ) -> Result<String, String> {
        let Some((_, sub)) = self.state.sub(id) else {
            return Err(format!("no subagent {id}"));
        };
        if let Some(key) = key
            && sub.tell_keys.iter().any(|k| k == key)
        {
            return Ok(format!(
                "outcome: noop. {id} already has this message (key {key}); it was not sent again"
            ));
        }
        let hold = sub.session_id.is_none()
            || sub.awaiting_task
            || sub.paused
            || sub.status == SubStatus::Queued;
        let cancelled = sub.cancelled;
        if cancelled {
            return Ok(format!(
                "outcome: refused. {id} was cancelled; control(action: \"restart\", id: \"{id}\") brings it back"
            ));
        }
        if let Some(key) = key
            && let Some(sub) = self.state.sub_mut(id)
        {
            sub.tell_keys.push(key.to_owned());
            let over = sub
                .tell_keys
                .len()
                .saturating_sub(crate::state::TELL_KEYS_KEPT);
            sub.tell_keys.drain(..over);
        }
        if hold {
            let (status, paused, waiting) = {
                let sub = self.state.sub_mut(id).expect("checked above");
                sub.inbox.push(crate::state::InboxMessage {
                    text: message.to_owned(),
                    at_ms: now_ms(),
                });
                (sub.status, sub.paused, sub.inbox.len())
            };
            self.save();
            self.trace.emit(
                "tell.queued",
                json!({"id": id, "waiting": waiting, "message": self.trace.text(message)}),
            );
            let why = if paused {
                "it is paused; it gets it on control resume".to_owned()
            } else if status == SubStatus::Queued {
                "it is queued; the message goes in with its task when it starts".to_owned()
            } else {
                "it is starting; it gets it the moment its session exists".to_owned()
            };
            return Ok(format!(
                "outcome: queued. Queued for delivery to {id} ({waiting} waiting): {why}. You get a note when it is delivered."
            ));
        }
        self.tell(id, message)
            .map(|answer| format!("outcome: done. {answer}"))
    }

    /// Delivers subagent `id`'s inbox now that it can take it (its session
    /// exists, it is not paused), in order, as one message; a quiet note
    /// tells the Chief.
    pub(super) fn flush_inbox(&mut self, id: &str) {
        let messages = match self.state.sub_mut(id) {
            Some(sub)
                if sub.session_id.is_some()
                    && !sub.awaiting_task
                    && !sub.paused
                    && !sub.inbox.is_empty() =>
            {
                std::mem::take(&mut sub.inbox)
            }
            _ => return,
        };
        self.save();
        let text = inbox_text(&messages);
        match self.tell(id, &text) {
            Ok(_) => {
                self.trace
                    .emit("tell.delivered", json!({"id": id, "count": messages.len()}));
                self.queue(
                    format!("[{id}] got {} queued message(s) from you.", messages.len()),
                    Source::Note,
                );
            }
            Err(e) => {
                (self.log)(&format!("subagent {id}: delivering its inbox: {e}"));
                if let Some(sub) = self.state.sub_mut(id) {
                    let mut back = messages;
                    back.append(&mut sub.inbox);
                    sub.inbox = back;
                }
                self.save();
            }
        }
    }

    /// `tell(id, message)`: a prompt to the subagent's session (acpmux runs
    /// it after the current turn).
    pub(super) fn tell(&mut self, id: &str, message: &str) -> Result<String, String> {
        let (spawn, session) = match self.state.sub(id) {
            Some((spawn, sub)) => (
                spawn.clone(),
                sub.session_id
                    .clone()
                    .ok_or_else(|| format!("{id} has no session yet"))?,
            ),
            None => return Err(format!("no subagent {id}")),
        };
        let prompt_id = format!("{PROMPT_PREFIX}tell:{id}:{}", now_ms());
        let blocks = vec![json!({"type": "text", "text": message})];
        let running = self
            .state
            .sub(id)
            .is_some_and(|(_, s)| matches!(s.status, SubStatus::Running | SubStatus::Starting));
        let (agents, forward, sub_id) = (self.agents.clone(), self.tx.clone(), id.to_owned());
        let steered = if running {
            // Reference parity S4: into the running session, read between
            // its tool calls; one that cannot steer now takes it as its next
            // prompt (acpmux queues it after the current turn).
            let log = self.log.clone();
            std::thread::spawn(move || {
                if let Err(e) = agents.steer(&session, blocks.clone(), &prompt_id) {
                    log(&format!(
                        "subagent {sub_id}: the tell could not be steered ({e}); it goes after the current turn"
                    ));
                    if let Err(e) = tell_prompt(
                        &*agents,
                        &session,
                        blocks,
                        &prompt_id,
                        forward,
                        sub_id.clone(),
                    ) {
                        log(&format!(
                            "subagent {sub_id}: the tell did not reach it: {e}"
                        ));
                    }
                }
            });
            true
        } else {
            tell_prompt(&*agents, &session, blocks, &prompt_id, forward, sub_id)?;
            false
        };
        let resumed = if let Some(sub) = self.state.sub_mut(id)
            && sub.status != SubStatus::Running
        {
            sub.status = SubStatus::Running;
            sub.run_ms = now_ms();
            true
        } else {
            false
        };
        self.save();
        if resumed {
            self.mark_workspace(id, false);
        }
        self.trace.emit(
            "tell",
            json!({"id": id, "spawn": spawn, "from": "chief", "steered": steered, "message": self.trace.text(message)}),
        );
        let answer = if steered {
            format!(
                "sent to {id}; it reads it between its tool calls, and its report answers it as a \"[{id}] ...\" message"
            )
        } else {
            format!(
                "sent to {id}; it reads it after its current step, and its report comes back as a \"[{id}] ...\" message"
            )
        };
        Ok(answer)
    }

    /// After a reconnect: subagents that finished or vanished meanwhile.
    pub(super) fn reconcile_spawns(&mut self, sessions: &[SessionSummary]) {
        // A host that stopped between a session and its task: nothing will
        // send that task now, so its tells go as they come.
        let held: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.awaiting_task)
            .map(|s| s.id.clone())
            .collect();
        for id in held {
            self.sub_prompted(&id);
        }
        let open: Vec<(String, Option<String>)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running))
            .map(|s| (s.id.clone(), s.session_id.clone()))
            .collect();
        for (id, session) in open {
            match session {
                None => self.sub_done(
                    &id,
                    "(did not start: the Chief host stopped while starting it)".into(),
                    false,
                    None,
                    None,
                ),
                Some(session) => match sessions.iter().find(|s| s.session_id == session) {
                    Some(summary) => {
                        self.sub_changed(summary);
                    }
                    None => self.sub_done(
                        &id,
                        "(gone: its session no longer exists, so no report will come)".into(),
                        false,
                        None,
                        None,
                    ),
                },
            }
        }
        let spawns: Vec<String> = self.state.spawns.keys().cloned().collect();
        for spawn in spawns {
            self.deliver(&spawn);
        }
        self.start_queued();
    }

    /// The live cap: `control cap` (0: none) over the env's.
    pub(super) fn live_cap(&self) -> Option<usize> {
        match self.state.live_cap {
            Some(0) => None,
            Some(n) => Some(n),
            None => self.max_live,
        }
    }

    /// Subagents starting or running now.
    pub(super) fn live_subs(&self) -> usize {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running))
            .count()
    }

    /// Starts queued subagents, oldest first, while slots are free.
    pub(super) fn start_queued(&mut self) {
        while self.live_cap().is_none_or(|n| self.live_subs() < n) {
            let next = self
                .state
                .spawns
                .iter()
                .flat_map(|(spawn, r)| r.subs.iter().map(move |s| (spawn, s)))
                .filter(|(_, s)| s.status == SubStatus::Queued && !s.cancelled && !s.paused)
                .min_by_key(|(_, s)| {
                    (
                        -s.priority,
                        s.id.trim_start_matches('a')
                            .parse::<u64>()
                            .unwrap_or(u64::MAX),
                    )
                })
                .map(|(spawn, s)| crate::subagents::QueuedStart {
                    id: s.id.clone(),
                    spawn: spawn.clone(),
                    launch: s.queued_launch.clone(),
                    engine: None,
                    extra: (!s.inbox.is_empty()).then(|| inbox_text(&s.inbox)),
                });
            let Some(mut queued) = next else { return };
            queued.engine = self.spawn_engine();
            let id = queued.id.clone();
            let sent = self
                .sub_starter
                .as_ref()
                .is_some_and(|starter| starter.send(queued).is_ok());
            if !sent {
                self.sub_failed(&id, "this Chief host cannot start queued subagents");
                continue;
            }
            let mut delivered = 0;
            if let Some(sub) = self.state.sub_mut(&id) {
                sub.status = SubStatus::Starting;
                sub.run_ms = now_ms();
                sub.queued_launch = None;
                // Its inbox went in with its task.
                delivered = sub.inbox.len();
                sub.inbox.clear();
            }
            if delivered > 0 {
                self.queue(
                    format!("[{id}] got {delivered} queued message(s) from you with its task."),
                    Source::Note,
                );
            }
            self.save();
            (self.log)(&format!("subagent {id}: a slot is free, starting it"));
        }
    }

    /// `text` with every mention of this Chief's subagents written as its link
    /// (`workspaces::link_subagents`): the user's reply shows them as links
    /// whether or not the model wrote one.
    pub(super) fn link_subagents(&self, text: &str) -> String {
        crate::workspaces::link_subagents(text, &self.settings.parent, |id| {
            self.state.sub(id).and_then(|(_, s)| s.session_id.clone())
        })
    }

    /// chief.stop {name}: subagent `name` stops as with chief.stop (its
    /// report comes quiet), the reference's "Stopped by the user: X.".
    pub(super) fn stop_subagent(&mut self, name: &str) -> Value {
        let live = self.state.sub(name).is_some_and(|(_, s)| {
            matches!(
                s.status,
                SubStatus::Starting | SubStatus::Running | SubStatus::Queued
            )
        });
        if !live {
            return json!({"stopped": false, "error": format!("no subagent {name} at work")});
        }
        let stopped = self.stop_subagents_where(|id| id == name);
        if stopped.is_empty() {
            return json!({"stopped": false, "error": format!("{name} is still starting; stop it again in a moment")});
        }
        (self.log)(&format!("the owner stopped subagent {name}"));
        json!({"stopped": true, "subagents": stopped, "note": format!("Stopped by the user: {}.", stopped.join(", "))})
    }

    /// chief.stop: every subagent at work stops (`session/cancel`; its
    /// report comes quiet) and every queued one is dropped. Their ids.
    pub(super) fn stop_subagents(&mut self) -> Vec<String> {
        self.stop_subagents_where(|_| true)
    }

    /// Stops the subagents at work (or queued) whose id `pick` takes.
    fn stop_subagents_where(&mut self, pick: impl Fn(&str) -> bool) -> Vec<String> {
        let subs: Vec<(String, SubStatus, Option<String>)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| {
                pick(&s.id)
                    && matches!(
                        s.status,
                        SubStatus::Starting | SubStatus::Running | SubStatus::Queued
                    )
            })
            .map(|s| (s.id.clone(), s.status, s.session_id.clone()))
            .collect();
        let mut stopped = Vec::new();
        for (id, status, session) in subs {
            match (status, session) {
                (SubStatus::Queued, _) => {
                    self.sub_done(
                        &id,
                        "(stopped by the user before it started)".into(),
                        true,
                        None,
                        None,
                    );
                }
                (_, Some(session)) => {
                    if let Err(e) = self.agents.cancel(&session) {
                        (self.log)(&format!("subagent {id}: stopping it: {e}"));
                        continue;
                    }
                }
                // Its session is not made yet: nothing to stop.
                (_, None) => continue,
            }
            stopped.push(id);
        }
        stopped.sort_by_key(|id| {
            id.trim_start_matches('a')
                .parse::<u64>()
                .unwrap_or(u64::MAX)
        });
        stopped
    }
}

impl Brain {
    /// `Subagents at work now: a1, a3.` when any runs (a turn's line after
    /// the view); None when none does.
    pub(super) fn at_work_line(&self) -> Option<String> {
        let ids: Vec<&str> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running))
            .map(|s| s.id.as_str())
            .collect();
        (!ids.is_empty()).then(|| format!("Subagents at work now: {}.", ids.join(", ")))
    }

    /// A running subagent spawned under the spawn floor: the floor stays
    /// `ask` while one lives (`spawn_policy`).
    pub(super) fn ask_subagent_live(&self) -> bool {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .any(|s| {
                s.policy.as_deref() == Some(crate::approval::ASK)
                    && matches!(s.status, SubStatus::Starting | SubStatus::Running)
            })
    }

    /// A permission request of subagent session `session_id`, when it is
    /// one: an ask subagent's goes to a person in the Chief chat (as an ask
    /// child's), any other's reaches the Chief as a note. True when handled.
    pub(super) fn sub_permission(
        &mut self,
        session_id: &str,
        permission_id: &str,
        request: &Value,
    ) -> bool {
        let Some(id) = self.state.sub_by_session(session_id) else {
            return false;
        };
        let ask = self
            .state
            .sub(&id)
            .is_some_and(|(_, s)| s.policy.as_deref() == Some(crate::approval::ASK));
        let summary: SessionSummary = match serde_json::from_value(json!({
            "sessionId": session_id, "name": id, "status": "running",
            "tags": {crate::subagents::SUBAGENT_TAG: id, crate::approval::POLICY_TAG: if ask { crate::approval::ASK } else { "" }},
        })) {
            Ok(s) => s,
            Err(_) => return true,
        };
        if let Some(sub) = self.state.sub_mut(&id) {
            sub.permission = Some(crate::state::PendingPermission {
                id: permission_id.to_owned(),
                request: request.clone(),
            });
        }
        self.save();
        if ask {
            self.child_permission(&summary, permission_id.to_owned(), request.clone());
        } else {
            let text = super::control::permission_note(&id, request);
            self.queue(text, Source::Note);
        }
        true
    }
}

/// A tell as the subagent's next prompt; its answer goes to the brain.
fn tell_prompt(
    agents: &dyn crate::acpmux::AgentPort,
    session: &str,
    blocks: Vec<Value>,
    prompt_id: &str,
    forward: std::sync::mpsc::Sender<super::Input>,
    sub_id: String,
) -> Result<(), String> {
    let (tx, rx) = std::sync::mpsc::channel();
    agents.start_prompt(session, blocks, prompt_id, tx)?;
    std::thread::spawn(move || {
        while let Ok(signal) = rx.recv() {
            match signal {
                crate::acpmux::TurnSignal::Changed
                | crate::acpmux::TurnSignal::Noted
                | crate::acpmux::TurnSignal::Streamed => {}
                crate::acpmux::TurnSignal::Done(answer) => {
                    let _ = forward.send(super::Input::SubagentAnswer { id: sub_id, answer });
                    return;
                }
                crate::acpmux::TurnSignal::Lost => return,
            }
        }
    });
    Ok(())
}

/// Inbox messages as one prompt, oldest first.
pub(super) fn inbox_text(messages: &[crate::state::InboxMessage]) -> String {
    match messages {
        [one] => one.text.clone(),
        many => many
            .iter()
            .enumerate()
            .map(|(k, m)| format!("Message {} from the Chief:\n{}", k + 1, m.text))
            .collect::<Vec<_>>()
            .join("\n\n"),
    }
}

/// The text of a prompt acpmux recorded (`user_message`).
fn user_text(msg: &serde_json::Map<String, Value>) -> String {
    if let Some(text) = msg.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    msg.get("prompt")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}
