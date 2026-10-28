//! The turn loop (section 7): the settle worker, taking the queue into a
//! turn, delivering messages between tool calls (native engine) or
//! stopping the turn for them (acpmux engine), and the turn's end.

use std::sync::Arc;
use std::sync::mpsc::channel;

use optchat_core::Kind;

use super::{
    Brain, Engine, Input, PROGRESS_TICK, Phase, Queued, SETTLE_BOUND, Source, answer_entry,
    reply_key_at,
};
use std::sync::atomic::Ordering;

use crate::acpmux::SessionSpec;
use crate::compactor::is_marker_limit_error;
use crate::prompt::{CacheTtl, input_blocks, input_layout, is_ttl_refused_error};
use crate::state::{Batch, ChildRef, ChildStatus, HostState, Item, PendingTurn};
use crate::turn::{self, Interrupt, TurnOutcome, TurnStart};
use optchat_host::{Appended, NewMessage};

/// The notice for the first stuck view line (its node fails with a request
/// error on every try); None when no line is stuck.
/// A line held only by an exhausted route (a capacity error) is a quiet
/// wait, logged by the host: no notice.
pub fn stuck_notice(status: &optchat_host::Status) -> Option<String> {
    let error = |node: &optchat_core::NodeId| {
        status
            .failures
            .iter()
            .find(|f| f.node == *node)
            .map(|f| f.error.as_str())
    };
    let node = status
        .stuck
        .iter()
        .find(|n| error(n).is_none_or(|e| optchat_host::capacity_wait(e).is_none()))?;
    let class = match error(node) {
        Some(e) if e.starts_with(optchat_host::SETUP_ERROR) => {
            format!("a {}", optchat_core::cut_at_bytes(e, 240))
        }
        e => e
            .and_then(optchat_host::error_class)
            .map_or_else(|| "a request error".to_owned(), |c| c.to_string()),
    };
    Some(format!(
        "The Chief's memory cannot summarize line {} ({class}). Replies go on without that summary; the line stays unsummarized (zoom opens it) until the compactor can build it.",
        node.name()
    ))
}

