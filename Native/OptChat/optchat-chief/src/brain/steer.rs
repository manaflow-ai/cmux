//! Messages during an acpmux turn reach the model between its tool calls
//! (parity item 7): the brain steers them into the running session
//! (`AgentPort::steer`, a steered `session/prompt` with `steerOnly`); Claude
//! Code reads them at its next tool boundary, and the turn's one reply
//! answers them too. Every queued message goes at once, in order. They are
//! logged as `user` where they arrived: once acpmux says Claude Code read
//! them, and at once on a harness that answers a steer only at the turn's
//! end (codex-acp). A message too big to go in whole (over the view's
//! budget, or over 20 images: the reference's Memory.whole) is not steered;
//! it waits for the next turn, which builds its node first.
//!
//! A person's message interrupts at once when it cannot go in now (user
//! 2026-10-21: "we need to immediately interrupt and steer"; replaces the
//! 2026-10-09 "a message never stops a turn"). When acpmux refuses its
//! steer, or Claude Code has not read it within [`STEER_DEADLINE`] (a long
//! tool call or a long think: it reads steers only at tool boundaries), the
//! turn is stopped at once, even mid-tool (`session/cancel`), its end posts
//! nothing, and the next turn starts with the message and the view of
//! everything the stopped turn did. The host never posts a message of its
//! own about it ("no fake messages": the front desk receipt is gone). A
//! subagent's report never stops a turn: refused, it waits at the head of
//! the queue and the next turn starts the moment this one ends.

use std::time::{Duration, Instant};

use super::{Brain, Input, Phase, Queued, Source};
use crate::acpmux::Family;

/// How long a person's message steered into the running turn may stay
/// unread before the turn is interrupted (the host's default;
/// `OPTCHAT_STEER_DEADLINE_SECONDS`, 0 waits for the next tool boundary).
pub const STEER_DEADLINE: Duration = Duration::from_secs(3);

/// Most images one steer carries (the reference's PICS).
const STEER_IMAGES: usize = 20;

/// One steer on its way: the turn it went to and its messages.
pub(super) struct Steering {
    pub(super) id: u64,
    pub(super) key: String,
    pub(super) items: Vec<Queued>,
    /// Logged when sent (a harness that answers at the turn's end).
    pub(super) logged: bool,
}

/// Whether `items` hold a person's message (a report never interrupts).
fn has_person(items: &[Queued]) -> bool {
    items
        .iter()
        .any(|i| matches!(i.source, Source::Message { .. }))
}

impl Brain {
    /// How long a person's steered message may stay unread before the turn
    /// is interrupted; None or zero: it waits for the next tool boundary
    /// (the default; the host sets it).
    pub fn set_steer_deadline(&mut self, deadline: Option<Duration>) {
        self.steer_deadline = deadline.filter(|d| !d.is_zero());
    }

