//! Subagents and background work (section 9): acpmux sessions tagged
//! `mux.parent=optchat-chief` (mux/host's tag, with this Chief's value) are
//! the Chief's children. When one ends a turn, its final reply becomes one
//! `user` entry `[<child name>] <report>`, which starts a new turn when the
//! Chief is idle; the Chief never waits or polls for it.
//!
//! Deviation: section 9 delivers one message per spawn (all of a spawn's
//! subagents together) and gives subagents the view. Here each child reports
//! on its own, and a child is a plain acpmux agent started with its task.
//! A report is logged whole, like any user message (section 4.2: never cut
//! the compactor's input; CAP is for tool results only).

use cmux_chief::acp::{AcpmuxEvent, SessionStatus, SessionSummary, TurnFolder, TurnOutput};
use cmux_chief::rules::{PARENT_TAG, turn_ended};
use serde_json::Value;

use super::{Brain, Source};
use crate::acpmux::AgentEvent;
use crate::state::{ChildRecord, ChildStatus};

fn busy(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Running | SessionStatus::Waiting)
}

impl Brain {
    pub(super) fn on_agents(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::Up(sessions) => {
                self.agents_up = true;
                self.reap_closed_compactor_sessions(&sessions);
                self.reconcile_spawns(&sessions);
                // Only the Chief's own children: the compactor and turn
                // sessions come and go by the thousand.
                self.sessions = sessions
                    .into_iter()
                    .filter(|s| self.is_child(s))
                    .map(|s| (s.session_id.clone(), s))
                    .collect();
                for name in std::mem::take(&mut self.stale_sessions) {
                    if let Ok(Some(id)) = self.agents.find(&name) {
                        let _ = self.agents.end_session(&id);
                    }
                }
                self.adopt_orphans(false);
                self.reconcile_children();
                self.maybe_start_turn();
                self.prewarm_next_turn();
            }
            AgentEvent::Down => self.agents_up = false,
            AgentEvent::Ended => {
                // home-state-ownership.md section 3: the host lives inside its
                // acpmux daemon's lifetime; the next Home open starts both.
                self.agents_up = false;
                self.fatal =
                    Some("the acpmux daemon ended (sessions were ended); the host stops".into());
            }
            AgentEvent::SessionChanged(session) => self.on_session(session),
            AgentEvent::Permission {
                session_id,
                permission_id,
                request,
            } => {
                if self.is_turn_session(&session_id) {
                    self.turn_permission(session_id, permission_id, request);
                    return;
                }
                if self.sub_permission(&session_id, &permission_id, &request) {
                    return;
                }
                // A child can ask before its session_changed reached us.
                let known = self.sessions.get(&session_id).cloned();
                let session = match known {
                    Some(s) => s,
                    None => match self.agents.session(&session_id) {
                        Ok(Some(s)) => {
                            if self.is_child(&s) {
                                self.sessions.insert(s.session_id.clone(), s.clone());
                            }
                            s
                        }
                        Ok(None) => return,
                        Err(e) => {
                            (self.log)(&format!(
                                "permission request from unknown session {session_id}: {e}"
                            ));
                            return;
                        }
                    },
                };
                let ask = session
                    .tags
                    .get(crate::approval::POLICY_TAG)
                    .map(String::as_str)
                    == Some(crate::approval::ASK);
                if self.is_child(&session) && ask {
                    // Spawned under the spawn floor: refused at once.
                    self.child_permission(&session, permission_id, request);
                } else if self.is_child(&session) {
                    let text = permission_text(&session.name, &request);
                    self.queue(text, Source::Note);
                    // A child has no tab in the person's app, so nobody
                    // can allow it: denied once overdue, unless the Chief
                    // answers or steers it first.
                    self.watch_unanswered(
                        crate::approval::Pending {
                            session_id: session.session_id.clone(),
                            permission_id,
                            tool: crate::approval::tool_name(&request),
                            request,
                            child: Some(session.name.clone()),
                        },
                        "a child agent has no approval button in the app",
                    );
                } else if self.is_own_turn_session(&session) {
                    // A turn session of this Chief that is not the running
                    // turn (a kept, adopted or ended one): nobody sees its
                    // request, so it is refused at once.
                    let pending = crate::approval::Pending {
                        session_id: session.session_id.clone(),
                        permission_id,
                        tool: crate::approval::tool_name(&request),
                        request,
                        child: None,
                    };
                    (self.log)(&format!(
                        "turn session {} that no turn runs on asked for {}: refusing it",
                        pending.session_id, pending.tool
                    ));
                    self.refuse_by(&pending, "no approver");
                }
            }
        }
    }

    /// Ends this Chief's compactor sessions that acpmux lists as closed.
    /// The compactor purges each node's session when the node is built, so
    /// a closed one is a leftover: an acpmux that saved a purged session's
    /// record again (a late generated title) loaded about 450 of them back
    /// after a restart (2026-10-20). Never a live one, a turn session or
    /// another Chief's.
    fn reap_closed_compactor_sessions(&self, sessions: &[SessionSummary]) {
        let leftovers: Vec<&SessionSummary> = sessions
            .iter()
            .filter(|s| {
                s.status == SessionStatus::Closed
                    && s.tags.get(crate::acpmux::CHIEF_TAG) == Some(&self.settings.chief_id)
                    && s.tags
                        .get(crate::acpmux::CHIEF_ROLE_TAG)
                        .map(String::as_str)
                        == Some(crate::acpmux::COMPACTOR_ROLE)
            })
            .collect();
        if leftovers.is_empty() {
            return;
        }
        let mut failed = 0;
        for s in &leftovers {
            if self.agents.end_session(&s.session_id).is_err() {
                failed += 1;
            }
        }
        (self.log)(&format!(
            "ended {} closed compactor session(s) a stopped host or an older acpmux left{}",
            leftovers.len() - failed,
            if failed > 0 {
                format!(" ({failed} could not be ended)")
            } else {
                String::new()
            }
        ));
    }

    /// A turn session of this Chief (`cmux.chief=<id>`, role `turn`).
    fn is_own_turn_session(&self, session: &SessionSummary) -> bool {
        session.tags.get(crate::acpmux::CHIEF_TAG) == Some(&self.settings.chief_id)
            && session
                .tags
                .get(crate::acpmux::CHIEF_ROLE_TAG)
                .map(String::as_str)
                == Some("turn")
    }

    /// One of the Chief's `chief agents` children; a subagent (section 9,
    /// `optchat.subagent`) is not: its spawn reports for it.
    fn is_child(&self, session: &SessionSummary) -> bool {
        session.tags.get(PARENT_TAG).map(String::as_str) == Some(self.settings.parent.as_str())
            && !session.tags.contains_key(crate::subagents::SUBAGENT_TAG)
    }

    fn on_session(&mut self, session: SessionSummary) {
        if session.pending_permissions == 0 {
            // Answered (by the person's app, or a deny): nothing to watch.
            self.forget_unanswered_of(&session.session_id);
        }
        // An adopted turn the Chief waits for has ended: fold it, then the
        // turns that waited start (the resume first).
        if self.orphan_wait.is_some()
            && !busy(session.status)
            && self
                .state
                .orphans
                .iter()
                .any(|o| o.session == session.session_id)
        {
            self.adopt_orphans(false);
            if self.orphan_wait.is_none() {
                self.maybe_start_turn();
            }
            return;
        }
        if self.sub_changed(&session) {
            return;
        }
        if !self.is_child(&session) {
            self.sessions.remove(&session.session_id);
            return;
        }
        let before = self
            .sessions
            .insert(session.session_id.clone(), session.clone())
            .map(|s| s.status);
        let id = session.session_id.clone();
        let record = self
            .state
            .children
            .entry(id.clone())
            .or_insert_with(|| ChildRecord {
                name: session.name.clone(),
                status: if busy(session.status) {
                    ChildStatus::Running
                } else {
                    ChildStatus::Reported
                },
                floor: 0,
            });
        let was = record.status;
        if turn_ended(before, session.status) && was == ChildStatus::Running {
            self.child_finished(&session);
        } else if busy(session.status) {
            record.status = ChildStatus::Running;
        } else if matches!(
            session.status,
            SessionStatus::Closed | SessionStatus::Disconnected
        ) && was == ChildStatus::Running
        {
            record.status = ChildStatus::Reported;
            let text = format!(
                "[{}] (stopped without a report: its session is {:?})",
                session.name, session.status
            );
            self.queue(text, Source::Note);
        }
        if self.state.children.get(&id).map(|r| r.status) != Some(was) || before.is_none() {
            self.save();
        }
    }

    /// Turn sessions whose connection was lost: fold what they did since into
    /// the log, then remove them. One that cannot be read stays for the next
    /// connect, unless acpmux no longer knows it (a daemon restart purged it):
    /// then nothing more can be read and it is dropped.
    ///
    /// One that still runs (its harness lives in an agent host the next
    /// daemon adopted after an update; user 2026-10-20 "updates must never
    /// cut Chief") is left running: ending it would lose its work and the
    /// resume turn would do it again. No turn starts until it ends
    /// (`on_session`) or `ORPHAN_WAIT` passes; `force` (that deadline) folds
    /// and ends it anyway.
    pub(super) fn adopt_orphans(&mut self, force: bool) {
        if self.state.orphans.is_empty() {
            self.orphan_wait = None;
            return;
        }
        let orphans = std::mem::take(&mut self.state.orphans);
        let mut gone = Vec::new();
        let mut running = false;
        for orphan in orphans {
            let still_runs = !force
                && matches!(
                    self.agents.session(&orphan.session),
                    Ok(Some(s)) if busy(s.status)
                );
            if still_runs {
                (self.log)(&format!(
                    "orphan turn session {} still runs (the next acpmux adopted it); no turn starts until it ends",
                    orphan.session
                ));
                running = true;
                self.state.orphans.push(orphan);
                continue;
            }
            match crate::turn::adopt_orphan(&*self.agents, &self.chat, &orphan, &*self.log) {
                Ok(()) => (self.log)(&format!("folded orphan turn session {}", orphan.session)),
                Err(e) if e.contains("no session matches") => {
                    (self.log)(&format!(
                        "orphan turn session {} is gone from acpmux; dropped ({e})",
                        orphan.session
                    ));
                    gone.push((crate::state::fold_key(&orphan.session), None));
                }
                Err(e) => {
                    (self.log)(&format!("orphan turn session {}: {e}", orphan.session));
                    self.state.orphans.push(orphan);
                }
            }
        }
        self.orphan_wait = match (running, self.orphan_wait) {
            (false, _) => None,
            (true, Some(at)) => Some(at),
            (true, None) => Some(std::time::Instant::now() + super::ORPHAN_WAIT),
        };
        self.save_with(gone);
    }

    /// After a reconnect: children whose turn ended while the host was away,
    /// children that vanished, and permission requests still pending.
    fn reconcile_children(&mut self) {
        let mut finished = Vec::new();
        let mut gone = Vec::new();
        for (id, record) in &self.state.children {
            if record.status != ChildStatus::Running {
                continue;
            }
            match self.sessions.get(id) {
                Some(s) if matches!(s.status, SessionStatus::Ready | SessionStatus::Idle) => {
                    finished.push(s.clone())
                }
                Some(_) => {}
                None => gone.push(id.clone()),
            }
        }
        for id in gone {
            // The Chief may have told the user it is running: say it is gone.
            if let Some(record) = self.state.children.remove(&id) {
                let text = format!(
                    "[{}] (gone: its session no longer exists, so no report will come)",
                    record.name
                );
                self.queue(text, Source::Note);
            }
        }
        for session in finished {
            self.child_finished(&session);
        }
        // Requests raised while the host was away arrive as no notification.
        let asking: Vec<SessionSummary> = self
            .sessions
            .values()
            .filter(|s| self.is_child(s) && s.pending_permissions > 0)
            .cloned()
            .collect();
        for s in asking {
            let text = format!(
                "[{}] has {} pending permission request(s). Nobody can allow them (only the person's cmux app allows, and it has no tab there): deny with `chief agents deny {}`, or tell it what to do instead.",
                s.name, s.pending_permissions, s.name
            );
            self.queue(text, Source::Note);
        }
        // Tagged sessions first seen now: running ones report when they end.
        let unseen: Vec<SessionSummary> = self
            .sessions
            .values()
            .filter(|s| self.is_child(s) && !self.state.children.contains_key(&s.session_id))
            .cloned()
            .collect();
        for s in unseen {
            let status = if busy(s.status) {
                ChildStatus::Running
            } else {
                ChildStatus::Reported
            };
            self.state.children.insert(
                s.session_id.clone(),
                ChildRecord {
                    name: s.name.clone(),
                    status,
                    floor: 0,
                },
            );
        }
        self.save();
    }

    /// Queues the child's report: every turn it ended after its floor, one
    /// `[name] reply` each. A report already queued for this child (it ended
    /// again before the Chief's next turn) is made again from all of its
    /// turns, so no turn's report is lost.
    fn child_finished(&mut self, session: &SessionSummary) {
        let id = &session.session_id;
        let floor = self.state.children.get(id).map_or(0, |r| r.floor);
        let queued = self.queue.iter().position(
            |q| matches!(&q.source, Source::Child { session_id, .. } if session_id == id),
        );
        let (text, next_floor) = match self.agents.events(id, floor) {
            Ok(events) => {
                let (mut replies, last_end, _) = ended_replies(&events);
                if replies.is_empty() {
                    replies.push("(no reply text)".to_owned());
                }
                let text = replies
                    .iter()
                    .map(|r| format!("[{}] {r}", session.name))
                    .collect::<Vec<_>>()
                    .join("\n\n");
                // The floor is the last folded turn end, not the session's
                // last seq: that can already be inside the next turn, whose
                // `turn_started` the next fold would then never see.
                (text, last_end.unwrap_or(floor))
            }
            Err(e) if queued.is_some() => {
                // Keep what is queued; the next turn end reads it again.
                (self.log)(&format!(
                    "child {}: its report could not be read: {e}",
                    session.name
                ));
                return;
            }
            Err(e) => (
                format!("[{}] (its report could not be read: {e})", session.name),
                session.last_seq.unwrap_or(floor),
            ),
        };
        (self.log)(&format!(
            "child {} finished; queued its report",
            session.name
        ));
        let source = Source::Child {
            session_id: id.clone(),
            floor: next_floor,
        };
        match queued {
            Some(k) => {
                self.queue[k] = super::Queued {
                    text,
                    source,
                    images: Vec::new(),
                    conversation: None,
                    logged: false,
                }
            }
            None => self.queue(text, source),
        }
    }
}

