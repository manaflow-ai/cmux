//! The durable outbox (mux/host rules): ops in order, one at a time. Untried
//! messages to one conversation go as one send, the next agent message waits
//! out the owner's gap, and an `agent_rate` reject is retried under the same
//! key with a growing backoff and never dropped (G11, crate::pacing). Any other
//! reject (`agent_budget` included) is dropped so it never loops, and
//! `actor_mismatch` (the app replaced the token) keeps the entry and
//! reconnects, which binds again.

use std::time::{Duration, Instant};

use cmux_conversation::Op;

use super::{Brain, now_ms};
use crate::daemon::OpError;
use crate::pacing;

impl Brain {
    /// Sends what the outbox holds, then acks the wakes nothing waits for
    /// any more (G9: a woken message is acked after its reply is taken).
    pub(super) fn flush_outbox(&mut self) {
        self.flush_entries();
        self.settle_acks();
    }

    fn flush_entries(&mut self) {
        loop {
            if self.daemon.is_none() {
                return;
            }
            pacing::coalesce(&mut self.state.outbox);
            let Some(entry) = self.state.outbox.first() else {
                self.outbox_timer = None;
                return;
            };
            let (is_message, not_before, attempted) = (
                matches!(entry.op, Op::MessageSend { .. }),
                entry.not_before,
                entry.attempted,
            );
            let (conversation, key, op) = (
                entry.conversation.clone(),
                entry.idempotency_key.clone(),
                entry.op.clone(),
            );
            let gap_ms = self.settings.agent_gap.as_millis() as u64;
            let now = now_ms();
            let paced = if is_message {
                pacing::gap_wait(self.last_agent_send, gap_ms, now).map(|w| now + w)
            } else {
                None
            };
            if let Some(at) = not_before.into_iter().chain(paced).max()
                && now < at
            {
                // Its one-shot timer flushes it.
                self.outbox_timer = Some(Instant::now() + Duration::from_millis(at - now + 50));
                return;
            }
            if !attempted {
                self.state.outbox[0].attempted = true;
                self.save();
            }
            let Some(daemon) = self.daemon.as_mut() else {
                return;
            };
            match daemon.op(&conversation, &key, &op) {
                Ok(_) => {
                    if is_message {
                        self.last_agent_send = Some(now_ms());
                    }
                }
                Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                    (self.log)(&format!(
                        "op {key}: binding lost; reconnecting to bind again"
                    ));
                    self.drop_daemon();
                    return;
                }
                Err(OpError::Rejected(reason)) if reason.contains("agent_rate") => {
                    // Never dropped (G11): the same key again after a growing backoff.
                    let head = &mut self.state.outbox[0];
                    head.rate_retried = true;
                    head.rate_attempts += 1;
                    let wait = pacing::backoff(self.settings.agent_gap, head.rate_attempts);
                    head.not_before = Some(now_ms() + wait.as_millis() as u64);
                    let attempt = head.rate_attempts;
                    self.save();
                    (self.log)(&format!(
                        "op {key} inside the agent gap (try {attempt}); retrying after {} ms",
                        wait.as_millis()
                    ));
                    self.outbox_timer = Some(Instant::now() + wait + Duration::from_millis(50));
                    return;
                }
                Err(OpError::Rejected(reason)) if reason.contains("idempotency_conflict") => {
                    // A key reused with other text: a bug, not an owner rule.
                    // Dropped so it never loops, but loudly.
                    (self.log)(&format!(
                        "error: the owner refused op {key} as a reused key with different content ({reason}); the message was not posted"
                    ))
                }
                Err(OpError::Rejected(reason)) => {
                    (self.log)(&format!("dropping rejected op {key}: {reason}"))
                }
                Err(OpError::Transport(e)) => {
                    // Kept: retried on the next connect (the owner dedupes by key).
                    (self.log)(&format!("op {key}: {e}"));
                    self.drop_daemon();
                    return;
                }
            }
            self.state.outbox.remove(0);
            self.save();
        }
    }
}