    /// Steers what is queued for the running turn's conversation into its
    /// session, now: the request is written on the brain thread, so steers
    /// keep their order, and its answer is awaited off it. False: this turn
    /// cannot take them now (its session not started yet, an item of
    /// another conversation is ahead (G9: it is never passed), or the head
    /// message is too big to go in whole); they wait for the next turn.
    pub(super) fn try_steer(&mut self) -> bool {
        let Some(turn) = self.state.turn.as_ref() else {
            return false;
        };
        let (key, session) = (turn.key.clone(), turn.session_id.clone());
        // Unread steers of this turn are being taken back; the turn is cut
        // when they are, and the next turn takes the queue.
        if self.withdrawing.as_deref() == Some(key.as_str()) {
            return false;
        }
        // Any harness: acpmux steers when the session's harness says it can
        // (Claude Code through its adapter, codex-acp), else refuses.
        let Some(session) = session else {
            return false;
        };
        let side = self.turn_side();
        let (mut bytes, mut images) = (0usize, 0usize);
        let take = self
            .queue
            .iter()
            .take_while(|q| q.conversation == side)
            .take_while(|q| {
                bytes += q.text.len();
                images += q.images.len();
                bytes <= optchat_core::VIEW && images <= STEER_IMAGES
            })
            .count();
        if take == 0 {
            return false;
        }
        let items: Vec<Queued> = self.queue.drain(..take).collect();
        // Never feed a non-owner's text into an approve-all session. It waits
        // for the current turn to end, then starts its own ask-policy turn.
        if !self.turn_ask && items.iter().any(Queued::requires_approval) {
            for item in items.into_iter().rev() {
                self.queue.push_front(item);
            }
            return false;
        }
        let mut blocks: Vec<serde_json::Value> = items
            .iter()
            .flat_map(|i| i.images.iter())
            .filter_map(super::images::TurnImage::block)
            .collect();
        let texts: Vec<&str> = items.iter().map(|i| i.text.as_str()).collect();
        blocks.push(serde_json::json!({"type": "text", "text": texts.join("\n\n")}));
        self.steer_seq += 1;
        let id = self.steer_seq;
        let prompt_id = format!("optchat-steer:{key}:{id}");
        // Only Claude Code says when it read a message; elsewhere the
        // answer comes at the turn's end, so the message is logged now.
        let at_end = self
            .turn_engine
            .as_ref()
            .is_none_or(|e| self.family_of(&e.harness) != Family::Claude);
        // Their people join the turn before their words reach it, so the
        // rights hook holds the turn's next call to them too.
        self.add_turn_people(&items);
        let started = self.agents.start_steer(&session, blocks, &prompt_id);
        let logged = at_end && started.is_ok() && self.log_delivered(&items);
        // Claude Code says when it read the message: one it has not read by
        // the deadline interrupts the turn (`on_steer_deadline`).
        if started.is_ok()
            && !logged
            && has_person(&items)
            && self.steer_due.is_none()
            && let Some(deadline) = self.steer_deadline
        {
            self.steer_due = Some((Instant::now() + deadline, key.clone()));
        }
        self.steering.push(Steering {
            id,
            key,
            items,
            logged,
        });
        let wait = match started {
            Ok(wait) => wait,
            Err(e) => {
                self.steered(id, Err(e));
                return true;
            }
        };
        let tx = self.tx.clone();
        let spawned = std::thread::Builder::new()
            .name("steer".into())
            .spawn(move || {
                let _ = tx.send(Input::Steered { id, result: wait() });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("waiting for a steer failed: {e}"));
        }
        true
    }

    /// A steer's outcome. Read: its messages are logged as `user` (in the
    /// running turn's batches when it still runs). Not delivered: they go
    /// back to the head of the queue, and a turn that still runs is stopped
    /// so the next one answers them.
    pub(super) fn steered(&mut self, id: u64, result: Result<(), String>) {
        let Some(at) = self.steering.iter().position(|s| s.id == id) else {
            return;
        };
        let steer = self.steering.remove(at);
        let current = self.phase == Phase::Running
            && self.state.turn.as_ref().is_some_and(|t| t.key == steer.key);
        match result {
            Ok(()) if steer.logged => {}
            Ok(()) => {
                if current {
                    // Read: a later message may move the next long call too.
                    self.backgrounded = None;
                    self.log_delivered(&steer.items);
                } else {
                    // The turn read them and ended before this arrived.
                    self.log_items(&steer.items, |_, _| {});
                    self.set_cursor(self.state.logged_seq);
                }
            }
            Err(e) => {
                // The messages go back to the head of the queue. A person's
                // stops the turn now, and the next turn takes it; a report
                // waits for this turn's end.
                let person = current && has_person(&steer.items);
                (self.log)(&format!(
                    "turn {}: the message could not reach the running turn ({e}); {}",
                    steer.key,
                    if person {
                        "interrupting the turn"
                    } else {
                        "it waits for the next turn"
                    }
                ));
                // A steer a stop ended after it was written may still wait
                // unread in the harness (acpmux's `stopped_unread`).
                if e.contains("stopped before the agent read it") {
                    self.steer_left = Some(steer.key.clone());
                }
                for mut item in steer.items.into_iter().rev() {
                    item.logged = steer.logged;
                    self.queue.push_front(item);
                }
                if person {
                    self.interrupt_for_person("steer refused");
                }
            }
        }
        self.maybe_start_turn();
    }

