//! G9: acking the chief's wake queue (`cloud-mux-ack`) and bounding the side
//! floors.
//!
//! A wake is acked once its conversation's saved floor covers it and nothing
//! for that conversation waits: no queued message, no pending turn, no
//! outbox entry. So a waking message is acked only after the owner took the
//! turn's reply (or refused it for good), and a message that does not wake
//! as soon as its floor is saved. The main conversation's floor is
//! `logged_seq`. An ack is cumulative (`mux.ack` clears every wake up to its
//! seq) and idempotent, so a crash between the floor and the ack only means
//! the queue delivers the wake again, and the saved floor drops it.

use super::{Brain, Source, now_ms};
use crate::daemon::OpError;
use crate::state::FLOOR_RETENTION_DAYS;

const DAY_MS: u64 = 86_400_000;

impl Brain {
    /// Remembers a wake to ack: the highest woken seq per conversation.
    pub(super) fn wake_pending(&mut self, conversation: &str, seq: u64) {
        let top = self.mux_pending.entry(conversation.to_owned()).or_insert(0);
        *top = (*top).max(seq);
    }

    /// Acks every woken conversation whose floor covers its wakes and for
    /// which nothing waits.
    pub(super) fn settle_acks(&mut self) {
        if self.daemon.is_none() || self.mux_pending.is_empty() {
            return;
        }
        let ready: Vec<(String, u64)> = self
            .mux_pending
            .iter()
            .filter_map(|(conversation, woken)| {
                let floor = self.saved_floor(conversation)?;
                (floor >= *woken && !self.waits(conversation))
                    .then(|| (conversation.clone(), floor))
            })
            .collect();
        for (conversation, floor) in ready {
            self.ack(&conversation, floor);
            if self.daemon.is_none() {
                return;
            }
        }
    }

    /// The saved floor of `conversation`: every message at or below it is
    /// in the log or needed none.
    fn saved_floor(&self, conversation: &str) -> Option<u64> {
        if self.state.conversation.as_deref() == Some(conversation) {
            Some(self.state.logged_seq)
        } else {
            self.state.side.get(conversation).map(|f| f.seq)
        }
    }

    /// Whether a message, a turn or a reply of `conversation` still waits.
    fn waits(&self, conversation: &str) -> bool {
        let side = self.side_of(Some(conversation));
        self.queue
            .iter()
            .any(|q| q.conversation == side && matches!(q.source, Source::Message { .. }))
            || self
                .state
                .turn
                .as_ref()
                .is_some_and(|t| t.conversation.as_deref() == Some(conversation))
            || self
                .state
                .outbox
                .iter()
                .any(|e| e.conversation == conversation)
    }

    /// `cloud-mux-ack {conversation, seq}` through the leased port.
    pub(super) fn ack(&mut self, conversation: &str, seq: u64) {
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        match daemon.mux_ack(conversation, seq) {
            Ok(()) => {}
            Err(OpError::Rejected(why)) => {
                // Not retried: the queue delivers the wake again after a
                // resubscribe, and the saved floor drops it then.
                (self.log)(&format!("ack {conversation}:{seq} refused: {why}"));
            }
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("ack {conversation}:{seq}: {e}"));
                self.drop_daemon();
                return;
            }
        }
        if self
            .mux_pending
            .get(conversation)
            .is_some_and(|top| *top <= seq)
        {
            self.mux_pending.remove(conversation);
        }
    }

    /// Requirement 3 (bounded state): drops the floor of every side
    /// conversation without a wake for `FLOOR_RETENTION_DAYS`, unless
    /// something of it still waits. A later wake starts a new floor at that
    /// wake, so nothing older is read again.
    pub(super) fn prune_floors(&mut self) {
        let cutoff = now_ms().saturating_sub(FLOOR_RETENTION_DAYS * DAY_MS);
        let stale: Vec<String> = self
            .state
            .side
            .iter()
            .filter(|(c, f)| {
                f.touched_ms < cutoff && !self.waits(c) && !self.mux_pending.contains_key(*c)
            })
            .map(|(c, _)| c.clone())
            .collect();
        if stale.is_empty() {
            return;
        }
        for conversation in &stale {
            self.state.side.remove(conversation);
            self.side_handled.remove(conversation);
        }
        (self.log)(&format!(
            "dropped the floors of {} side conversations without a wake for {FLOOR_RETENTION_DAYS} days",
            stale.len()
        ));
        self.save();
    }
}
