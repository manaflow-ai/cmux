//! Messages during an acpmux turn reach the model between its tool calls
//! (parity item 7): the brain steers them into the running session
//! (`AgentPort::steer`, a steered `session/prompt` with `steerOnly`); Claude
//! Code reads them at its next tool boundary, and the turn's one reply
//! answers them too. Every queued message goes at once, in order. They are
//! logged as `user` where they arrived: once acpmux says Claude Code read
//! them, and at once on a harness that answers a steer only at the turn's
//! end (codex-acp). A message too big to go in whole (over the view's
//! budget, or over 20 images: the reference's Memory.whole) is not steered;
//! it waits for the next turn, which builds its node first. When the session cannot steer now (acpmux refuses, or the
//! harness does not steer), the messages wait at the head of the queue and
//! the next turn starts the moment this one ends. A message never stops a
//! turn (decision 2026-10-09); only chief.stop does.

use super::{Brain, Input, Phase, Queued, Source};
use crate::acpmux::Family;

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

impl Brain {
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
        let started = self.agents.start_steer(&session, blocks, &prompt_id);
        let logged = at_end && started.is_ok() && self.log_delivered(&items);
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
                    self.log_delivered(&steer.items);
                } else {
                    // The turn read them and ended before this arrived.
                    self.log_items(&steer.items, |_, _| {});
                    self.set_cursor(self.state.logged_seq);
                }
            }
            Err(e) => {
                // Never a stop: the messages go back to the head of the
                // queue, and the next turn starts the moment this one ends.
                (self.log)(&format!(
                    "turn {}: the message could not reach the running turn ({e}); it waits for the next turn",
                    steer.key
                ));
                for mut item in steer.items.into_iter().rev() {
                    item.logged = steer.logged;
                    self.queue.push_front(item);
                }
            }
        }
        self.maybe_start_turn();
    }

    /// Whether a delivered batch has a paired device's message: the turn's
    /// local effects then need an approval (README "Remote-origin messages").
    pub(super) fn taint_remote(&mut self, items: &[Queued]) {
        let remote = items.iter().any(|i| {
            matches!(
                i.source,
                Source::Message {
                    remote: Some(_),
                    ..
                }
            )
        });
        if remote {
            self.turn_remote = true;
            self.turn_ask = !self.chief.remote_auto_approve;
            self.interrupt.set_gate(self.turn_ask);
        }
    }
}