/// The final reply of every turn that ended in `events`, oldest first (a
/// failed turn's error included), and the seq of the last turn end. A turn's
/// final reply is its words after its last tool call (the last words it said,
/// when it ended on a tool call): the folder's turn text glues every progress
/// line of the run together with no break, which put whole runs in report
/// bubbles (Leo, 2026-10-31).
pub(super) fn ended_replies(events: &[AcpmuxEvent]) -> (Vec<String>, Option<u64>, bool) {
    let mut folder = TurnFolder::default();
    let mut replies = Vec::new();
    let mut last_end = None;
    let mut cancelled = false;
    // Byte offsets into the running turn's text where its tool calls fell.
    let mut cuts: Vec<usize> = Vec::new();
    for event in events {
        // A turn the user stopped (`session/cancel`) ends with stopReason cancelled.
        let stopped = event.kind == "turn_end"
            && event.msg.get("stopReason").and_then(Value::as_str) == Some("cancelled");
        if is_own_tool_call(event)
            && let Some(turn) = folder.running()
            && cuts.last() != Some(&turn.text.len())
        {
            cuts.push(turn.text.len());
        }
        for output in folder.apply(event) {
            match output {
                TurnOutput::Started { .. } => cuts.clear(),
                TurnOutput::Ended { turn, seq, error } => {
                    last_end = Some(seq);
                    cancelled = stopped || crate::fold::is_cancelled(error.as_deref());
                    let text = final_words(&turn.text, &cuts);
                    cuts.clear();
                    let reply = match error {
                        Some(error) if text.is_empty() => format!("(turn failed: {error})"),
                        Some(error) => format!("{text}\n\n(turn failed: {error})"),
                        None => text.to_owned(),
                    };
                    if !reply.is_empty() {
                        replies.push(reply);
                    }
                }
                _ => {}
            }
        }
    }
    (replies, last_end, cancelled)
}