    /// The steer deadline passed: a person's message Claude Code has not
    /// read yet. First the turn's running work moves to the background, so
    /// the message is read at once (`steer_backgrounded`); when nothing
    /// moves, or the message is still unread at the next deadline, it
    /// interrupts the turn. Its unread steers go back to the head of the
    /// queue (an answer that comes later is dropped), so the next turn
    /// takes them; one read just before the stop is read again, which
    /// costs a line, never a lost message.
    pub(super) fn on_steer_deadline(&mut self, now: Instant) {
        if self.steer_due.as_ref().is_none_or(|(at, _)| *at > now) {
            return;
        }
        let Some((_, key)) = self.steer_due.take() else {
            return;
        };
        let current =
            self.phase == Phase::Running && self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if !current {
            return;
        }
        let (unread, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.steering)
            .into_iter()
            .partition(|s| s.key == key && !s.logged);
        self.steering = kept;
        if !unread.iter().any(|s| has_person(&s.items)) {
            self.steering.extend(unread);
            return;
        }
        // First, once a turn: Claude Code reads a steer only when its step
        // ends, and the step is usually a long tool call. Move that call to
        // the background (Ctrl-B) instead of cutting the turn: the call runs
        // on and its result still comes, and the message is read now, as
        // Claude desktop does with a message sent during a long command.
        // Before, the cut killed the call and the earlier ask was never
        // answered (responsiveness bench, steer probe, 3 of 3 rounds).
        let session = self.state.turn.as_ref().and_then(|t| t.session_id.clone());
        if self.backgrounded.as_deref() != Some(key.as_str())
            && let Some(session) = session.clone()
        {
            self.backgrounded = Some(key.clone());
            self.steering.extend(unread);
            let agents = self.agents.clone();
            let tx = self.tx.clone();
            let asked = key.clone();
            let spawned = std::thread::Builder::new()
                .name("steer-background".into())
                .spawn(move || {
                    let moved = agents.background_work(&session) == Ok(true);
                    let _ = tx.send(Input::SteerBackgrounded { key: asked, moved });
                });
            match spawned {
                Ok(_) => return,
                Err(e) => {
                    (self.log)(&format!(
                        "moving the turn's work to the background failed: {e}"
                    ));
                    let (unread2, kept2): (Vec<_>, Vec<_>) = std::mem::take(&mut self.steering)
                        .into_iter()
                        .partition(|s| s.key == key && !s.logged);
                    self.steering = kept2;
                    return self.withdraw_and_cut(&key, unread2);
                }
            }
        }
        self.withdraw_and_cut(&key, unread);
    }

    /// The deadline's background move answered: when work moved, Claude
    /// Code reads the message at its next step, so the deadline starts once
    /// more; else the unread steers are taken back and the turn is cut.
    pub(super) fn steer_backgrounded(&mut self, key: &str, moved: bool) {
        let current =
            self.phase == Phase::Running && self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if !current {
            return;
        }
        if !self.steering.iter().any(|s| s.key == key && !s.logged) {
            return;
        }
        if moved {
            self.moved = Some(key.to_owned());
            self.interrupt.set_moved_work();
            (self.log)(&format!(
                "turn {key}: moved its running work to the background so a new message is read now"
            ));
            if let Some(deadline) = self.steer_deadline {
                self.steer_due = Some((Instant::now() + deadline, key.to_owned()));
            }
            return;
        }
        self.steer_due = Some((Instant::now(), key.to_owned()));
        self.on_steer_deadline(Instant::now());
    }

