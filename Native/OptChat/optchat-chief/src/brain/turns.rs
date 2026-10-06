//! The turn loop (section 7): the settle worker, taking the queue into a
//! turn, delivering messages between tool calls (native engine) or
//! stopping the turn for them (acpmux engine), and the turn's end.

use std::sync::Arc;
use std::sync::mpsc::channel;

use optchat_core::Kind;

use super::{Brain, Engine, Input, Phase, Queued, STALL_NOTICE, Source, reply_entry, reply_key};
use std::sync::atomic::Ordering;

use crate::acpmux::SessionSpec;
use crate::compactor::is_marker_limit_error;
use crate::prompt::{cached_layout, turn_blocks};
use crate::state::{Batch, ChildRef, ChildStatus, Item, PendingTurn};
use crate::turn::{self, Interrupt, TurnOutcome, TurnStart};

impl Brain {
    /// Starts a turn worker when idle with something queued.
    pub(super) fn maybe_start_turn(&mut self) {
        if self.phase != Phase::Idle || self.queue.is_empty() || !self.ready() {
            return;
        }
        self.phase = Phase::Settling;
        self.settle_clock
            .get_or_insert_with(std::time::Instant::now);
        self.interrupt = Arc::new(Interrupt::new());
        let trace = self.trace.clone();
        let (chat, agents, tx, log, engine, interrupt, marker_refused) = (
            self.chat.clone(),
            self.agents.clone(),
            self.tx.clone(),
            self.log.clone(),
            self.settings.engine.clone(),
            self.interrupt.clone(),
            self.marker_refused.clone(),
        );
        let spawned = std::thread::Builder::new()
            .name("turn".into())
            .spawn(move || {
                // Section 6: no turn starts before every view line is a summary.
                // The wait has no deadline; a line each minute says what it
                // waits on, and the first one with a failing node also goes to
                // the conversation, so the user is not left without a word.
                let mut told = false;
                while !chat.settle(None, Some(STALL_NOTICE)) {
                    let status = chat.status();
                    if status.closed || status.fatal.is_some() {
                        let _ = tx.send(Input::SettleFailed);
                        return;
                    }
                    let failing: Vec<String> = status
                        .failures
                        .iter()
                        .map(|f| format!("{}: {}", f.node.name(), f.error))
                        .collect();
                    log(&format!(
                        "turn waits for the compactor: {} view lines unbuilt; failing: {}",
                        status.unbuilt,
                        if failing.is_empty() {
                            "none".to_owned()
                        } else {
                            failing.join("; ")
                        }
                    ));
                    if !told && let Some(first) = status.failures.first() {
                        told = true;
                        let _ = tx.send(Input::Stalled(format!(
                            "(waiting: the Chief's memory cannot summarize line {} yet, so your message waits. First error: {}. It is retried every 10 s.)",
                            first.node.name(),
                            first.error
                        )));
                    }
                }
                let (reply, start) = channel();
                if tx.send(Input::Settled(reply)).is_err() {
                    return;
                }
                let Ok(Some(start)) = start.recv() else {
                    return;
                };
                let outcome = match &engine {
                    Engine::Acpmux => {
                        let progress = |session_id: &str, after: u64| {
                            let _ = tx.send(Input::TurnProgress {
                                key: start.key.clone(),
                                session_id: session_id.to_owned(),
                                after,
                            });
                        };
                        let outcome =
                            turn::run(&*agents, &chat, &start, &interrupt, &*log, &progress, &trace);
                        // Claude Code placed all four cache breakpoints
                        // itself: the same turn again without the marker
                        // (the refused request did nothing), and later
                        // turns go without it.
                        let marked = start
                            .blocks
                            .iter()
                            .any(|b| b.get("cache_control").is_some());
                        match &outcome.error {
                            Some(e) if marked && is_marker_limit_error(e) => {
                                marker_refused.store(true, Ordering::SeqCst);
                                log(&format!(
                                    "turn {}: Claude Code refused the cache_control marker ({e}); running the turn again without it, and later turns go without it",
                                    start.key
                                ));
                                let mut again = start.clone();
                                for block in &mut again.blocks {
                                    if let Some(b) = block.as_object_mut() {
                                        b.remove("cache_control");
                                    }
                                }
                                again.prompt_id = format!("{}:unmarked", start.prompt_id);
                                turn::run(&*agents, &chat, &again, &interrupt, &*log, &progress, &trace)
                            }
                            _ => outcome,
                        }
                    }
                    Engine::Native(native) => {
                        let mailbox = || {
                            let (reply, texts) = channel();
                            let asked = tx.send(Input::Boundary {
                                key: start.key.clone(),
                                reply,
                            });
                            if asked.is_err() {
                                return Vec::new();
                            }
                            texts.recv().unwrap_or_default()
                        };
                        native.run(&chat, &start, &*log, &mailbox, &|| interrupt.is_set())
                    }
                };
                let _ = tx.send(Input::TurnEnded {
                    key: start.key,
                    outcome,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting a turn failed: {e}"));
            self.phase = Phase::Idle;
        }
    }

    /// The worker settled the view. Between its check and now the brain may
    /// have lost acpmux (the turn would fail at once and consume the queue)
    /// or appended to the log (an orphan's fold), which can leave a view line
    /// unsummarized again; then the queue stays and the wait starts over
    /// (section 6: no call ever sees the placeholder).
    pub(super) fn settled(&mut self) -> Option<TurnStart> {
        if !self.ready() {
            // The next `Up` starts the turn.
            self.phase = Phase::Idle;
            return None;
        }
        if self.chat.status().unbuilt > 0 {
            self.phase = Phase::Idle;
            self.maybe_start_turn();
            return None;
        }
        let start = self.take_turn();
        if start.is_none() && self.phase == Phase::Settling {
            self.phase = Phase::Idle;
        }
        start
    }

    /// Section 7 after `settle`: take every queued message, render the view
    /// BEFORE logging them, then log each as `user`.
    fn take_turn(&mut self) -> Option<TurnStart> {
        if self.queue.is_empty() {
            return None;
        }
        let items: Vec<Queued> = self.queue.drain(..).collect();
        let view = self.chat.render_view();
        // Saved before the first append: a crash between an append and the
        // next save must not log a message twice at restart (recover.rs).
        let first_id = self.chat.status().messages;
        self.state.turn = Some(PendingTurn {
            conversation: self.state.conversation.clone(),
            session: format!("{}-{first_id}", self.settings.turn_prefix),
            first_id: Some(first_id),
            items: items.iter().map(item).collect(),
            ..PendingTurn::default()
        });
        self.save();
        let first = self.log_items(&items)?;
        let key = reply_key(&self.chat, first);
        if let Some(turn) = self.state.turn.as_mut() {
            turn.key = key.clone();
        }
        self.save();
        self.set_cursor(self.handled);
        self.set_typing(true);
        self.phase = Phase::Running;
        self.stop_wanted = false;
        let items_sources: Vec<&'static str> =
            items.iter().map(|i| source_name(&i.source)).collect();
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        // The engine of this turn, read now (engine.rs): a change applies
        // from this turn on and is logged as a note after its messages.
        let engine = self.turn_engine_choice();
        let family = self.family_of(&engine.harness);
        self.note_engine(&engine);
        let default_family = self.family_of(&self.settings.harness);
        // The cached layout on a Claude harness whose acpmux takes a preset
        // system prompt; else the view and the messages as blocks.
        let cached = (matches!(self.settings.engine, Engine::Acpmux)
            && family == crate::acpmux::Family::Claude)
            .then_some(self.settings.turn_preset.as_deref())
            .flatten()
            .filter(|preset| self.agents.system_prompt(preset));
        let (blocks, system_prompt, preset) = match cached {
            Some(preset) => {
                let layout = cached_layout(
                    &self.settings.system_text,
                    &view.text,
                    &texts.join("\n\n"),
                    !self.marker_refused.load(Ordering::SeqCst),
                );
                (layout.blocks, Some(layout.system), Some(preset.to_owned()))
            }
            None => {
                // The family's own preset when the turn left the default
                // harness's family (the port falls back to the default's).
                let preset = match family {
                    crate::acpmux::Family::Codex => self.settings.codex_preset.clone(),
                    crate::acpmux::Family::Claude if default_family != family => {
                        self.settings.turn_preset.clone()
                    }
                    _ => None,
                };
                (turn_blocks(&view.text, &texts), None, preset)
            }
        };
        if self.settings.turn_preset.is_some() && family == crate::acpmux::Family::Claude {
            // The system prompt carries the instructions in the cached
            // layout; the old layout reads them from CLAUDE.md.
            let text = system_prompt
                .is_none()
                .then_some(self.settings.system_text.as_str());
            if let Err(e) = crate::session_dir::set_claude_md(&self.settings.session_dir, text) {
                (self.log)(&format!("updating the session directory's CLAUDE.md: {e}"));
            }
        }
        self.trace_start(
            &key,
            first,
            &view.text,
            &texts,
            &items_sources,
            system_prompt.as_deref(),
        );
        Some(TurnStart {
            prompt_id: format!("optchat:{first}"),
            session: SessionSpec {
                name: format!("{}-{first}", self.settings.turn_prefix),
                cwd: self.settings.session_dir.clone(),
                harness: engine.harness.clone(),
                policy: self.settings.policy.clone(),
                model: engine.model.clone(),
                effort: engine.effort.clone(),
                preset,
                tags: crate::acpmux::chief_tags(&self.settings.chief_id, "turn"),
            },
            blocks,
            system_prompt,
            key,
            limit: self.settings.turn_limit,
        })
    }

    /// Logs `items` as `user` entries and finishes their bookkeeping; returns
    /// the first one's id. On a failed write nothing is posted for them and
    /// the host stops (the conversation's cursor stays before them).
    fn log_items(&mut self, items: &[Queued]) -> Option<u64> {
        let mut first = None;
        for item in items {
            match self.chat.append(Kind::User, &item.text) {
                Ok(id) => {
                    first.get_or_insert(id);
                }
                Err(e) => {
                    (self.log)(&format!("logging a message failed: {e}"));
                    self.fatal = Some(format!("the memory stopped writing: {e}"));
                    self.phase = Phase::Idle;
                    return None;
                }
            }
        }
        for item in items {
            if let Source::Child { session_id, floor } = &item.source
                && let Some(record) = self.state.children.get_mut(session_id)
            {
                record.status = ChildStatus::Reported;
                record.floor = *floor;
            }
            if let Source::Spawn(r) = &item.source {
                self.state.spawn_logged(r);
                self.trace_report_logged(r, &item.text);
            }
        }
        // The queue is empty now, so every handled seq is logged or needed no log.
        self.state.logged_seq = self.handled;
        first
    }

    /// A native turn is between tool calls: everything queued is logged as
    /// `user` and delivered (section 7: "Messages the user types mid-run are
    /// delivered at the agent's next tool boundary and logged as `user`").
    pub(super) fn boundary(&mut self, key: &str) -> Vec<String> {
        let current = self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if self.phase != Phase::Running || !current {
            return Vec::new();
        }
        // Everything queued is delivered now: the interrupt is answered.
        self.interrupt.clear();
        if self.queue.is_empty() {
            return Vec::new();
        }
        let items: Vec<Queued> = self.queue.drain(..).collect();
        let at = self.chat.status().messages;
        if let Some(turn) = self.state.turn.as_mut() {
            turn.mid.push(Batch {
                at,
                items: items.iter().map(item).collect(),
                done: false,
            });
        }
        self.save();
        if self.log_items(&items).is_none() {
            return Vec::new();
        }
        if let Some(batch) = self.state.turn.as_mut().and_then(|t| t.mid.last_mut()) {
            batch.done = true;
        }
        self.save();
        self.set_cursor(self.handled);
        items.into_iter().map(|i| i.text).collect()
    }

    /// A human message arrived during a turn (decision 2026-10-04): the
    /// model is interrupted at once, even mid-thinking, and a running tool
    /// call finishes first. The native engine aborts its stream and calls
    /// the model again with the message; the acpmux engine stops the turn
    /// (`session/cancel`, sent by the turn's runner once no tool runs, and
    /// again until the turn ends), and the next fresh turn answers with the
    /// view of everything the stopped turn did. "thanks" interrupts too.
    pub(super) fn interrupt_for_newer(&mut self) {
        if self.phase != Phase::Running {
            return;
        }
        if matches!(self.settings.engine, Engine::Acpmux) {
            self.stop_wanted = true;
        }
        self.interrupt.request();
    }

    /// An acpmux turn's session id and fold position, saved so a host that
    /// stops mid-turn folds the rest at the next start.
    pub(super) fn progress(&mut self, key: &str, session_id: String, after: u64) {
        let Some(turn) = self.state.turn.as_mut().filter(|t| t.key == key) else {
            return;
        };
        if turn.session_id.as_deref() != Some(session_id.as_str()) || turn.after != after {
            turn.session_id = Some(session_id);
            turn.after = after;
            self.save();
        }
    }

    /// The trace's `turn.start`: what the turn reads, the view's size and
    /// the hash of each cached piece, how much of the previous turn's view
    /// is unchanged, and how long the settle wait took.
    fn trace_start(
        &mut self,
        key: &str,
        first: u64,
        view: &str,
        texts: &[String],
        sources: &[&'static str],
        system: Option<&str>,
    ) {
        self.turn_clock = Some(std::time::Instant::now());
        let settle_ms = self
            .settle_clock
            .take()
            .map(|t| t.elapsed().as_millis() as u64);
        if !self.trace.is_on() {
            return;
        }
        let unchanged = self
            .prev_view
            .as_deref()
            .map(|prev| (crate::trace::common_prefix(prev, view), prev.len()));
        let system_text = system.unwrap_or(&self.settings.system_text);
        self.trace.emit(
            "turn.start",
            serde_json::json!({
                "turn": key,
                "first": first,
                "engine": match self.settings.engine { Engine::Acpmux => "acpmux", Engine::Native(_) => "native" },
                "harness": self.turn_engine.as_ref().map_or(self.settings.harness.as_str(), |e| e.harness.as_str()),
                "model": self.turn_engine.as_ref().and_then(|e| e.model.clone()),
                "effort": self.turn_engine.as_ref().and_then(|e| e.effort.clone()),
                "settle_ms": settle_ms,
                "messages": texts.iter().map(|t| self.trace.text(t)).collect::<Vec<_>>(),
                "sources": sources,
                "view": {
                    "bytes": view.len(),
                    "lines": view.lines().count(),
                    "hash": crate::trace::hash(view),
                    "pieces": crate::trace::pieces(view),
                    "unchanged_prefix_bytes": unchanged.map(|u| u.0),
                    "prev_bytes": unchanged.map(|u| u.1),
                },
                "system": {"bytes": system_text.len(), "hash": crate::trace::hash(system_text), "with_view_head": system.is_some()},
            }),
        );
        self.prev_view = Some(view.to_owned());
    }

    /// This turn's engine: engine.json over the defaults. A harness acpmux
    /// does not know keeps the default harness, and says so.
    fn turn_engine_choice(&mut self) -> crate::engine::TurnEngine {
        let s = &self.settings;
        let choice = s
            .engine_file
            .as_deref()
            .map(crate::engine::load)
            .unwrap_or_default();
        let mut engine =
            crate::engine::resolve(&choice, &s.harness, s.model.as_deref(), s.effort.as_deref());
        if !s.families.is_empty() && !s.families.contains_key(&engine.harness) {
            (self.log)(&format!(
                "engine.json names harness {}, which acpmux does not have; this turn runs on {}",
                engine.harness, s.harness
            ));
            engine.harness = s.harness.clone();
        }
        self.turn_engine = Some(engine.clone());
        engine
    }

    /// A harness's family (the default harness is Claude in a brain made
    /// without acpmux's metadata when it has a turn preset).
    fn family_of(&self, harness: &str) -> crate::acpmux::Family {
        match self.settings.families.get(harness) {
            Some(f) => *f,
            None if self.settings.families.is_empty() && self.settings.turn_preset.is_some() => {
                crate::acpmux::Family::Claude
            }
            None => crate::acpmux::Family::Other,
        }
    }

    /// Logs an engine change as a note (after the turn's messages, so the
    /// pending turn's positions stay right) and into the trace.
    fn note_engine(&mut self, engine: &crate::engine::TurnEngine) {
        let now = engine.describe();
        let before = self.state.engine.clone();
        if before.as_deref() == Some(now.as_str()) {
            return;
        }
        if let Some(before) = &before {
            let text = format!("engine changed to {now} (was {before})");
            if let Err(e) = self.chat.append(Kind::Note, &text) {
                (self.log)(&format!("logging the engine change failed: {e}"));
            }
            (self.log)(&text);
        }
        self.trace.emit(
            "engine",
            serde_json::json!({"harness": engine.harness, "model": engine.model, "effort": engine.effort, "was": before}),
        );
        self.state.engine = Some(now);
        self.save();
    }

    /// The trace's `turn.end`.
    fn trace_end(&mut self, key: &str, outcome: &TurnOutcome, superseded: bool) {
        let ms = self
            .turn_clock
            .take()
            .map(|t| t.elapsed().as_millis() as u64);
        if !self.trace.is_on() {
            return;
        }
        let s = &outcome.stats;
        let status = if superseded {
            "superseded"
        } else if outcome.refused && outcome.reply.is_none() {
            "refused"
        } else if outcome.cancelled {
            "cancelled"
        } else if outcome.error.is_some() {
            "error"
        } else {
            "ok"
        };
        self.trace.emit(
            "turn.end",
            serde_json::json!({
                "turn": key,
                "ms": ms,
                "status": status,
                "harness": self.turn_engine.as_ref().map(|e| e.harness.clone()),
                "model": self.turn_engine.as_ref().and_then(|e| e.model.clone()),
                "effort": self.turn_engine.as_ref().and_then(|e| e.effort.clone()),
                "error": outcome.error.as_deref().map(|e| self.trace.text(e)),
                "reply": outcome.reply.as_deref().map(|r| self.trace.text(r)),
                "first_usage": s.first.as_ref().map(crate::trace::usage),
                "usage": s.totals.as_ref().map(|(u, _)| crate::trace::usage(u)),
                "usage_scope": s.totals.as_ref().map(|(_, scope)| *scope),
                "cost_usd": s.cost,
                "requests": s.requests,
                "tools": s.tools,
                "tool_errors": s.tool_errors,
                // What answered (harness_gate): the engine panel reads these.
                "harness_profile": outcome.harness.as_ref().map(|h| h.profile.as_str()),
                "harness_kind": outcome.harness.as_ref().map(|h| h.kind.as_str()),
                "harness_argv0": outcome.harness.as_ref().map(|h| h.argv0.as_str()),
                "harness_refused": outcome.refused,
            }),
        );
    }

    pub(super) fn turn_ended(&mut self, key: &str, outcome: TurnOutcome) {
        let conversation = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .and_then(|t| t.conversation.clone());
        // A turn stopped for a newer message posts nothing: the next turn,
        // which starts now with that message, answers both.
        let superseded = outcome.cancelled && self.stop_wanted;
        self.trace_end(key, &outcome, superseded);
        // A turn that failed after it said something posts both: its last
        // words alone (often "Let me check.") would read as the answer.
        let text = match (outcome.reply, outcome.error) {
            _ if superseded => String::new(),
            (None, Some(error)) if outcome.refused => format!("(turn {error})"),
            (Some(reply), Some(error)) => format!("{reply}\n\n(turn failed: {error})"),
            (Some(reply), None) => reply,
            (None, Some(error)) => format!("(turn failed: {error})"),
            (None, None) => String::new(),
        };
        if superseded {
            (self.log)(&format!("turn {key} stopped for a newer message"));
        }
        if let Some(orphan) = outcome.orphan {
            self.state.orphans.push(orphan);
        }
        match conversation {
            Some(conversation) if !text.is_empty() => {
                self.state
                    .outbox
                    .push(reply_entry(conversation, key, &text));
            }
            Some(_) => {}
            None => (self.log)(&format!(
                "turn {key} ended with no conversation to answer in"
            )),
        }
        self.state.turn = None;
        self.stop_wanted = false;
        self.save();
        self.flush_outbox();
        self.set_typing(false);
        self.phase = Phase::Idle;
        if let Some(hook) = &self.after_turn {
            hook(key);
        }
        self.maybe_start_turn();
    }
}

/// A queued item's source in the trace.
fn source_name(source: &Source) -> &'static str {
    match source {
        Source::Message { .. } => "human",
        Source::Child { .. } => "child",
        Source::Spawn(_) => "subagents",
        Source::Note => "note",
    }
}

/// A queued item's source as the pending turn saves it.
fn item(queued: &Queued) -> Item {
    match &queued.source {
        Source::Message { seq } => Item {
            seq: Some(*seq),
            ..Item::default()
        },
        Source::Child { session_id, floor } => Item {
            child: Some(ChildRef {
                session_id: session_id.clone(),
                floor: *floor,
            }),
            ..Item::default()
        },
        Source::Spawn(r) => Item {
            spawn: Some(r.clone()),
            ..Item::default()
        },
        Source::Note => Item::default(),
    }
}