/// A tool call of the session itself; a Task subagent's (`<acp>/<toolu>`
/// session, or `_meta.acpmux.subagent`) is not the turn's.
fn is_own_tool_call(event: &AcpmuxEvent) -> bool {
    let params = event.msg.get("params");
    event.kind == "tool_call"
        && !params
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str)
            .is_some_and(|id| id.contains('/'))
        && params
            .and_then(|p| p.pointer("/_meta/acpmux/subagent"))
            .is_none()
}

/// The last non-empty segment of `text` split at `cuts`, trimmed.
fn final_words<'a>(text: &'a str, cuts: &[usize]) -> &'a str {
    let mut end = text.len();
    for &cut in cuts.iter().rev() {
        if cut > end || !text.is_char_boundary(cut) {
            continue;
        }
        let segment = text[cut..end].trim();
        if !segment.is_empty() {
            return segment;
        }
        end = cut;
    }
    text[..end].trim()
}

/// A subagent's report, its replies since its floor: the last one, and when
/// the user stopped it, said so (and no failure note).
pub(super) fn report_of(replies: &[String], cancelled: bool) -> String {
    let last = replies.last().map_or("", |r| r.as_str());
    if !cancelled {
        return if last.is_empty() {
            "(no reply text)".to_owned()
        } else {
            last.to_owned()
        };
    }
    let note = format!(
        "(turn failed: {})",
        crate::fold::stop_error("cancelled").unwrap_or_default()
    );
    let text = last.replace(&note, "");
    let text = text.trim();
    if text.is_empty() {
        "(stopped by the user)".to_owned()
    } else {
        format!("(stopped by the user) {text}")
    }
}