    /// The unread steers of turn `key` go back to the queue, are taken back
    /// from the harness, and the turn is cut.
    fn withdraw_and_cut(&mut self, key: &str, unread: Vec<Steering>) {
        let key = key.to_owned();
        // Take them back from the harness first (Claude Code drops a line it
        // has not read), then cut the turn: a session that holds no unread
        // message is kept, and the next turn goes on in it with the messages
        // (turns.rs `keep_turn_session`). The cut waits for the answers, off
        // the brain thread; a harness that cannot take one back leaves it in
        // the session, which is then not kept.
        let prompts: Vec<String> = unread
            .iter()
            .map(|s| format!("optchat-steer:{}:{}", s.key, s.id))
            .collect();
        for steer in unread.into_iter().rev() {
            for item in steer.items.into_iter().rev() {
                self.queue.push_front(item);
            }
        }
        // Written to the harness and unread: the session may still hold them
        // until the withdraw says otherwise. No new steer goes in meanwhile
        // (`withdrawing`): it would take the requeued messages again.
        self.steer_left = Some(key.clone());
        self.withdrawing = Some(key.clone());
        let session = self.state.turn.as_ref().and_then(|t| t.session_id.clone());
        let (Some(session), true) = (session, !prompts.is_empty()) else {
            self.interrupt_for_person("steer unread past the deadline");
            return;
        };
        let agents = self.agents.clone();
        let tx = self.tx.clone();
        let asked_key = key.clone();
        let spawned = std::thread::Builder::new()
            .name("steer-withdraw".into())
            .spawn(move || {
                let all = prompts
                    .iter()
                    .all(|p| agents.withdraw_steer(&session, p) == Ok(true));
                let _ = tx.send(Input::SteersWithdrawn {
                    key: asked_key,
                    all,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("taking back unread steers failed: {e}"));
            self.interrupt_for_person("steer unread past the deadline");
        }
    }

    /// The unread steers of turn `key` were asked back: cut the turn now (it
    /// still runs), keeping its session when every one was dropped unread.
    pub(super) fn steers_withdrawn(&mut self, key: &str, all: bool) {
        let current =
            self.phase == Phase::Running && self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if self.withdrawing.as_deref() != Some(key) {
            return;
        }
        self.withdrawing = None;
        if all && self.steer_left.as_deref() == Some(key) {
            self.steer_left = None;
        }
        if current {
            self.interrupt_for_person("steer unread past the deadline");
        }
    }

    /// Stops the running turn for a person's message it cannot take now:
    /// at once, even mid-tool; its end posts nothing, and the next turn
    /// starts with the message.
    fn interrupt_for_person(&mut self, why: &str) {
        if self.phase != Phase::Running || self.stop_wanted {
            return;
        }
        let key = self.state.turn.as_ref().map(|t| t.key.clone());
        (self.log)(&format!(
            "turn {}: a new message cannot reach it ({why}); interrupting",
            key.as_deref().unwrap_or("?")
        ));
        if self.trace.is_on() {
            self.trace.emit(
                "turn.interrupt",
                serde_json::json!({"turn": key, "why": why}),
            );
        }
        self.stop_wanted = true;
        self.steer_due = None;
        // The next turn prompts this same session with the message (its work
        // so far stays in its context and its cache), as a person who stops
        // an agent and writes again does; never a new session that reads the
        // whole view uncached and starts the work over.
        self.interrupt.request_hard_resumable();
    }

    /// Another person's text delivered to a running turn keeps that turn's
    /// local effects refused until it ends.
    pub(super) fn taint_approval(&mut self, items: &[Queued]) {
        // Its people join the turn's (rights_gate.rs): the hook holds the
        // rest of the turn to every one of them.
        self.add_turn_people(items);
        self.forget_authors(items);
        if items.iter().any(Queued::requires_approval) {
            // Untrusted text, or other-person text in an owner's turn, ends
            // a trusted agent's tell and spawn for the rest of the turn.
            self.turn_relay = match (self.turn_ask, self.turn_relay.take()) {
                (true, Some(before)) => trusted_relays(items).map(|now| {
                    if before.split(", ").any(|n| n == now) {
                        before
                    } else {
                        format!("{before}, {now}")
                    }
                }),
                _ => None,
            };
            self.turn_ask = true;
            self.last_turn_ask = true;
            self.interrupt.set_gate(true);
        }
    }
}

/// The trusted agent sessions behind `items`' other-person text, joined
/// with `, `, when every item that takes the ask floor is a trusted agent's
/// message (`relay.trustedAgents`); None when any is not, or none is.
pub(super) fn trusted_relays(items: &[Queued]) -> Option<String> {
    let mut names: Vec<&str> = Vec::new();
    for item in items.iter().filter(|i| i.requires_approval()) {
        let name = item.trusted_relay()?;
        if !names.contains(&name) {
            names.push(name);
        }
    }
    (!names.is_empty()).then(|| names.join(", "))
}
