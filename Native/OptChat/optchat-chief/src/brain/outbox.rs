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
            // A browser card is not a turn of talk: the owner's agent
            // budget ignores it, so it is not paced either.
            let (is_message, not_before, attempted, previews_until) = (
                matches!(entry.op, Op::MessageSend { .. })
                    && !super::browser_card::is_card_key(&entry.idempotency_key),
                entry.not_before,
                entry.attempted,
                entry.previews_until,
            );
            // A reply waiting for its link previews (brain/previews.rs)
            // holds the queue, in order, until they arrive or its hold ends.
            if !attempted
                && let Some(until) = previews_until
                && now_ms() < until
            {
                self.outbox_timer = Some(
                    Instant::now() + Duration::from_millis(until.saturating_sub(now_ms()) + 50),
                );
                return;
            }
            // Cards go after the parts the previews and uploads filled (cards.rs).
            let (conversation, key, op) = (
                entry.conversation.clone(),
                entry.idempotency_key.clone(),
                super::cards::with_cards(&entry.op, &entry.cards),
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
                Ok(change) => {
                    self.reply_posted(&conversation, &key, &op);
                    if is_message {
                        self.last_agent_send = Some(now_ms());
                    }
                    if let Some(cmux_conversation::Change::Message { message }) = change {
                        self.note_posted(&conversation, &key, &message);
                        self.sent(&key, &message.id);
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
                Err(OpError::Rejected(reason))
                    if (self.state.outbox[0].plain_text.is_some()
                        || !self.state.outbox[0].cards.is_empty())
                        && has_cards(&op)
                        && refuses_parts(&reason) =>
                {
                    // The owner refused the link cards (an older or stricter
                    // owner): the reply goes as its original text, unchanged,
                    // under a new key, since the refused key is spent; each
                    // other card as a line of it (cards.rs).
                    let head = &mut self.state.outbox[0];
                    let text = super::cards::text_fallback(
                        head.plain_text.take(),
                        &head.op,
                        &head.cards,
                    );
                    let mut fallback = super::reply_entry(
                        head.conversation.clone(),
                        &format!("{key}:text"),
                        &text,
                    );
                    // The text answers the same messages in the same thread.
                    if let (
                        Op::MessageSend {
                            reply_to,
                            answers,
                            answers_pending,
                            thread_root,
                            ..
                        },
                        Op::MessageSend {
                            reply_to: to,
                            answers: ans,
                            answers_pending: pending,
                            thread_root: root,
                            ..
                        },
                    ) = (&head.op, &mut fallback.op)
                    {
                        *to = reply_to.clone();
                        *ans = answers.clone();
                        *pending = answers_pending.clone();
                        *root = thread_root.clone();
                    }
                    *head = fallback;
                    // A refused browser card is not sent again (browser_card.rs).
                    if let Some(card) = self.state.browser_card.as_mut()
                        && card.key == key
                    {
                        card.refused = true;
                        self.browser_cards_refused = true;
                    }
                    self.save();
                    (self.log)(&format!(
                        "op {key}: the owner refused its link cards ({reason}); sending the text"
                    ));
                    continue;
                }
                Err(OpError::Rejected(reason))
                    if super::replies::unthreaded(&op, &reason).is_some() =>
                {
                    // The owner refused the reply's thread: the same reply
                    // goes at the top level under a new key (the refused key
                    // is spent), never dropped.
                    let top = super::replies::unthreaded(&op, &reason).expect("checked above");
                    let head = &mut self.state.outbox[0];
                    let new_key = format!("{key}:top");
                    head.idempotency_key = new_key.clone();
                    head.attempted = false;
                    head.op = match top {
                        Op::MessageSend {
                            parts,
                            answers,
                            answers_pending,
                            ..
                        } => Op::MessageSend {
                            client_msg_id: new_key,
                            parts,
                            reply_to: None,
                            answers,
                            answers_pending,
                            thread_root: None,
                        },
                        other => other,
                    };
                    self.save();
                    (self.log)(&format!(
                        "op {key}: the owner refused its thread ({reason}); posting it at the top level"
                    ));
                    continue;
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

/// Whether the owner refused a send for its parts (cards it cannot take),
/// not for its thread or its pace: only then does the text go instead.
fn refuses_parts(reason: &str) -> bool {
    ["invalid_parts", "unknown_attachment", "attachment_mismatch"]
        .iter()
        .any(|code| reason.contains(code))
}

/// Whether `op` sends link cards (a reply the preview thread filled).
/// Whether a send carries parts an owner may refuse where text would pass:
/// link cards, or an approval card (a `question` part).
fn has_cards(op: &Op) -> bool {
    use cmux_conversation::Part;
    let Op::MessageSend { parts, .. } = op else {
        return false;
    };
    parts
        .iter()
        .any(|p| matches!(p, Part::LinkPreview { .. } | Part::Question(_) | Part::Card(_)))
}