/// A child's permission request as a message to the Chief.
pub(super) fn permission_text(name: &str, request: &Value) -> String {
    let call = request.get("toolCall");
    let title = call
        .and_then(|c| c.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("a tool call");
    let input = call
        .and_then(|c| c.get("rawInput"))
        .map(|raw| {
            format!(
                "\nInput: {}",
                raw.to_string().chars().take(600).collect::<String>()
            )
        })
        .unwrap_or_default();
    let options: Vec<String> = request
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|o| {
            let text = |k| o.get(k).and_then(Value::as_str).unwrap_or("");
            format!(
                "{} ({})",
                text("optionId"),
                if text("name").is_empty() {
                    text("kind")
                } else {
                    text("name")
                }
            )
        })
        .collect();
    let options = if options.is_empty() {
        "(none)".to_owned()
    } else {
        options.join(", ")
    };
    format!(
        "[{name}] asks permission: {title}{input}\nOptions: {options}\nNobody can allow it: only the person's cmux app allows, and {name} has no tab there. Deny it with `chief agents deny {name}`, or tell it what to do instead; the host denies it after {} s.",
        crate::approval::PERMISSION_WAIT.as_secs()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(seq: u64, dir: &str, kind: &str, msg: Value) -> AcpmuxEvent {
        serde_json::from_value(json!({"seq": seq, "at": seq, "dir": dir, "kind": kind, "msg": msg}))
            .unwrap()
    }

    fn update(seq: u64, kind: &str, session: &str, mut update: Value) -> AcpmuxEvent {
        update["sessionUpdate"] = json!(kind);
        ev(
            seq,
            "in",
            kind,
            json!({"method": "session/update", "params": {"sessionId": session, "update": update}}),
        )
    }

    fn say(seq: u64, text: &str) -> AcpmuxEvent {
        update(
            seq,
            "agent_message_chunk",
            "s1",
            json!({"content": {"type": "text", "text": text}}),
        )
    }

    fn tool(seq: u64, session: &str, id: &str) -> AcpmuxEvent {
        update(
            seq,
            "tool_call",
            session,
            json!({"toolCallId": id, "title": "Bash", "rawInput": {"command": "ls"}}),
        )
    }

    fn start(seq: u64) -> AcpmuxEvent {
        ev(seq, "mux", "turn_started", json!({}))
    }

    fn end(seq: u64) -> AcpmuxEvent {
        ev(seq, "mux", "turn_end", json!({"stopReason": "end_turn"}))
    }

    /// Leo, 2026-10-31, on an `a28 → Chief` bubble that held the whole run
    /// glued together ("...skills.Measured: hooks..."): a report is the
    /// subagent's final reply, not every progress line of its turn.
    #[test]
    fn a_report_is_the_reply_after_the_last_tool_call() {
        let events = vec![
            start(1),
            say(2, "Reading the hook config."),
            tool(3, "s1", "t1"),
            say(4, "Measured: hooks add 40 ms."),
            tool(5, "s1", "t2"),
            say(6, "Landed #30079 as a57fc4b."),
            end(7),
        ];
        let (replies, last_end, _) = ended_replies(&events);
        assert_eq!(last_end, Some(7));
        assert_eq!(replies, vec!["Landed #30079 as a57fc4b.".to_owned()]);
    }

    /// A turn that ends on a tool call reports its last words, never the run.
    #[test]
    fn a_turn_ending_on_a_tool_call_reports_its_last_words() {
        let events = vec![
            start(1),
            say(2, "Checking CI."),
            tool(3, "s1", "t1"),
            say(4, "All green; merged."),
            tool(5, "s1", "t2"),
            end(6),
        ];
        let (replies, _, _) = ended_replies(&events);
        assert_eq!(replies, vec!["All green; merged.".to_owned()]);
    }

    /// A Task subagent's own tool calls (`<acp>/<toolu>` sessions) do not
    /// split the reply.
    #[test]
    fn an_inner_subagent_tool_call_does_not_split_the_reply() {
        let events = vec![
            start(1),
            say(2, "Done: "),
            tool(3, "s1/toolu_1", "t1"),
            say(4, "landed."),
            end(5),
        ];
        let (replies, _, _) = ended_replies(&events);
        assert_eq!(replies, vec!["Done: landed.".to_owned()]);
    }

    /// One reply with no tool calls stays whole.
    #[test]
    fn a_reply_with_no_tool_calls_stays_whole() {
        let events = vec![start(1), say(2, "Line one.\n\nLine two."), end(3)];
        let (replies, _, _) = ended_replies(&events);
        assert_eq!(replies, vec!["Line one.\n\nLine two.".to_owned()]);
    }
}
