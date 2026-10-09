//! The turn loop (section 7): the settle worker, taking the queue into a
//! turn, delivering messages between tool calls (native engine) or
//! stopping the turn for them (acpmux engine), and the turn's end.

use std::sync::Arc;
use std::sync::mpsc::channel;

use optchat_core::Kind;

use super::{
    Brain, Engine, Input, PROGRESS_TICK, Phase, Queued, STALL_NOTICE, Source, reply_entry,
    reply_key_at,
};
use std::sync::atomic::Ordering;

use crate::acpmux::SessionSpec;
use crate::compactor::is_marker_limit_error;
use crate::prompt::{CacheTtl, Mark, cached_layout_marked, is_ttl_refused_error, turn_blocks};
use crate::state::{Batch, ChildRef, ChildStatus, HostState, Item, PendingTurn};
use crate::turn::{self, Interrupt, TurnOutcome, TurnStart};
use optchat_host::{Appended, NewMessage};

impl Brain {
    /// Starts a turn worker when idle with something queued.
    pub(super) fn maybe_start_turn(&mut self) {
        if self.phase != Phase::Idle || !self.queue.iter().any(Queued::wakes) || !self.ready() {
            return;
        }
        self.phase = Phase::Settling;
        self.settle_clock
            .get_or_insert_with(std::time::Instant::now);
        self.interrupt = Arc::new(Interrupt::new());
        let trace = self.trace.clone();
        let settle_status = self.settle_status.clone();
        let (chat, agents, tx, log, engine, interrupt, marker_refused) = (
            self.chat.clone(),
            self.agents.clone(),
            self.tx.clone(),
            self.log.clone(),
            self.settings.engine.clone(),
            self.interrupt.clone(),
            self.marker_refused.clone(),
        );
        let (ttl_refused, ttl_stale, session_dir) = (
            self.ttl_refused.clone(),
            self.ttl_stale.clone(),
            self.settings.session_dir.clone(),
        );
        let spawned = std::thread::Builder::new()
            .name("turn".into())
            .spawn(move || {
                // Section 6: no turn starts before every view line is a summary.
                // The wait has no deadline; a line each minute says what it
                // waits on, and the first one with a failing node also goes to
                // the conversation, so the user is not left without a word.
                // Every PROGRESS_TICK of waiting, `settle.json` says how far
                // the compactor is (the app's "Organizing Chief history");
                // a wait shorter than one tick shows nothing.
                let mut told = false;
                let mut waited = std::time::Duration::ZERO;
                let settled = loop {
                    if chat.settle(None, Some(PROGRESS_TICK)) {
                        break true;
                    }
                    waited += PROGRESS_TICK;
                    let status = chat.status();
                    if status.closed || status.fatal.is_some() {
                        break false;
                    }
                    if let Some(settle) = &settle_status {
                        settle.waiting(&status);
                    }
                    if waited < STALL_NOTICE {
                        continue;
                    }
                    waited = std::time::Duration::ZERO;
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
                };
                if let Some(settle) = &settle_status {
                    settle.clear();
                }
                if !settled {
                    let _ = tx.send(Input::SettleFailed);
                    return;
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
                        // The TTL our marks carry in this request.
                        let ours = if start.blocks.iter().any(|b| {
                            b.get("cache_control") == Some(&CacheTtl::OneHour.cache_control())
                        }) {
                            Some(CacheTtl::OneHour)
                        } else {
                            marked.then_some(CacheTtl::FiveMinutes)
                        };
                        let stale = ttl_stale.load(Ordering::SeqCst);
                        match (&outcome.error, ours) {
                            // The API refused our TTL next to Claude Code's.
                            // A pooled session started under the other TTL
                            // (cache.ttl changed since the prewarm): the
                            // same turn once at that TTL. Else the route
                            // takes no 1-hour TTL: the same turn at 5
                            // minutes, and later turns stay at 5 minutes.
                            (Some(e), Some(ttl))
                                if is_ttl_refused_error(e)
                                    && (stale || ttl == CacheTtl::OneHour) =>
                            {
                                let retry = match ttl {
                                    CacheTtl::OneHour => CacheTtl::FiveMinutes,
                                    CacheTtl::FiveMinutes => CacheTtl::OneHour,
                                };
                                if !stale {
                                    ttl_refused.store(true, Ordering::SeqCst);
                                }
                                trace.emit(
                                    "turn.ttl_refused",
                                    serde_json::json!({"turn": start.key, "ttl": retry.as_str()}),
                                );
                                log(&format!(
                                    "turn {}: the API refused the {} cache TTL ({e}); running the turn again at {}{}",
                                    start.key,
                                    ttl.as_str(),
                                    retry.as_str(),
                                    if stale {
                                        " (its session started before cache.ttl changed)"
                                    } else {
                                        ", and later turns go at 5 minutes (set cache.ttl to try 1h again)"
                                    }
                                ));
                                if let Err(e) =
                                    crate::session_dir::set_prompt_cache_ttl(&session_dir, retry)
                                {
                                    log(&format!("updating the session's promptCacheTtl: {e}"));
                                }
                                let mut again = start.clone();
                                for block in &mut again.blocks {
                                    if block.get("cache_control").is_some() {
                                        block["cache_control"] = retry.cache_control();
                                    }
                                }
                                again.prompt_id = format!("{}:{}", start.prompt_id, retry.as_str());
                                turn::run(&*agents, &chat, &again, &interrupt, &*log, &progress, &trace)
                            }
                            (Some(e), _) if marked && is_marker_limit_error(e) => {
                                marker_refused.store(true, Ordering::SeqCst);
                                // The inspector lays this turn out unmarked.
                                trace.emit("turn.unmarked", serde_json::json!({"turn": start.key}));
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
                        native.run_gated(
                            &chat,
                            &start,
                            &*log,
                            &mailbox,
                            &|| interrupt.is_set(),
                            &|| interrupt.gated(),
                        )
                    }
                };
                let _ = tx.send(Input::TurnEnded {
                    key: start.key,
                    outcome: Box::new(outcome),
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

    /// Section 7 after `settle`: take the queued items of the head item's
    /// conversation (G9: the others wait their turn), render the view BEFORE
    /// logging them, then log each as `user`.
    fn take_turn(&mut self) -> Option<TurnStart> {
        // The conversation of the first item that wakes (a quiet report waits).
        let head = self.queue.iter().find(|q| q.wakes());
        let side = head.or(self.queue.front())?.conversation.clone();
        let (items, rest): (Vec<Queued>, Vec<Queued>) =
            self.queue.drain(..).partition(|q| q.conversation == side);
        self.queue.extend(rest);
        let view = self.chat.render_view();
        // The messages, their bookkeeping (floors, children) and the pending
        // turn commit together: a crash leaves all of it or none of it, so a
        // restart never logs a message twice and never loses one.
        let first_id = self.chat.status().messages;
        let session = format!("{}-{first_id}", self.settings.turn_prefix);
        let conversation = side.clone().or_else(|| self.state.conversation.clone());
        let opening: Vec<Item> = items.iter().map(item).collect();
        let done = self.log_items(&items, move |next, done| {
            let first = done.ids.first().copied().unwrap_or(first_id);
            let stamp = done.stamps.first().map(String::as_str).unwrap_or("");
            next.turn = Some(PendingTurn {
                key: reply_key_at(first, stamp),
                conversation,
                session,
                first_id: Some(first_id),
                items: opening,
                ..PendingTurn::default()
            });
        })?;
        let first = done.ids.first().copied().unwrap_or(first_id);
        let key = self
            .state
            .turn
            .as_ref()
            .map(|t| t.key.clone())
            .unwrap_or_default();
        optchat_host::fault("brain:after-turn-log");
        self.set_cursor(self.state.logged_seq);
        if side.is_none() {
            self.set_typing(true);
        }
        self.phase = Phase::Running;
        self.stop_wanted = false;
        let items_sources: Vec<&'static str> =
            items.iter().map(|i| source_name(&i.source)).collect();
        // The strictest origin of the turn: a paired device's message (or
        // a remote turn this one supersedes) makes it ask for every local
        // effect, unless the user turned on remote.autoApprove on the Mac.
        self.turn_remote = std::mem::take(&mut self.remote_taint)
            || items.iter().any(|i| {
                matches!(
                    i.source,
                    Source::Message {
                        remote: Some(_),
                        ..
                    }
                )
            });
        self.turn_ask = self.turn_remote && !self.chief.remote_auto_approve;
        self.clear_turn_approvals();
        self.interrupt.set_gate(self.turn_ask);
        // The shared rule (cmux_chief::policy::turn_policy, the corpus's
        // `policy` cases).
        let policy = cmux_chief::policy::turn_policy(
            self.turn_remote,
            self.chief.remote_auto_approve,
            &self.settings.policy,
        );
        let images: Vec<super::images::TurnImage> = items
            .iter()
            .flat_map(|i| i.images.iter().cloned())
            .collect();
        let image_blocks: Vec<serde_json::Value> = images
            .iter()
            .filter_map(super::images::TurnImage::block)
            .collect();
        self.describe_images(&images);
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        // Per-turn state goes after the view, never in the system prompt:
        // the subagents at work now (the reference client's line), before
        // the new messages. Never logged.
        let at_work = self.at_work_line();
        let prompt_texts: Vec<String> = at_work.iter().chain(texts.iter()).cloned().collect();
        // The engine of this turn, read now (engine.rs): a change applies
        // from this turn on and is logged as a note after its messages.
        let engine = self.turn_engine_choice();
        let family = self.family_of(&engine.harness);
        self.note_engine(&engine);
        // The cached layout on a Claude harness whose acpmux takes a preset
        // system prompt; else the view and the messages as blocks.
        let (cached, plain_preset) = self.session_presets(family);
        let cached = cached.as_deref();
        let marker = !self.marker_refused.load(Ordering::SeqCst);
        let ttl = self.turn_cache_ttl();
        // Our one mark: the last whole block of the view, held within the
        // API's lookback of the last turn's mark (optchat_core::mark_piece).
        let mut mark = None;
        let (blocks, system_prompt, preset) = match cached {
            Some(preset) => {
                mark = marker
                    .then(|| optchat_core::mark_piece(&view.text, self.last_mark.as_deref()))
                    .flatten()
                    .map(|piece| Mark { piece, ttl });
                self.last_mark = mark.map(|m| {
                    optchat_core::block_pieces(&view.text)[..=m.piece].concat()
                });
                // Claude Code's own marks take the same TTL: the API refuses
                // a 1h mark after a 5m one. A session the pool started
                // before a cache.ttl change still has the old one.
                self.ttl_stale.store(
                    self.prewarm_ttl.is_some_and(|p| p != ttl),
                    Ordering::SeqCst,
                );
                if let Err(e) =
                    crate::session_dir::set_prompt_cache_ttl(&self.settings.session_dir, ttl)
                {
                    (self.log)(&format!("updating the session's promptCacheTtl: {e}"));
                }
                let layout = cached_layout_marked(
                    &self.settings.system_text,
                    &view.text,
                    &prompt_texts.join("\n\n"),
                    mark,
                );
                (layout.blocks, Some(layout.system), Some(preset.to_owned()))
            }
            None => (turn_blocks(&view.text, &prompt_texts), None, plain_preset),
        };
        let image_count = image_blocks.len();
        let blocks = with_images(blocks, image_blocks);
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
        // How the prompt was laid out, so the inspector can lay it out again
        // from the trace (inspect.rs): the cached layout and its marker, or
        // the view's pieces then the messages.
        let mut layout = if system_prompt.is_some() {
            serde_json::json!({
                "kind": "cached",
                "marker": mark.is_some(),
                "mark": mark.map(|m| m.piece),
                "ttl": ttl.as_str(),
            })
        } else {
            serde_json::json!({"kind": "blocks"})
        };
        layout["images"] = serde_json::json!(image_count);
        if let Some(line) = &at_work {
            layout["at_work"] = serde_json::json!(line);
        }
        self.trace_start(
            &key,
            first,
            &view,
            &texts,
            &done.ids,
            &items_sources,
            system_prompt.as_deref(),
            layout,
        );
        Some(TurnStart {
            prompt_id: format!("optchat:{first}"),
            session: SessionSpec {
                name: format!("{}-{first}", self.settings.turn_prefix),
                cwd: self.settings.session_dir.clone(),
                harness: engine.harness.clone(),
                policy,
                model: engine.model.clone(),
                effort: engine.effort.clone(),
                preset,
                tags: crate::acpmux::chief_tags(&self.settings.chief_id, "turn"),
                env: Default::default(),
            },
            blocks,
            system_prompt,
            key,
            limit: self.settings.turn_limit,
        })
    }

    /// Logs `items` as `user` entries and, in the same transaction, the
    /// state their bookkeeping leaves (each child's report marked, the read
    /// cursor past every handled message, then `update`). On a failed write
    /// nothing is posted for them and the host stops (the conversation's
    /// cursor stays before them).
    fn log_items(
        &mut self,
        items: &[Queued],
        update: impl FnOnce(&mut HostState, &Appended),
    ) -> Option<Appended> {
        let main = self.state.conversation.clone().unwrap_or_default();
        let entries: Vec<NewMessage<'_>> = items
            .iter()
            .map(|q| NewMessage {
                key: match q.source {
                    Source::Message { seq, .. } => Some(format!(
                        "{}#{seq}",
                        q.conversation.as_deref().unwrap_or(&main)
                    )),
                    _ => None,
                },
                ..NewMessage::new(Kind::User, &q.text)
            })
            .collect();
        let mut next = self.state.clone();
        // Each conversation's floor: every handled seq is logged or needed no
        // log, except what is still queued (other conversations' items wait).
        let handled = self.floor_of(None, self.handled);
        let side_floors: Vec<(String, u64)> = items
            .iter()
            .filter_map(|q| q.conversation.clone())
            .map(|c| {
                let handled = self.side_handled.get(&c).copied().unwrap_or(0);
                let floor = self.floor_of(Some(&c), handled);
                (c, floor)
            })
            .collect();
        let file = &self.file;
        let mut writes = Vec::new();
        let result = self.chat.append_with(&entries, |done| {
            for item in items {
                if let Source::Child { session_id, floor } = &item.source
                    && let Some(record) = next.children.get_mut(session_id)
                {
                    record.status = ChildStatus::Reported;
                    record.floor = *floor;
                }
                if let Source::Spawn(r) = &item.source {
                    next.spawn_logged(r);
                }
                if let (Some(c), Source::Message { seq, id, .. }) =
                    (&item.conversation, &item.source)
                {
                    next.side.entry(c.clone()).or_default().handled(*seq, id);
                }
            }
            for (c, floor) in &side_floors {
                let saved = next.side.entry(c.clone()).or_default();
                saved.seq = saved.seq.max(*floor);
            }
            next.logged_seq = handled;
            update(&mut next, done);
            writes = file.writes(&next);
            writes.clone()
        });
        match result {
            Ok(done) => {
                self.state = next;
                self.file.committed(&writes);
                for item in items {
                    if let Source::Spawn(r) = &item.source {
                        self.trace_report_logged(r, &item.text);
                    }
                }
                Some(done)
            }
            Err(e) => {
                (self.log)(&format!("logging a message failed: {e}"));
                self.fatal = Some(format!("the memory stopped writing: {e}"));
                self.phase = Phase::Idle;
                None
            }
        }
    }

    /// A native turn is between tool calls: everything queued is logged as
    /// `user` and delivered (section 7: "Messages the user types mid-run are
    /// delivered at the agent's next tool boundary and logged as `user`").
    pub(super) fn boundary(&mut self, key: &str) -> Vec<serde_json::Value> {
        let current = self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if self.phase != Phase::Running || !current {
            return Vec::new();
        }
        // Everything queued for this turn's conversation is delivered now:
        // the interrupt is answered. Only the items ahead of the first one
        // of another conversation go (G9 fairness: an item that waits for
        // its turn is never passed by later ones).
        self.interrupt.clear();
        let side = self.turn_side();
        let take = self
            .queue
            .iter()
            .take_while(|q| q.conversation == side)
            .count();
        if take == 0 {
            return Vec::new();
        }
        let items: Vec<Queued> = self.queue.drain(..take).collect();
        if items.iter().any(|i| {
            matches!(
                i.source,
                Source::Message {
                    remote: Some(_),
                    ..
                }
            )
        }) {
            self.turn_remote = true;
            self.turn_ask = !self.chief.remote_auto_approve;
            self.interrupt.set_gate(self.turn_ask);
        }
        let at = self.chat.status().messages;
        let batch: Vec<Item> = items.iter().map(item).collect();
        let logged = self.log_items(&items, move |next, _| {
            if let Some(turn) = next.turn.as_mut() {
                turn.mid.push(Batch {
                    at,
                    items: batch,
                    done: true,
                });
            }
        });
        if logged.is_none() {
            return Vec::new();
        }
        self.set_cursor(self.state.logged_seq);
        // The delivered messages' images go with them, and are described
        // for the log like a turn's own.
        let images: Vec<super::images::TurnImage> = items
            .iter()
            .flat_map(|i| i.images.iter().cloned())
            .collect();
        self.describe_images(&images);
        let mut blocks: Vec<serde_json::Value> = images
            .iter()
            .filter_map(super::images::TurnImage::block)
            .collect();
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        blocks.push(serde_json::json!({"type": "text", "text": texts.join("\n\n")}));
        blocks
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
        // A pending approval holds the tool call: a newer message denies it,
        // so the turn can stop and the next one answers.
        self.deny_pending("a newer message");
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
    #[allow(clippy::too_many_arguments)]
    fn trace_start(
        &mut self,
        key: &str,
        first: u64,
        rendered: &optchat_host::RenderedView,
        texts: &[String],
        ids: &[u64],
        sources: &[&'static str],
        system: Option<&str>,
        layout: serde_json::Value,
    ) {
        let view = rendered.text.as_str();
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
                // The log ids of the messages (the prompt's last block).
                "message_ids": ids,
                "sources": sources,
                "layout": layout,
                "view": {
                    "bytes": view.len(),
                    "lines": view.lines().count(),
                    "hash": crate::trace::hash(view),
                    "pieces": crate::trace::pieces(view),
                    // The tree node of each line, oldest first (`id+n`): with
                    // the stored node texts they render this view again.
                    "parts": rendered.parts.iter().map(|p| p.name()).collect::<Vec<_>>(),
                    "unchanged_prefix_bytes": unchanged.map(|u| u.0),
                    "prev_bytes": unchanged.map(|u| u.1),
                },
                "system": {"bytes": system_text.len(), "hash": crate::trace::hash(system_text), "with_view_head": system.is_some()},
            }),
        );
        self.prev_view = Some(view.to_owned());
    }

    /// The cache TTL of this turn on the Claude Code path:
    /// `OPTCHAT_CACHE_TTL`, else the Chief's `cache.ttl`, else 1 hour; 5
    /// minutes once a route refused 1 hour.
    pub(super) fn turn_cache_ttl(&self) -> CacheTtl {
        if self.ttl_refused.load(Ordering::SeqCst) {
            return CacheTtl::FiveMinutes;
        }
        self.settings
            .cache_ttl
            .or(self.chief.cache_ttl)
            .unwrap_or(CacheTtl::OneHour)
    }

    /// This turn's engine: engine.json over the defaults. A harness acpmux
    /// does not know keeps the default harness, and says so.
    fn turn_engine_choice(&mut self) -> crate::engine::TurnEngine {
        let (engine, unknown) = self.next_engine();
        if let Some(named) = unknown {
            (self.log)(&format!(
                "engine.json names harness {named}, which acpmux does not have; this turn runs on {}",
                engine.harness
            ));
        }
        self.turn_engine = Some(engine.clone());
        engine
    }

    /// The engine a spawn's subagents take: the running (or last) turn's,
    /// with its family when that is not the default harness's.
    pub(super) fn spawn_engine(&self) -> Option<crate::subagents::SpawnEngine> {
        let engine = self.turn_engine.as_ref()?;
        let family = self.family_of(&engine.harness);
        Some(crate::subagents::SpawnEngine {
            harness: engine.harness.clone(),
            model: engine.model.clone(),
            other_family: (family != self.family_of(&self.settings.harness)).then_some(family),
        })
    }

    /// A harness's family (the default harness is Claude in a brain made
    /// without acpmux's metadata when it has a turn preset).
    pub(super) fn family_of(&self, harness: &str) -> crate::acpmux::Family {
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
                // Time to first token (parity item 10): the session's start,
                // then the first request's first token.
                "start_ms": s.start_ms,
                "ttft_ms": s.ttft_ms,
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
        // A failure names the harness that ran the turn, and the one it
        // stood in for when acpmux moved the session onto a fallback.
        let failed = match outcome.harness.as_deref() {
            Some(h) if h.requested != h.profile => {
                format!(
                    "turn failed on {} (fallback for {})",
                    h.profile, h.requested
                )
            }
            Some(h) => format!("turn failed on {}", h.profile),
            None => "turn failed".to_owned(),
        };
        // A turn that failed after it said something posts both: its last
        // words alone (often "Let me check.") would read as the answer.
        let owner_stopped = std::mem::take(&mut self.owner_stopped);
        let text = match (outcome.reply, outcome.error) {
            _ if superseded => String::new(),
            (reply, _) if owner_stopped && outcome.cancelled => match reply {
                Some(reply) => format!("{reply}\n\n(turn stopped)"),
                None => "(turn stopped)".to_owned(),
            },
            (None, Some(error)) if outcome.refused => format!("(turn {error})"),
            (Some(reply), Some(error)) => format!("{reply}\n\n({failed}: {error})"),
            (Some(reply), None) => reply,
            (None, Some(error)) => format!("({failed}: {error})"),
            (None, None) => String::new(),
        };
        if superseded {
            (self.log)(&format!("turn {key} stopped for a newer message"));
            // The turn that answers both keeps this one's remote origin.
            self.remote_taint |= self.turn_remote;
        }
        self.turn_remote = false;
        self.turn_ask = false;
        self.clear_turn_approvals();
        self.interrupt.set_gate(false);
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
        // The session's fold position goes with the pending turn, unless the
        // session lives on as an orphan whose fold continues from it.
        let session = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .and_then(|t| t.session_id.clone());
        let orphaned = |s: &String| self.state.orphans.iter().any(|o| &o.session == s);
        let extra = match session {
            Some(s) if !orphaned(&s) => vec![(crate::state::fold_key(&s), None)],
            _ => Vec::new(),
        };
        let main = self.turn_side().is_none();
        self.state.turn = None;
        self.stop_wanted = false;
        self.save_with(extra);
        self.flush_outbox();
        if main {
            self.set_typing(false);
        }
        self.phase = Phase::Idle;
        if let Some(hook) = &self.after_turn {
            hook(key);
        }
        self.prewarm_next_turn();
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

/// The turn's images go just before its last block (the new messages, which
/// name them), so the view blocks and their cache marker stay as they were.
fn with_images(
    mut blocks: Vec<serde_json::Value>,
    images: Vec<serde_json::Value>,
) -> Vec<serde_json::Value> {
    if images.is_empty() {
        return blocks;
    }
    let tail = blocks.pop();
    blocks.extend(images);
    blocks.extend(tail);
    blocks
}

/// A queued item's source as the pending turn saves it.
fn item(queued: &Queued) -> Item {
    let images = queued.images.iter().map(|i| i.source.clone()).collect();
    match &queued.source {
        Source::Message { seq, id, .. } => Item {
            seq: Some(*seq),
            images,
            conversation: queued.conversation.clone(),
            id: queued.conversation.as_ref().map(|_| id.clone()),
            ..Item::default()
        },
        Source::Child { session_id, floor } => Item {
            child: Some(ChildRef {
                session_id: session_id.clone(),
                floor: *floor,
            }),
            images,
            ..Item::default()
        },
        Source::Spawn(r) => Item {
            spawn: Some(r.clone()),
            images,
            ..Item::default()
        },
        Source::Note => Item {
            images,
            ..Item::default()
        },
    }
}