impl Brain {
    /// Starts a turn worker when idle with something queued.
    pub(super) fn maybe_start_turn(&mut self) {
        // An update asked for a handoff: no new turn starts here; the next
        // host takes the queue.
        if self.handoff_if_idle() {
            return;
        }
        if self.phase != Phase::Idle || !self.queue.iter().any(Queued::wakes) || !self.ready() {
            return;
        }
        // An adopted turn session still runs (an update relaunch): it ends
        // first, then its resume runs.
        if self.orphan_wait.is_some() {
            return;
        }
        // A turn an upstream error cut waits out its backoff first; a new
        // message from a person starts it at once.
        if self
            .resume_at
            .is_some_and(|at| at > std::time::Instant::now())
            && !self
                .queue
                .iter()
                .any(|q| matches!(q.source, Source::Message { .. }))
        {
            return;
        }
        // The turn that starts now takes the cut turn's resume note: its
        // hold (a backoff, or a network cut's wait) is over.
        self.resume_at = None;
        self.phase = Phase::Settling;
        // The bound counts from the first wait for this turn: a wait that
        // starts over (the log changed under it) does not reset it.
        let waiting_since = *self
            .settle_clock
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
                // Section 6, as the chief changed it (2026-10-10: a user turn
                // never waits more than SETTLE_BOUND on compaction): the turn waits
                // until every view line is a summary, at most SETTLE_BOUND.
                // Then it starts anyway and reads the lines still building
                // unsummarized (`PLACEHOLDER`, which `zoom` opens); the next
                // turn reads their summaries. A node that cannot be built at
                // all (a setup error, or one that fails every try) is stuck
                // and holds no turn. Every PROGRESS_TICK of waiting,
                // `settle.json` says how far the compactor is (the app's
                // "Organizing Chief history"); a wait shorter than one tick
                // shows nothing.
                let mut deferred = false;
                let settled = loop {
                    let left = SETTLE_BOUND.saturating_sub(waiting_since.elapsed());
                    if chat.settle(None, Some(left.min(PROGRESS_TICK))) {
                        break true;
                    }
                    let status = chat.status();
                    if status.closed || status.fatal.is_some() {
                        break false;
                    }
                    if waiting_since.elapsed() >= SETTLE_BOUND {
                        let failing: Vec<String> = status
                            .failures
                            .iter()
                            .map(|f| format!("{}: {}", f.node.name(), f.error))
                            .collect();
                        log(&format!(
                            "turn starts without {} view line summaries after {}s (still building; failing: {})",
                            status.unbuilt,
                            SETTLE_BOUND.as_secs(),
                            if failing.is_empty() { "none".to_owned() } else { failing.join("; ") }
                        ));
                        deferred = true;
                        break true;
                    }
                    if let Some(settle) = &settle_status {
                        settle.waiting(&status);
                    }
                };
                if let Some(settle) = &settle_status {
                    settle.clear();
                }
                if settled {
                    // A stuck node (a request error on every try) no longer
                    // holds the turn: one notice says so, retracted once
                    // every stuck node is built.
                    let status = chat.status();
                    if let Some(text) = stuck_notice(&status) {
                        let _ = tx.send(Input::CompactorStatus(Err(text)));
                    } else if status.recovered {
                        let _ = tx.send(Input::CompactorStatus(Ok(())));
                    }
                }
                if !settled {
                    let _ = tx.send(Input::SettleFailed);
                    return;
                }
                let (reply, start) = channel();
                if tx.send(Input::Settled { reply, deferred }).is_err() {
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
                        // The reply as it streams, to every client.
                        let draft = |d: crate::draft::Draft| {
                            let _ = tx.send(Input::Draft(Box::new(d)));
                        };
                        // The turn's run record, to the same clients.
                        let run_update = |u: crate::run::RunUpdate| {
                            let _ = tx.send(Input::Run(Box::new(u)));
                        };
                        let outcome =
                            turn::run_with_drafts(&*agents, &chat, &start, &interrupt, &*log, &progress, &trace, &draft, &run_update);
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
                        let outcome = match (&outcome.error, ours) {
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
                                    crate::session_dir::set_session_cache(&session_dir, retry, true)
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
                                turn::run_with_drafts(&*agents, &chat, &again, &interrupt, &*log, &progress, &trace, &draft, &run_update)
                            }
                            (Some(e), _) if marked && is_marker_limit_error(e) => {
                                marker_refused.refused();
                                // The inspector lays this turn out unmarked.
                                trace.emit("turn.unmarked", serde_json::json!({"turn": start.key}));
                                log(&format!(
                                    "turn {}: Claude Code refused the cache_control marker ({e}); running the turn again without it, and the next {} turns go without it",
                                    start.key,
                                    crate::prompt::MARK_RETRY_AFTER
                                ));
                                // Unmarked: Claude Code's own marks again.
                                if let Err(e) = crate::session_dir::set_session_cache(
                                    &session_dir,
                                    ours.unwrap_or(CacheTtl::OneHour),
                                    false,
                                ) {
                                    log(&format!("updating the session's cache settings: {e}"));
                                }
                                let mut again = start.clone();
                                for block in &mut again.blocks {
                                    if let Some(b) = block.as_object_mut() {
                                        b.remove("cache_control");
                                    }
                                }
                                again.prompt_id = format!("{}:unmarked", start.prompt_id);
                                turn::run_with_drafts(&*agents, &chat, &again, &interrupt, &*log, &progress, &trace, &draft, &run_update)
                            }
                            _ => outcome,
                        };
                        crate::turn::run_after_capacity_waits(outcome, &start, &interrupt, &*log, &trace, |again| {
                            turn::run_with_drafts(&*agents, &chat, again, &interrupt, &*log, &progress, &trace, &draft, &run_update)
                        })
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
    /// unsummarized again; then the queue stays and the wait starts over.
    /// A user turn never waits more than SETTLE_BOUND (1 s) on
    /// compaction (README, Deviations from the spec, Section 6).
    /// `deferred`: the worker waited SETTLE_BOUND and starts the turn with
    /// lines still building (they read as the placeholder).
    pub(super) fn settled(&mut self, deferred: bool) -> Option<TurnStart> {
        if !self.ready() {
            // The next `Up` starts the turn, with a new bound: the wait for
            // acpmux was not a wait on compaction.
            self.phase = Phase::Idle;
            self.settle_clock = None;
            return None;
        }
        // The same check as settle's: an imported line still being built
        // (or a stuck one) does not hold the turn.
        if !deferred && !self.chat.turn_ready() {
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
        // The messages, their bookkeeping (floors, children) and the pending
        // turn commit together: a crash leaves all of it or none of it, so a
        // restart never logs a message twice and never loses one.
        let first_id = self.chat.status().messages;
        let session = format!("{}-{first_id}", self.settings.turn_prefix);
        let conversation = side.clone().or_else(|| self.state.conversation.clone());
        let opening: Vec<Item> = items.iter().map(item).collect();
        // The engine of this turn, read now (engine.rs): a change applies
        // from this turn on and is logged as a note after its messages.
        let engine = self.turn_engine_choice();
        let family = self.family_of(&engine.harness);
        // The cached layout on a Claude harness whose acpmux takes a preset
        // system prompt; else the view and the messages as blocks.
        let (cached, plain_preset) = self.session_presets(family);
        let marker = self.marker_refused.take();
        let ttl = self.turn_cache_ttl();
        // Our marks (spec 5a.2): the `<chat>` header, the frozen view's end and
        // the delta's end (the request's end before the per-turn tail). A marked
        // turn runs Claude Code without its own marks (the API takes 4), so each
        // tool step's tail after our input goes uncached. Claude Code
        // reads the setting at process start, so a turn cannot switch after
        // its first step; tool-heavy work belongs in subagents, which keep
        // Claude Code's marks (decision 2026-10-08).
        // A kept session (Settings::keep_turn_session) runs on Claude Code's
        // own marks: ours would pile up in its history past the API's four.
        let keep = self.settings.keep_turn_session && cached.is_some();
        let mark = cached
            .as_ref()
            .filter(|_| marker && !keep)
            .map(|_| ttl)
            // A session the pool started for an unmarked turn runs Claude
            // Code with its own marks: ours on top would make 5.
            .filter(|_| self.prewarm_ours != Some(false));
        let mut answers = self.state.carry_answers.clone();
        add_answers(&mut answers, self.answers_of(&items));
        let done = self.log_items(&items, move |next, done| {
            next.carry_answers.clear();
            let first = done.ids.first().copied().unwrap_or(first_id);
            let stamp = done.stamps.first().map(String::as_str).unwrap_or("");
            next.turn = Some(PendingTurn {
                key: reply_key_at(first, stamp),
                conversation,
                session,
                first_id: Some(first_id),
                items: opening,
                answers,
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
        self.tool_stopped = false;
        self.denial_stopped = None;
        // A user message or a report replaces the `until: event` wakes.
        self.drop_event_wakes(
            items
                .iter()
                .any(|i| matches!(i.source, Source::Message { .. } | Source::Spawn(_))),
        );
        let items_sources: Vec<&'static str> =
            items.iter().map(|i| source_name(&i.source)).collect();
        let home = self
            .settings
            .home_view
            .as_ref()
            .and_then(crate::home_view::HomeView::read);
        // The Chief never asks (Lawrence, 2026-10-20). The owner's turns, from
        // this Mac, a paired device or Home, run with the configured policy;
        // a turn that carries another person's text runs with policy `ask`
        // and every local effect it asks for is refused at once
        // (`turn_permission`), with no question to anyone.
        self.turn_ask = items.iter().any(Queued::requires_approval);
        self.last_turn_ask = self.turn_ask;
        self.turn_denied.clear();
        self.repeat_denials = 0;
        self.interrupt.set_gate(self.turn_ask);
        let policy = if self.turn_ask {
            crate::approval::ASK.to_owned()
        } else {
            self.settings.policy.clone()
        };
        let images: Vec<super::images::TurnImage> = items
            .iter()
            .flat_map(|i| i.images.iter().cloned())
            .collect();
        let image_blocks: Vec<serde_json::Value> = images
            .iter()
            .filter_map(super::images::TurnImage::block)
            .collect();
        self.describe_images(&images);
        // A resume note carries the cut messages' full text (never logged
        // again): it goes in the per-turn tail; every new message is in the
        // delta as it was logged (spec 5a.3).
        let resumes: Vec<String> = items
            .iter()
            .filter_map(|i| match &i.source {
                Source::Resume { cut, .. } => Some(super::recover::resume_prompt(cut)),
                _ => None,
            })
            .collect();
        // The turn's first new entry: an item a failed steer logged already
        // is new too, so it stays in the delta, never in a new view (5a.3).
        let main = self.state.conversation.clone().unwrap_or_default();
        let first_new = items
            .iter()
            .filter(|q| q.logged)
            .filter_map(|q| match q.source {
                Source::Message { seq, .. } => self.chat.logged_id(&format!(
                    "{}#{seq}",
                    q.conversation.as_deref().unwrap_or(&main)
                )),
                _ => None,
            })
            .fold(first_id, u64::min);
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        // Per-turn state goes after the delta, never in the system prompt and
        // never before a cache mark: the subagents at work now (the reference
        // client's line). Never logged.
        let at_work = self.at_work_line();
        // The person's Home workspace as it is now: after the view, never logged.
        let tail: Vec<String> = at_work
            .iter()
            .chain(home.iter())
            .chain(resumes.iter())
            .cloned()
            .collect();
        // Spec 5a: the frozen view and the delta after it (this turn's new
        // messages last), or a new view: optchat-core `turn_input` decides;
        // the host only keeps the record. The engine note goes after, so the
        // input ends with the turn's own messages (the next turn's delta
        // takes the note with this turn's work, in one block).
        let frozen = self
            .state
            .frozen
            .as_ref()
            .and_then(crate::state::FrozenRecord::frozen);
        let (input, delta_end) = self.chat.turn_input(frozen.as_ref(), first_new);
        self.state.frozen = Some(crate::state::FrozenRecord::of(&input.frozen));
        self.save();
        self.note_engine(&engine);
        let view = optchat_host::RenderedView {
            marks: optchat_core::cache_marks(&input.view),
            parts: input.frozen.parts.clone(),
            text: input.view.clone(),
        };
        let view = &view;
        // The previous request's end (the last cut before this one), when
        // this turn kept the frozen view: it gets a mark (see input_layout).
        let prev_end = (!input.rerendered)
            .then(|| {
                input
                    .frozen
                    .cuts
                    .iter()
                    .rev()
                    .find(|c| **c < delta_end)
                    .copied()
            })
            .flatten()
            .and_then(|end| crate::prompt::block_ending_at(&input.delta, end));
        let cached = cached.as_deref();
        let (blocks, system_prompt, preset) = match cached {
            Some(preset) => {
                // Claude Code's own marks take the same TTL: the API refuses
                // a 1h mark after a 5m one. A session the pool started
                // before a cache.ttl change still has the old one.
                self.ttl_stale
                    .store(self.prewarm_ttl.is_some_and(|p| p != ttl), Ordering::SeqCst);
                if let Err(e) = crate::session_dir::set_session_cache(
                    &self.settings.session_dir,
                    ttl,
                    mark.is_some(),
                ) {
                    (self.log)(&format!("updating the session's promptCacheTtl: {e}"));
                }
                let layout = input_layout(
                    &self.settings.system_text,
                    &view.text,
                    &input.delta,
                    prev_end,
                    &image_blocks,
                    &tail.join("\n\n"),
                    mark,
                );
                (layout.blocks, Some(layout.system), Some(preset.to_owned()))
            }
            None => (
                input_blocks(&view.text, &input.delta, &image_blocks, &tail.join("\n\n")),
                None,
                plain_preset,
            ),
        };
        // The kept session, when this turn has the same session shape and
        // keeps the frozen view: only what it has not read goes to it. The
        // policy is part of the shape: an approve-all session never serves a
        // turn another person started, and an `ask` one never an owner turn.
        let sig = keep.then(|| {
            keep_sig(
                &engine,
                &preset,
                system_prompt.as_deref(),
                &view.text,
                ttl,
                &policy,
            )
        });
        let kept = self.kept.take();
        let stale = self
            .state
            .kept_session
            .take()
            .filter(|s| kept.as_ref().is_none_or(|k| &k.kept.session != s));
        let reuse = match (&kept, sig) {
            (Some(k), Some(sig))
                if k.sig == sig
                    && !input.rerendered
                    && first_new >= k.seen_end
                    && k.tokens < KEEP_MAX_TOKENS =>
            {
                crate::prompt::delta_from(&input.delta, k.seen_end).map(|text| {
                    let mut blocks = vec![serde_json::json!({"type": "text", "text": text})];
                    blocks.extend(image_blocks.iter().cloned());
                    let tail = tail.join("\n\n");
                    if !tail.is_empty() {
                        blocks.push(serde_json::json!({"type": "text", "text": tail}));
                    }
                    turn::Reuse::new(k.kept.clone(), blocks)
                })
            }
            _ => None,
        };
        let retire = match (&kept, &reuse) {
            (Some(k), None) => Some(k.kept.session.clone()),
            _ => None,
        }
        .or(stale);
        self.keep_pending = sig.map(|sig| (key.clone(), sig));
        let image_count = image_blocks.len();
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
                "ttl": ttl.as_str(),
            })
        } else {
            serde_json::json!({"kind": "blocks"})
        };
        // The delta by its log range and cuts: the inspector renders it again.
        layout["delta"] = serde_json::json!({
            "front": input.frozen.front,
            "new_from": first_new,
            "end": delta_end,
            "unbuilt": input.frozen.unbuilt.iter().map(|p| p.name()).collect::<Vec<_>>(),
            // The cuts this delta was built with (this request's own end is past it).
            "cuts": input.frozen.cuts.iter().filter(|c| **c < delta_end).collect::<Vec<_>>(),
            // The forced block starts this delta was built with.
            "starts": input.frozen.starts.iter().filter(|s| **s <= first_new).collect::<Vec<_>>(),
            "bytes": input.delta.iter().map(String::len).sum::<usize>(),
            "rendered": input.rerendered,
            "prev_end_block": prev_end,
        });
        if !resumes.is_empty() {
            layout["resumes"] = serde_json::json!(resumes);
        }
        layout["images"] = serde_json::json!(image_count);
        if let Some(line) = &at_work {
            layout["at_work"] = serde_json::json!(line);
        }
        if let Some(block) = &home {
            layout["home_workspace"] = serde_json::json!(block);
        }
        if keep {
            layout["kept"] = serde_json::json!({
                "reuse": reuse.as_ref().map(|r| r.kept.session.clone()),
                "retire": retire,
                "from": kept.as_ref().map(|k| k.seen_end),
            });
        }
        self.trace_start(
            &key,
            first,
            view,
            &input.delta,
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
                tags: crate::acpmux::turn_tags(&self.settings.chief_id, &self.settings.parent),
                // Only the Chief's own turn gets the seal its `chiefs`
                // tool needs (chief_profile.rs TURN_KEY_ENV).
                env: [(
                    crate::chief_profile::TURN_KEY_ENV.to_owned(),
                    crate::chief_profile::process_turn_seal().to_owned(),
                )]
                .into(),
                fast: self.turn_fast(&engine, family),
                peer: None,
            },
            blocks,
            system_prompt,
            key,
            limit: self.settings.turn_limit,
            idle_limit: self.settings.turn_idle_limit,
            reuse,
            keep,
            retire,
        })
    }

    /// Logs `items` as `user` entries and, in the same transaction, the
    /// state their bookkeeping leaves (each child's report marked, the read
    /// cursor past every handled message, then `update`). On a failed write
    /// nothing is posted for them and the host stops (the conversation's
    /// cursor stays before them).
    pub(super) fn log_items(
        &mut self,
        items: &[Queued],
        update: impl FnOnce(&mut HostState, &Appended),
    ) -> Option<Appended> {
        // Items logged already (a failed steer on a harness that answers at
        // the turn's end) are not logged again.
        let fresh: Vec<Queued> = items.iter().filter(|q| !q.logged).cloned().collect();
        let items = &fresh[..];
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
                if let Source::Resume { .. } = &item.source {
                    next.resumes.retain(|r| r.conversation != item.conversation);
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
        // Messages never set the interrupt now; only chief.stop does, and a
        // boundary must not clear it.
        if !self.owner_stopped && !self.tool_stopped && self.denial_stopped.is_none() {
            self.interrupt.clear();
        }
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
        if !self.log_delivered(&items) {
            return Vec::new();
        }
        let images: Vec<super::images::TurnImage> = items
            .iter()
            .flat_map(|i| i.images.iter().cloned())
            .collect();
        let mut blocks: Vec<serde_json::Value> = images
            .iter()
            .filter_map(super::images::TurnImage::block)
            .collect();
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        blocks.push(serde_json::json!({"type": "text", "text": texts.join("\n\n")}));
        blocks
    }

    /// Logs messages delivered into the running turn as `user`, in its
    /// batches, past the read cursor, with their images described like a
    /// turn's own. False: the write failed (the host stops).
    pub(super) fn log_delivered(&mut self, items: &[Queued]) -> bool {
        self.taint_approval(items);
        let at = self.chat.status().messages;
        let batch: Vec<Item> = items.iter().map(item).collect();
        let answers = self.answers_of(items);
        let logged = self.log_items(items, move |next, _| {
            if let Some(turn) = next.turn.as_mut() {
                add_answers(&mut turn.answers, answers);
                turn.mid.push(Batch {
                    at,
                    items: batch,
                    done: true,
                });
            }
        });
        if logged.is_none() {
            return false;
        }
        self.set_cursor(self.state.logged_seq);
        let images: Vec<super::images::TurnImage> = items
            .iter()
            .flat_map(|i| i.images.iter().cloned())
            .collect();
        self.describe_images(&images);
        true
    }

    /// A human message arrived during a turn. acpmux: it is steered in at
    /// once; a steer refused or unread past the deadline stops the turn
    /// (`steer.rs`, user 2026-10-21). Native: the engine delivers it after
    /// the next tool results.
    pub(super) fn interrupt_for_newer(&mut self) {
        if self.phase != Phase::Running {
            return;
        }
        if matches!(self.settings.engine, Engine::Acpmux) {
            self.try_steer();
        }
    }

    /// An acpmux turn's session id and fold position, saved so a host that
    /// stops mid-turn folds the rest at the next start.
    pub(super) fn progress(&mut self, key: &str, session_id: String, after: u64) {
        let Some(turn) = self.state.turn.as_mut().filter(|t| t.key == key) else {
            return;
        };
        let first = turn.session_id.is_none();
        if turn.session_id.as_deref() != Some(session_id.as_str()) || turn.after != after {
            turn.session_id = Some(session_id);
            turn.after = after;
            self.save();
        }
        // Messages that came before the turn's session existed go in now.
        if first && self.phase == Phase::Running && matches!(self.settings.engine, Engine::Acpmux) {
            self.try_steer();
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
        delta: &[String],
        texts: &[String],
        ids: &[u64],
        sources: &[&'static str],
        system: Option<&str>,
        layout: serde_json::Value,
    ) {
        let view = rendered.text.as_str();
        self.turn_clock = Some(std::time::Instant::now());
        // A spawn in this turn gives its subagents this view and the delta
        // after it (the turn's new messages included): its lines are
        // one-message view lines already (`id+1|...`).
        let mut turn_view = view.strip_suffix("</chat>").unwrap_or(view).to_owned();
        for line in delta
            .iter()
            .flat_map(|b| b.lines())
            .filter(|l| !l.is_empty())
        {
            turn_view.push_str(line);
            turn_view.push('\n');
        }
        turn_view.push_str("</chat>");
        self.turn_view = Some(turn_view);
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
        let ttl = if self.ttl_refused.load(Ordering::SeqCst) {
            CacheTtl::FiveMinutes
        } else {
            self.settings
                .cache_ttl
                .or(self.chief.cache_ttl)
                .unwrap_or(CacheTtl::OneHour)
        };
        // The compactor's nodes follow it.
        self.settings.shared_ttl.set(ttl);
        ttl
    }

    /// This turn's engine: engine.json over the defaults. A harness acpmux
    /// does not know keeps the default harness, and says so.
    /// Whether this turn runs at the fast tier: `speed` fast on a harness
    /// that has it; on another one the turn runs at the default speed and
    /// the log says why.
    fn turn_fast(&self, engine: &crate::engine::TurnEngine, family: crate::acpmux::Family) -> bool {
        let Some(speed) = engine.speed.as_deref() else {
            return false;
        };
        match crate::engine::check_speed(speed, family) {
            Ok(()) => crate::engine::is_fast(Some(speed)),
            Err(reason) => {
                (self.log)(&format!("{reason}; this turn runs at the default speed"));
                false
            }
        }
    }

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
            effort: engine.effort.clone(),
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
        // Who ended a cancelled turn: the Chief itself (`stop`, `sleep`, after
        // it replied by send), the owner, or neither (a lost session).
        let by_chief = self.tool_stopped || self.denial_stopped.is_some();
        let status = if superseded {
            "superseded"
        } else if outcome.refused && outcome.reply.is_none() {
            "refused"
        } else if outcome.cancelled && by_chief {
            "stopped"
        } else if outcome.cancelled && self.owner_stopped {
            "owner_stopped"
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
                // A turn the Chief or the owner stopped ended as asked: no error.
                "error": outcome
                    .error
                    .as_deref()
                    .filter(|_| !matches!(status, "stopped" | "owner_stopped"))
                    .map(|e| self.trace.text(e)),
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

    pub(super) fn turn_ended(&mut self, key: &str, mut outcome: TurnOutcome) {
        if let Some(cut) = self.is_cut(key, &outcome) {
            self.turn_cut(key, outcome, cut);
            return;
        }
        self.cuts = 0;
        self.steer_due.take_if(|(_, turn)| turn == key);
        let outcome_done = outcome.done_draft.take();
        self.keep_turn_session(key, &mut outcome);
        if self.state.turn.as_ref().is_some_and(|t| t.key == key) {
            self.turn_view = None;
        }
        let conversation = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .and_then(|t| t.conversation.clone());
        let done_conversation = conversation.clone();
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
        // The Chief ended the turn itself (`stop`, `sleep`): everything it
        // meant to say went by send, reply or react, so its last text is not
        // posted and the cancel is no failure; unlike an owner stop, the
        // turn still closes its messages.
        // A turn stopped for asking again for what it was denied ends like
        // a Chief stop, but says so in one line.
        let denial_stopped = self.denial_stopped.take();
        let tool_stopped = std::mem::take(&mut self.tool_stopped) || denial_stopped.is_some();
        // A turn the owner stopped posts nothing, even one that ended
        // normally before it saw the interrupt (the stop was accepted).
        let quiet = superseded || owner_stopped;
        // A failed turn also leaves a note in the memory log, after the
        // messages it did not answer: without it the next turn's delta shows
        // them as still open, and a later "hi" got the answer to a message
        // that failed ten days before (2026-10-18). The note tells the next
        // turn to answer only what comes after it. None for a session that
        // lives on as an orphan (its answer is folded in later) or while a
        // message a failed steer logged already waits in the queue (it is
        // before the note but still open).
        let steered_waits = self.queue.iter().any(|q| q.logged);
        let failure_note = match &outcome.error {
            Some(error)
                if !(quiet || tool_stopped || outcome.orphan.is_some() || steered_waits) =>
            {
                Some(failure_note(error))
            }
            _ => None,
        };
        if owner_stopped {
            (self.log)(&format!("turn {key} stopped by the owner: nothing posted"));
        }
        if tool_stopped {
            (self.log)(&format!(
                "turn {key} ended by the Chief's stop: nothing more posted"
            ));
        }
        let text = ended_turn_text(
            outcome.reply,
            outcome.error,
            quiet || tool_stopped,
            outcome.refused,
            &failed,
        );
        // NO_REPLY posts nothing: a Chief that reads every message stays
        // quiet with it (membership), and any Chief ends with it when a
        // reaction or its `reply` calls said it all (brain/replies.rs).
        let said_no_reply = crate::membership::is_no_reply(&text);
        let text = if said_no_reply {
            // Never for a person's message of the Chief conversation: it
            // stays in the reply ledger, and a retry turn answers it
            // (reply_ledger.rs, user 2026-10-21).
            let main = conversation.is_some() && conversation == self.state.conversation;
            let person = main
                && self.state.turn.as_ref().is_some_and(|t| {
                    t.key == key
                        && t.answers
                            .iter()
                            .any(|id| self.state.awaiting.iter().any(|a| &a.id == id))
                });
            if person {
                (self.log)(&format!(
                    "turn {key} answered {} with a person's message in the batch: refused; a retry turn answers it",
                    crate::membership::NO_REPLY
                ));
            } else {
                (self.log)(&format!(
                    "turn {key} answered {}: nothing posted",
                    crate::membership::NO_REPLY
                ));
            }
            String::new()
        } else {
            text
        };
        let text = match &denial_stopped {
            Some((what, why)) if !quiet => {
                (self.log)(&format!("turn {key} stopped: it asked again for {what}"));
                format!("I stopped: I kept trying to {what}, and {}.", why.reason())
            }
            _ => text,
        };
        if let Some(note) = &failure_note
            && let Err(e) = self.chat.append(Kind::Note, note)
        {
            (self.log)(&format!("logging turn {key}'s failure failed: {e}"));
        }
        if superseded {
            (self.log)(&format!("turn {key} stopped for a newer message"));
        }
        self.turn_ask = false;
        self.turn_denied.clear();
        self.repeat_denials = 0;
        self.interrupt.set_gate(false);
        if let Some(orphan) = outcome.orphan {
            self.state.orphans.push(orphan);
        }
        // E22: what this reply answers, and which of those messages still
        // have subagents at work (more replies to them follow).
        let answers = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .map(|t| t.answers.clone())
            .unwrap_or_default();
        if superseded {
            add_answers(&mut self.state.carry_answers, answers.clone());
        } else if !answers.is_empty() {
            self.state.last_answers = answers.clone();
        }
        let pending: Vec<String> = answers
            .iter()
            .filter(|id| self.state.spawns.values().any(|s| s.working_for(id)))
            .cloned()
            .collect();
        // Work announced as pending that this turn closes: a silent turn
        // still answers with a done marker, unless the owner stopped it.
        let closes = !quiet
            && answers
                .iter()
                .any(|id| self.state.open_answers.contains(id) && !pending.contains(id));
        // An owner-stopped turn posts no done marker, so the work it would
        // close stays open for a later turn to close.
        if !quiet {
            self.state
                .open_answers
                .retain(|id| !answers.contains(id) || pending.contains(id));
            if conversation.is_some() && (!text.is_empty() || closes) {
                add_answers(&mut self.state.open_answers, pending.clone());
            }
        }
        let session = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .map(|t| t.session.clone())
            .unwrap_or_default();
        // In a group conversation the reply goes into the thread of the last
        // message it answers (membership::thread_target); a superseded turn's
        // messages keep theirs for the turn that answers them.
        let thread = if superseded {
            None
        } else {
            // In the Chief conversation too: the thread of the user message
            // it answers, by `replies.thread` (brain/replies.rs).
            let thread = conversation
                .as_deref()
                .and_then(|c| self.reply_thread(c, &answers));
            for id in &answers {
                self.reply_threads.remove(id);
            }
            thread
        };
        // The owner stopped the turn: its messages need no reply (the person
        // asked for the silence; reply_ledger.rs).
        let not_needed = if owner_stopped {
            answers.clone()
        } else {
            Vec::new()
        };
        match conversation {
            Some(conversation) if !text.is_empty() => {
                // Every mention of a subagent is its link (Lawrence 2026-10-10).
                let text = self.link_subagents(&text);
                let mut entry = answer_entry(conversation, key, &text, answers, pending);
                in_thread(&mut entry, thread);
                let entry = self.reply_with_previews(entry);
                self.state.outbox.push(entry);
            }
            Some(conversation) if closes => {
                (self.log)(&format!(
                    "turn {key} said nothing; it closes its messages with a done marker"
                ));
                // The marker stays out of the thread of the message it
                // closes: the daemon counts every message of a thread as a
                // reply, so a threaded marker gave the person's message a
                // reply that opens to nothing, and Home quoted that message
                // above it (cmux#23810). Its `answers` close the work alone.
                let mut entry = answer_entry(conversation, key, "", answers, pending);
                if let cmux_conversation::Op::MessageSend { parts, .. } = &mut entry.op {
                    *parts = vec![cmux_conversation::Part::Work {
                        session,
                        host: None,
                        status: cmux_conversation::WorkStatus::Done,
                        preview: None,
                    }];
                }
                self.state.outbox.push(entry);
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
        // Any other end leaves what no post answered to a retry check.
        self.reply_not_needed(&not_needed);
        self.state.turn = None;
        self.stop_wanted = false;
        self.save_with(extra);
        self.flush_outbox();
        self.schedule_reply_checks(if said_no_reply {
            super::reply_ledger::WHY_NO_REPLY
        } else {
            super::reply_ledger::WHY_SILENT
        });
        // After the reply: a client drops the draft as the message lands.
        if let (Some(done), Some(conversation)) = (outcome_done, &done_conversation) {
            self.publish_draft(conversation, &done);
        }
        if main {
            self.set_typing(false);
        }
        self.phase = Phase::Idle;
        if let Some(hook) = &self.after_turn {
            hook(key);
        }
        self.maybe_start_turn();
        self.prewarm_next_turn();
    }
}

/// Turns that may be cut in a row before the next one fails: an update
/// relaunch cuts one, a gateway redeploy (40 s to 2 min, a181 2026-10-19)
/// a few; a link or upstream that stays down must not loop.
pub(super) const MAX_CUTS: u32 = 3;

/// The waits before a turn cut by an upstream error runs again: about
/// 3 min in all, longer than a gateway redeploy.
pub(super) const UPSTREAM_RESUME_BACKOFF: [std::time::Duration; 3] = [
    std::time::Duration::from_secs(15),
    std::time::Duration::from_secs(45),
    std::time::Duration::from_secs(120),
];

/// Why a turn was cut rather than failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Cut {
    /// Its acpmux link went away: lost while it ran, or still gone at its
    /// `session/new` after the tries (`turn::new_session_with_retry`). It
    /// runs again once acpmux is back.
    Link,
    /// The model's endpoint answered a passing error (the sr2 gateway's
    /// 502 or a refused connection while it redeploys). It runs again after
    /// an `UPSTREAM_RESUME_BACKOFF` wait. Also any other error a retry may
    /// clear (`auto_resume::classify_error`: 429, 500, overloaded).
    Upstream,
    /// The request did not reach the model (DNS, a dropped connection, the
    /// Mac offline). It runs again once the model endpoint answers
    /// (`auto_resume::wait_online`), and no sooner than an upstream wait.
    Network,
}

/// Errors from the model's endpoint that a later try can cure.
const UPSTREAM_TRANSIENT: [&str; 8] = [
    "API Error: 502",
    "API Error: 503",
    "API Error: 504",
    "API Error: 529",
    "upstream request failed",
    "Connection refused",
    "ECONNREFUSED",
    "ECONNRESET",
];

/// Whether, and why, a failed turn was cut.
pub(super) fn cut_kind(outcome: &TurnOutcome) -> Option<Cut> {
    let error = outcome.error.as_deref()?;
    if outcome.orphan.is_some() {
        return (error == crate::turn::CONNECTION_LOST).then_some(Cut::Link);
    }
    if outcome.refused || outcome.cancelled {
        return None;
    }
    if outcome.reply.is_none()
        && [
            "acpmux is not connected",
            "connection closed",
            "acpmux is shutting down",
        ]
        .iter()
        .any(|t| error.contains(t))
    {
        return Some(Cut::Link);
    }
    if UPSTREAM_TRANSIENT.iter().any(|t| error.contains(t)) {
        return Some(Cut::Upstream);
    }
    // The same classes a subagent's run auto-resumes on (issue 25577); a
    // usage limit is not cured by a retry and stays the turn's failure.
    match crate::auto_resume::classify_error(error) {
        crate::auto_resume::StopKind::Transient(_) => Some(Cut::Upstream),
        crate::auto_resume::StopKind::Network(_) => Some(Cut::Network),
        _ => None,
    }
}

impl Brain {
    /// Why turn `key` was cut and runs again instead of failing (`cut_kind`):
    /// never one the owner or a newer message stopped, at most `MAX_CUTS` in
    /// a row.
    fn is_cut(&self, key: &str, outcome: &TurnOutcome) -> Option<Cut> {
        if self.stop_wanted
            || self.owner_stopped
            || self.tool_stopped
            || self.denial_stopped.is_some()
            || self.cuts >= MAX_CUTS
            || self.state.turn.as_ref().is_none_or(|t| t.key != key)
        {
            return None;
        }
        cut_kind(outcome)
    }

    /// Sets the waits before a turn an upstream error cut runs again (tests
    /// shorten them).
    pub fn set_upstream_resume_backoff(&mut self, waits: Vec<std::time::Duration>) {
        self.upstream_backoff = waits;
    }

    /// How often a network cut checks the model endpoint (tests shorten it).
    pub fn set_network_poll(&mut self, poll: std::time::Duration) {
        self.network_poll = poll;
    }

    /// The model endpoint answers again after the network cut whose hold
    /// is `hold` (or the wait for it ended, `!online`): the cut turn runs at
    /// `not_before` at the earliest. A turn that started meanwhile (a
    /// person's message) took the resume already and a newer cut has its own
    /// hold, so a stale answer is ignored.
    pub(super) fn network_back(
        &mut self,
        hold: std::time::Instant,
        not_before: std::time::Instant,
        online: bool,
    ) {
        if self.resume_at != Some(hold) || self.phase != Phase::Idle {
            return;
        }
        if online {
            (self.log)("the model endpoint answers again; the cut turn runs again");
        } else {
            (self.log)(&format!(
                "the model endpoint did not answer for {} min; the cut turn runs again anyway",
                crate::auto_resume::NETWORK_WAIT_MAX.as_secs() / 60
            ));
        }
        self.resume_at = Some(not_before.max(std::time::Instant::now()));
        self.on_resume_timer();
    }

    /// The upstream resume wait is over: the cut turn may start.
    pub(super) fn on_resume_timer(&mut self) {
        if self
            .resume_at
            .is_some_and(|at| at <= std::time::Instant::now())
        {
            self.resume_at = None;
            self.maybe_start_turn();
        }
    }

    fn turn_cut(&mut self, key: &str, outcome: TurnOutcome, cut: Cut) {
        self.cuts += 1;
        let error = outcome.error.clone().unwrap_or_default();
        let wait = self
            .upstream_backoff
            .get(self.cuts as usize - 1)
            .or(self.upstream_backoff.last())
            .copied()
            .unwrap_or_default();
        let when = match cut {
            Cut::Link => "once acpmux is back".to_owned(),
            Cut::Upstream => {
                self.resume_at = Some(std::time::Instant::now() + wait);
                format!("in {} s", wait.as_secs())
            }
            Cut::Network => {
                // Held until the probe answers; the timer only bounds the
                // hold, so a probe thread that never answers cannot keep the
                // task from running again.
                let now = std::time::Instant::now();
                let hold = now + crate::auto_resume::NETWORK_WAIT_MAX + wait;
                self.resume_at = Some(hold);
                let (tx, reach, poll) = (self.tx.clone(), self.reach.clone(), self.network_poll);
                let probe = std::thread::Builder::new()
                    .name("chief-network-wait".into())
                    .spawn(move || {
                        let online = crate::auto_resume::wait_online(
                            &*reach,
                            poll,
                            crate::auto_resume::NETWORK_WAIT_MAX,
                            std::thread::sleep,
                        );
                        let _ = tx.send(super::Input::NetworkBack {
                            hold,
                            not_before: now + wait,
                            online,
                        });
                    });
                match probe {
                    Ok(_) => format!(
                        "once the model endpoint answers (at least {} s)",
                        wait.as_secs()
                    ),
                    // No thread to wait on: an upstream backoff instead.
                    Err(e) => {
                        self.resume_at = Some(now + wait);
                        format!("in {} s (no endpoint probe: {e})", wait.as_secs())
                    }
                }
            }
        };
        (self.log)(&format!(
            "turn {key} was cut ({error}); it runs again on the resume note {when} ({} of {MAX_CUTS})",
            self.cuts
        ));
        let (cut_id, cut_name) = match self.state.turn.as_ref() {
            Some(t) => (t.session_id.clone(), Some(t.session.clone())),
            None => (None, None),
        };
        self.trace_end(key, &outcome, false);
        self.turn_view = None;
        let main = self.turn_side().is_none();
        let had: Vec<Option<String>> = self
            .state
            .resumes
            .iter()
            .map(|r| r.conversation.clone())
            .collect();
        // recover() closes the pending turn as a host restart does; only a
        // session still running (the lost turn's) becomes an orphan here.
        let orphans = self.state.orphans.clone();
        let _ = super::recover::recover(&self.chat, &mut self.state, true);
        self.state.orphans = orphans;
        let mut extra = Vec::new();
        match outcome.orphan {
            Some(lost) => {
                match self
                    .state
                    .orphans
                    .iter_mut()
                    .find(|o| o.session == lost.session)
                {
                    Some(o) => o.after = o.after.max(lost.after),
                    None => self.state.orphans.push(lost),
                }
            }
            None => {
                // No session runs on: a half-started one is ended at the
                // next connect, and the turn's fold position goes.
                self.stale_sessions.extend(cut_name);
                if let Some(id) = cut_id {
                    extra.push((crate::state::fold_key(&id), None));
                }
            }
        }
        if cut == Cut::Link {
            // The link thread sends the turn's Lost before its Down: no
            // turn starts until the next daemon is up.
            self.agents_up = false;
        }
        // The resume runs before any newer message, as after a restart.
        let fresh: Vec<crate::state::Resume> = self
            .state
            .resumes
            .iter()
            .filter(|r| !had.contains(&r.conversation))
            .cloned()
            .collect();
        for resume in fresh.into_iter().rev() {
            self.queue.push_front(Queued {
                text: super::recover::RESUMED.to_owned(),
                source: Source::Resume {
                    remote: resume.remote,
                    requires_approval: resume.requires_approval,
                    cut: resume.messages,
                },
                images: Vec::new(),
                conversation: resume.conversation,
                logged: false,
            });
        }
        self.turn_ask = false;
        self.turn_denied.clear();
        self.repeat_denials = 0;
        self.denial_stopped = None;
        self.interrupt.set_gate(false);
        self.stop_wanted = false;
        self.save_with(extra);
        self.schedule_reply_checks(&format!(
            "the turn was cut ({})",
            optchat_core::cut_at_bytes(&error, 120)
        ));
        if main {
            self.set_typing(false);
        }
        self.phase = Phase::Idle;
        if let Some(hook) = &self.after_turn {
            hook(key);
        }
        self.maybe_start_turn();
    }
}

/// The memory note a failed turn leaves after the messages it did not answer.
pub fn failure_note(error: &str) -> String {
    let error: String = error
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .take(200)
        .collect();
    format!(
        "the turn failed ({error}); the user saw the failure, and the requests before this note did not finish and are closed: answer only messages after this note, and take up an older request only if the user asks again"
    )
}

/// Puts a reply into the thread `(root, parent)`, when it has one.
fn in_thread(entry: &mut crate::state::OutboxEntry, thread: Option<(String, String)>) {
    if let (
        Some((root, parent)),
        cmux_conversation::Op::MessageSend {
            thread_root,
            reply_to,
            ..
        },
    ) = (thread, &mut entry.op)
    {
        *thread_root = Some(root);
        *reply_to = Some(cmux_conversation::PartRef {
            message_id: parent,
            part_index: 0,
        });
    }
}

/// A queued item's source in the trace.
fn source_name(source: &Source) -> &'static str {
    match source {
        Source::Message { .. } => "human",
        Source::Child { .. } => "child",
        Source::Spawn(_) => "subagents",
        Source::Note => "note",
        Source::Resume { .. } => "resume",
    }
}

/// The turn's images go just before its last block (the new messages, which
/// name them), so the view blocks and their cache marker stay as they were.
/// A queued item's source as the pending turn saves it.
fn item(queued: &Queued) -> Item {
    let images = queued.images.iter().map(|i| i.source.clone()).collect();
    match &queued.source {
        Source::Message {
            seq,
            id,
            remote,
            requires_approval,
        } => Item {
            seq: Some(*seq),
            images,
            conversation: queued.conversation.clone(),
            id: queued.conversation.as_ref().map(|_| id.clone()),
            remote: remote.is_some(),
            requires_approval: *requires_approval,
            ..Item::default()
        },
        Source::Resume {
            remote,
            requires_approval,
            cut,
        } => Item {
            conversation: queued.conversation.clone(),
            remote: *remote,
            requires_approval: *requires_approval,
            resume: true,
            cut: cut.clone(),
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
            requires_approval: r.requires_approval,
            images,
            ..Item::default()
        },
        Source::Note => Item {
            images,
            ..Item::default()
        },
    }
}

/// Adds `more` to `answers`, each id once, in order.
pub(super) fn add_answers(answers: &mut Vec<String>, more: Vec<String>) {
    for id in more {
        if !answers.contains(&id) {
            answers.push(id);
        }
    }
}

impl Brain {
    /// E22: the message ids that `items` answer: a human message's own id,
    /// and for a subagent's report the messages of the turn that spawned it.
    pub(super) fn answers_of(&self, items: &[Queued]) -> Vec<String> {
        let mut answers = Vec::new();
        for queued in items {
            match &queued.source {
                Source::Message { id, .. } if !id.is_empty() => {
                    add_answers(&mut answers, vec![id.clone()]);
                }
                Source::Spawn(r) => {
                    if let Some(record) = self.state.spawns.get(&r.spawn) {
                        // A subagent told during a later turn answers that
                        // turn's messages; the others, the spawn's.
                        let mut spawn_wide = r.subs.is_empty();
                        for (sub, _) in &r.subs {
                            match record.subs.iter().find(|s| &s.id == sub) {
                                Some(s) if !s.answers.is_empty() => {
                                    add_answers(&mut answers, s.answers.clone())
                                }
                                _ => spawn_wide = true,
                            }
                        }
                        if spawn_wide {
                            add_answers(&mut answers, record.answers.clone());
                        }
                    }
                }
                _ => {}
            }
        }
        answers
    }
}

/// What an ended turn posts to the conversation (and so to every bridge,
/// iMessage included). A quiet turn posts nothing: one superseded by a
/// newer message (the next turn answers both) and one the owner stopped
/// with chief.stop. The owner pressed stop and already knows; a
/// "(turn stopped)" message only adds noise (Lawrence 2026-10-19).
fn ended_turn_text(
    reply: Option<String>,
    error: Option<String>,
    quiet: bool,
    refused: bool,
    failed: &str,
) -> String {
    match (reply, error) {
        _ if quiet => String::new(),
        (None, Some(error)) if refused => format!("(turn {error})"),
        (Some(reply), Some(error)) => format!("{reply}\n\n({failed}: {error})"),
        (Some(reply), None) => reply,
        (None, Some(error)) => format!("({failed}: {error})"),
        (None, None) => String::new(),
    }
}

#[cfg(test)]
mod ended_turn_text_tests {
    use super::ended_turn_text;

    #[test]
    fn owner_stopped_turn_posts_nothing() {
        for reply in [None, Some("Let me check.".to_owned())] {
            let text = ended_turn_text(reply, Some("cancelled".into()), true, false, "turn failed");
            assert_eq!(text, "");
            assert!(!text.contains("turn stopped"));
        }
    }

    #[test]
    fn failures_and_replies_still_post() {
        assert_eq!(
            ended_turn_text(Some("hi".into()), None, false, false, "turn failed"),
            "hi"
        );
        assert_eq!(
            ended_turn_text(None, Some("boom".into()), false, false, "turn failed"),
            "(turn failed: boom)"
        );
        assert_eq!(
            ended_turn_text(
                Some("a".into()),
                Some("boom".into()),
                false,
                false,
                "turn failed"
            ),
            "a\n\n(turn failed: boom)"
        );
        assert_eq!(
            ended_turn_text(None, Some("refused".into()), false, true, "x"),
            "(turn refused)"
        );
    }
}

/// A kept turn session (`Settings::keep_turn_session`) and what the next turn
/// needs to prompt it again.
#[derive(Clone, Debug)]
pub(super) struct KeptTurn {
    pub kept: turn::Kept,
    /// The session's shape (`keep_sig`): a turn of another shape starts fresh.
    pub sig: u64,
    /// The log length when the kept turn ended: the session has read
    /// everything before it.
    pub seen_end: u64,
    /// The kept turn's first request's prompt tokens (its context size).
    pub tokens: u64,
}

/// A kept session's context past this many tokens is not prompted again:
/// a fresh session reads the view, which compaction keeps small.
const KEEP_MAX_TOKENS: u64 = 120_000;

/// A first request this large that read and wrote no cache ran with Claude
/// Code's caching off (a pooled process started for our marks): not kept.
const UNCACHED_LIMIT: u64 = 10_000;

/// The shape of a turn session: a kept one serves only a turn of the same
/// harness, model, effort, preset, system prompt, frozen view and TTL.
fn keep_sig(
    engine: &crate::engine::TurnEngine,
    preset: &Option<String>,
    system: Option<&str>,
    view: &str,
    ttl: CacheTtl,
    policy: &str,
) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (
        &engine.harness,
        &engine.model,
        &engine.effort,
        preset,
        system,
        view,
        ttl.as_str(),
        policy,
    )
        .hash(&mut h);
    h.finish()
}

impl Brain {
    /// Records the session a turn kept for the next turn, or ends it when
    /// it should not serve one (its first request ran uncached, or its
    /// context is too large).
    fn keep_turn_session(&mut self, key: &str, outcome: &mut TurnOutcome) {
        let pending = self.keep_pending.take().filter(|(k, _)| k == key);
        let Some(kept) = outcome.kept.take() else {
            return;
        };
        let first = outcome.stats.first.unwrap_or_default();
        let tokens = first.input + first.cache_read + first.cache_write;
        let uncached =
            first.cache_read == 0 && first.cache_write == 0 && first.input > UNCACHED_LIMIT;
        match pending {
            Some((_, sig)) if !uncached && tokens < KEEP_MAX_TOKENS => {
                self.state.kept_session = Some(kept.session.clone());
                self.kept = Some(KeptTurn {
                    kept,
                    sig,
                    seen_end: self.chat.status().messages,
                    tokens,
                });
            }
            _ => {
                if uncached {
                    (self.log)(&format!(
                        "turn {key}: its session ran without prompt caching; not kept"
                    ));
                }
                if let Err(e) = self.agents.end_session(&kept.session) {
                    (self.log)(&format!("ending turn session {}: {e}", kept.session));
                }
            }
        }
    }
}
