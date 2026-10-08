//! Section 9 in the brain: the spawns and their subagents (state.rs
//! `SpawnRecord`), each subagent's turn ends read from its acpmux session,
//! and the combined report: when all of one spawn's subagents finished,
//! their reports reach the chat as ONE message, `[id] report` each, queued
//! like a human message (so on acpmux it stops a working Chief between its
//! tool calls, and the next turn takes it; otherwise it starts a turn). A
//! subagent that runs again later (a `tell`, or the user writing in its
//! chat) reports alone when it finishes.
//!
//! A report is the subagent's last finished reply: its final reply is its
//! report to the Chief (section 9's subagent prompt).

use cmux_chief::acp::{AcpmuxEvent, SessionStatus, SessionSummary};
use serde_json::{Value, json};

use super::children::ended_replies;
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
                .map(|(id, task)| SubRecord {
                    id: id.clone(),
                    title: crate::workspaces::name(id, task),
                    run_ms: now_ms(),
                    ..SubRecord::default()
                })
                .collect(),
            delivered: false,
            started_ms: now_ms(),
            turn: self.state.turn.as_ref().map(|t| t.key.clone()),
        };
        self.state.spawns.insert(spawn.clone(), record);
        self.save();
        (self.log)(&format!("spawn {spawn}: {}", ids.join(", ")));
        Ok(SpawnPlan {
            spawn,
            ids,
            engine: self.spawn_engine(),
        })
    }

    pub(super) fn sub_started(&mut self, id: &str, session_id: String, policy: Option<String>) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.session_id = Some(session_id);
            sub.policy = policy;
            if sub.status == SubStatus::Starting {
                sub.status = SubStatus::Running;
            }
            self.save();
        }
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
        sub.report = Some(format!("(did not start: {error})"));
        let spawn = self.state.sub(id).map(|(s, _)| s.clone());
        self.save();
        if let Some(spawn) = spawn {
            self.deliver(&spawn);
        }
    }

    pub(super) fn sub_answer(&mut self, id: &str, answer: &Result<Value, String>) {
        let mut fields = crate::subagents::answer_fields(answer);
        fields["id"] = json!(id);
        if let Some((spawn, _)) = self.state.sub(id) {
            fields["spawn"] = json!(spawn);
        }
        self.trace.emit("subagent.answer", fields);
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
        if busy(session.status) {
            // Running again: a tell, or the user writing in its chat.
            if matches!(status, SubStatus::Done | SubStatus::Reported) {
                if let Some(sub) = self.state.sub_mut(&id) {
                    sub.status = SubStatus::Running;
                    sub.run_ms = now_ms();
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
                self.sub_done(&id, report, None, None);
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
        let (replies, last_end) = ended_replies(&events);
        // Idle before its prompt started (a new session is ready first).
        let Some(last_end) = last_end else { return };
        self.trace_sub_events(id, &events, floor);
        let report = replies
            .last()
            .cloned()
            .unwrap_or_else(|| "(no reply text)".to_owned());
        self.sub_done(id, report, Some(last_end), Some(&events));
    }

    fn sub_done(
        &mut self,
        id: &str,
        report: String,
        floor: Option<u64>,
        events: Option<&[AcpmuxEvent]>,
    ) {
        let Some(spawn) = self.state.sub(id).map(|(s, _)| s.clone()) else {
            return;
        };
        let run_ms = if let Some(sub) = self.state.sub_mut(id) {
            sub.status = SubStatus::Done;
            sub.report = Some(report.clone());
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
            }),
        );
        (self.log)(&format!("subagent {id} finished"));
        self.mark_workspace(id, true);
        self.deliver(&spawn);
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

    /// Renames a subagent's workspace: done mark on, or off when it runs again.
    fn mark_workspace(&self, id: &str, done: bool) {
        let (Some(workspaces), Some((_, sub))) = (self.workspaces.clone(), self.state.sub(id))
        else {
            return;
        };
        let Some(key) = sub.workspace.clone() else {
            return;
        };
        let name = if done {
            crate::workspaces::done_name(&sub.title)
        } else {
            sub.title.clone()
        };
        let log = self.log.clone();
        let id = id.to_owned();
        std::thread::spawn(move || {
            if let Err(e) = workspaces.rename(&key, &name) {
                log(&format!("subagent {id}: renaming its workspace: {e}"));
            }
        });
    }

    /// Queues the spawn's report once nothing of it runs (or, after the
    /// combined report, each later one as it comes).
    pub(super) fn deliver(&mut self, spawn: &str) {
        let Some(record) = self.state.spawns.get(spawn) else {
            return;
        };
        let running = record
            .subs
            .iter()
            .any(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running));
        if running && !record.delivered {
            return;
        }
        let done: Vec<&SubRecord> = record
            .subs
            .iter()
            .filter(|s| s.status == SubStatus::Done)
            .collect();
        if done.is_empty() {
            return;
        }
        let text = done
            .iter()
            .map(|s| format!("[{}] {}", s.id, s.report.as_deref().unwrap_or("")))
            .collect::<Vec<_>>()
            .join("\n\n");
        let source = Source::Spawn(SpawnRef {
            spawn: spawn.to_owned(),
            subs: done.iter().map(|s| (s.id.clone(), s.floor)).collect(),
        });
        let queued = self
            .queue
            .iter()
            .position(|q| matches!(&q.source, Source::Spawn(r) if r.spawn == spawn));
        match queued {
            Some(k) => {
                self.queue[k] = Queued {
                    text,
                    source,
                    images: Vec::new(),
                    conversation: None,
                }
            }
            None => {
                (self.log)(&format!("spawn {spawn}: queued its report"));
                self.queue(text, source);
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

    /// `tell(id, message)`: a prompt to the subagent's session (acpmux runs
    /// it after the current turn).
    pub(super) fn tell(&mut self, id: &str, message: &str) -> Result<String, String> {
        let (spawn, session) = match self.state.sub(id) {
            Some((spawn, sub)) => (
                spawn.clone(),
                sub.session_id
                    .clone()
                    .ok_or_else(|| format!("{id} is still starting; tell it again in a moment"))?,
            ),
            None => return Err(format!("no subagent {id}")),
        };
        let (tx, rx) = std::sync::mpsc::channel();
        let prompt_id = format!("{PROMPT_PREFIX}tell:{id}:{}", now_ms());
        self.agents.start_prompt(
            &session,
            vec![json!({"type": "text", "text": message})],
            &prompt_id,
            tx,
        )?;
        let forward = self.tx.clone();
        let sub_id = id.to_owned();
        std::thread::spawn(move || {
            while let Ok(signal) = rx.recv() {
                match signal {
                    crate::acpmux::TurnSignal::Changed => {}
                    crate::acpmux::TurnSignal::Done(answer) => {
                        let _ = forward.send(super::Input::SubagentAnswer { id: sub_id, answer });
                        return;
                    }
                    crate::acpmux::TurnSignal::Lost => return,
                }
            }
        });
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
            json!({"id": id, "spawn": spawn, "from": "chief", "message": self.trace.text(message)}),
        );
        Ok(format!(
            "sent to {id}; it reads it after its current step, and its report comes back as a \"[{id}] ...\" message"
        ))
    }

    /// After a reconnect: subagents that finished or vanished meanwhile.
    pub(super) fn reconcile_spawns(&mut self, sessions: &[SessionSummary]) {
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
    }
}

impl Brain {
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
        if ask {
            self.child_permission(&summary, permission_id.to_owned(), request.clone());
        } else {
            let text = super::children::permission_text(&id, request);
            self.queue(text, Source::Note);
        }
        true
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
