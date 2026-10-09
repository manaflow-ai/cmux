//! Messages during an acpmux turn reach the model between its tool calls
//! (parity item 7): the brain steers them into the running session
//! (`AgentPort::steer`, a steered `session/prompt` with `steerOnly`); Claude
//! Code reads them at its next tool boundary, and the turn's one reply
//! answers them too. They are logged as `user` once acpmux says the harness
//! read them. A session that cannot steer now gets the stop of decision
//! 2026-10-04 instead, and the messages wait for the next turn.

use super::{Brain, Input, Phase, Queued, Source};
use crate::acpmux::Family;

/// One steer on its way: the turn it went to and its messages.
pub(super) struct Steering {
    pub(super) id: u64,
    pub(super) key: String,
    pub(super) items: Vec<Queued>,
}

impl Brain {
    /// Steers what is queued for the running turn's conversation into its
    /// session. False: this turn cannot be steered now (not a Claude
    /// harness, its session not started yet, or an item of another
    /// conversation is ahead (G9: it is never passed)); the caller stops
    /// the turn instead, as before. One steer at a time, so the messages
    /// keep their order; the next goes when this one is read.
    pub(super) fn try_steer(&mut self) -> bool {
        let Some(turn) = self.state.turn.as_ref() else {
            return false;
        };
        let (key, session) = (turn.key.clone(), turn.session_id.clone());
        let claude = self
            .turn_engine
            .as_ref()
            .is_some_and(|e| self.family_of(&e.harness) == Family::Claude);
        let Some(session) = session.filter(|_| claude) else {
            return false;
        };
        if self.steering.is_some() {
            return true;
        }
        let side = self.turn_side();
        let take = self
            .queue
            .iter()
            .take_while(|q| q.conversation == side)
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
        self.steering = Some(Steering { id, key, items });
        let (agents, tx) = (self.agents.clone(), self.tx.clone());
        let interrupt = self.interrupt.clone();
        let spawned = std::thread::Builder::new()
            .name("steer".into())
            .spawn(move || {
                let result = agents.steer(&session, blocks, &prompt_id);
                let failed = result.is_err();
                // The outcome first: the brain then knows the stop is for
                // these messages before the stopped turn can end.
                let _ = tx.send(Input::Steered { id, result });
                if failed {
                    // The stop leaves at once, off the brain thread.
                    interrupt.request();
                }
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting a steer failed: {e}"));
            self.steered(id, Err(e.to_string()));
        }
        true
    }

    /// A steer's outcome. Read: its messages are logged as `user` (in the
    /// running turn's batches when it still runs). Not delivered: they go
    /// back to the head of the queue, and a turn that still runs is stopped
    /// so the next one answers them.
    pub(super) fn steered(&mut self, id: u64, result: Result<(), String>) {
        let Some(steer) = self.steering.take_if(|s| s.id == id) else {
            return;
        };
        let current = self.phase == Phase::Running
            && self.state.turn.as_ref().is_some_and(|t| t.key == steer.key);
        match result {
            Ok(()) => {
                if current {
                    self.log_delivered(&steer.items);
                } else {
                    // The turn read them and ended before this arrived.
                    self.log_items(&steer.items, |_, _| {});
                    self.set_cursor(self.state.logged_seq);
                }
                // Messages that came meanwhile go next.
                if current && self.queue.front().is_some_and(|q| q.wakes()) {
                    self.try_steer();
                }
            }
            Err(e) => {
                (self.log)(&format!(
                    "turn {}: the message could not reach the running turn ({e}); stopping the turn",
                    steer.key
                ));
                for item in steer.items.into_iter().rev() {
                    self.queue.push_front(item);
                }
                if current {
                    self.stop_wanted = true;
                    self.interrupt.request();
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
