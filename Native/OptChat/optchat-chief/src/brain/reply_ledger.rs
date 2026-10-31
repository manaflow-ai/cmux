//! The reply ledger: every person message of the Chief conversation gets a
//! reply (user 2026-10-21: "make every user message in the Chief DM get a
//! reply, guaranteed").
//!
//! A message joins `HostState::awaiting` when it is queued for a turn and
//! leaves only when the owner takes a post that answers it: a reply that
//! names it (`answers`, or `reply_to` it), or any other text the Chief posts
//! once its turn has seen the message. The ledger is saved with the host
//! state, so a crash, a host restart or a lost turn keeps it.
//!
//! A turn that ends without such a post (it said `NO_REPLY`, it stopped with
//! nothing sent, it failed before posting, or the owner refused the post)
//! leaves its messages here with a due check. When the check is due and no
//! turn runs, a retry turn starts on a `[no reply]` note that names them and
//! forbids `NO_REPLY`; the waits grow (`REPLY_RETRY_WAITS`). After
//! `MAX_REPLY_TRIES` retries the host posts a short failure note in the
//! message's thread, so the person is never left with silence. Only the
//! owner's own stop (chief.stop) closes a message with no post: the person
//! asked for the silence.

use std::time::{Duration, Instant};

use cmux_conversation::{Message, Op, Part};
use optchat_core::Kind;

use super::{Brain, Phase, Source, now_ms};
use crate::state::Awaiting;

/// The waits before each retry check: after the turn that left a message
/// unanswered ends, and between retries.
pub const REPLY_RETRY_WAITS: [Duration; 3] = [
    Duration::from_secs(5),
    Duration::from_secs(30),
    Duration::from_secs(120),
];

/// Retry turns per message before the failure note posts.
pub const MAX_REPLY_TRIES: u32 = 3;

/// The first word of a retry turn's note.
pub const NO_REPLY_TAG: &str = "[no reply]";

/// Characters of a message kept for the notes.
const PREVIEW_CHARS: usize = 120;

/// Why a turn that ended left its messages unanswered, as the notes say it.
pub(super) const WHY_NO_REPLY: &str = "the turn ended with NO_REPLY";
pub(super) const WHY_SILENT: &str = "the turn ended without a reply";

impl Brain {
    /// Person message `message` of the Chief conversation is queued for a
    /// turn: it waits for a reply from now on.
    pub(super) fn await_reply(&mut self, message: &Message, text: &str) {
        if message.id.is_empty() || self.state.awaiting.iter().any(|a| a.id == message.id) {
            return;
        }
        self.state.awaiting.push(Awaiting {
            id: message.id.clone(),
            seq: message.seq,
            since_ms: now_ms(),
            preview: preview(text),
            ..Awaiting::default()
        });
        self.save();
    }

    /// Whether message `id` still waits in the queue, unseen by any turn.
    fn reply_queued(&self, id: &str) -> bool {
        self.queue.iter().any(|q| {
            q.conversation.is_none()
                && !q.logged
                && matches!(&q.source, Source::Message { id: m, .. } if m == id)
        })
    }

    /// The owner took `op` under `key` in `conversation`: the messages it
    /// answers leave the ledger. A post with text (or an attachment) answers
    /// the messages it names (`answers`, `reply_to`); a Chief's own post (a
    /// `send`, a turn's reply, a retry turn's reply) answers every message a
    /// turn has seen. The host's own notices and the desk's voice answer
    /// nothing.
    pub(super) fn reply_posted(&mut self, conversation: &str, key: &str, op: &Op) {
        if self.state.awaiting.is_empty()
            || self.state.conversation.as_deref() != Some(conversation)
        {
            return;
        }
        let Op::MessageSend {
            parts,
            answers,
            reply_to,
            ..
        } = op
        else {
            return;
        };
        // A browser card (and its text) shows work; it answers nothing.
        if !says_something(parts) || super::browser_card::is_card_key(key) {
            return;
        }
        let chief_post = key.starts_with("send-") || key.starts_with("turn:optchat:");
        let mut named: Vec<String> = answers.clone();
        if let Some(parent) = reply_to {
            named.push(parent.message_id.clone());
        }
        let before = self.state.awaiting.len();
        let awaiting = std::mem::take(&mut self.state.awaiting);
        self.state.awaiting = awaiting
            .into_iter()
            .filter(|a| {
                // Kept unless the post names it, or it is the Chief's own
                // post and a turn has seen the message.
                !(named.contains(&a.id) || (chief_post && !self.reply_queued(&a.id)))
            })
            .collect();
        if self.state.awaiting.len() != before {
            self.save();
        }
    }

    /// The person messages the running turn has seen that nothing answers
    /// yet: in the ledger, out of the queue, and no post of this Chief that
    /// would answer them waits in the outbox. `stop` and `sleep` refuse to
    /// end the turn over them (brain/wakes.rs): one reply now is cheaper
    /// than the `[no reply]` retry turn it would cost.
    pub(super) fn unanswered_in_turn(&self) -> Vec<&Awaiting> {
        let pending_post = self.state.outbox.iter().any(|e| {
            matches!(&e.op, Op::MessageSend { parts, .. } if says_something(parts))
                && (e.idempotency_key.starts_with("send-")
                    || e.idempotency_key.starts_with("reply-"))
        });
        if pending_post {
            return Vec::new();
        }
        self.state
            .awaiting
            .iter()
            .filter(|a| !self.reply_queued(&a.id))
            .collect()
    }

    /// Messages the person retracted, or whose turn the owner stopped
    /// (chief.stop: the person asked for the silence), need no reply.
    pub(super) fn reply_not_needed(&mut self, ids: &[String]) {
        let before = self.state.awaiting.len();
        self.state.awaiting.retain(|a| !ids.contains(&a.id));
        if self.state.awaiting.len() != before {
            self.save();
        }
    }

    /// A turn ended (or was cut): every message it saw that is still
    /// unanswered gets a check after the wait of its tries. `why` is how the
    /// turn ended without answering.
    pub(super) fn schedule_reply_checks(&mut self, why: &str) {
        if self.state.awaiting.is_empty() {
            return;
        }
        let now = now_ms();
        let waits = self.reply_waits.clone();
        let queued: Vec<bool> = self
            .state
            .awaiting
            .iter()
            .map(|a| self.reply_queued(&a.id))
            .collect();
        for (a, queued) in self.state.awaiting.iter_mut().zip(queued) {
            if queued {
                continue;
            }
            a.due_ms = Some(now + wait_of(&waits, a.tries).as_millis() as u64);
            a.why = Some(why.to_owned());
        }
        self.save();
    }

    /// A host that starts again: a message whose check was not set yet (its
    /// turn was cut by the stop) gets the longest wait, so the resume turn
    /// answers it first.
    pub(super) fn rearm_reply_checks(&mut self) {
        let now = now_ms();
        let long = self.reply_waits.last().copied().unwrap_or_default();
        for a in self
            .state
            .awaiting
            .iter_mut()
            .filter(|a| a.due_ms.is_none())
        {
            a.due_ms = Some(now + long.as_millis() as u64);
        }
    }

    /// The messages still waiting for a reply, oldest first.
    pub fn awaiting_replies(&self) -> Vec<Awaiting> {
        self.state.awaiting.clone()
    }

    /// Posts a host notice, as a compactor fault or a stuck line does (tests).
    #[doc(hidden)]
    pub fn notice_for_test(&mut self, key: &str, text: &str) {
        self.notice(key.to_owned(), text.to_owned());
    }

    /// Sets the waits between retry checks (tests shorten them).
    pub fn set_reply_retry_waits(&mut self, waits: Vec<Duration>) {
        self.reply_waits = waits;
    }

    /// When the next retry check is due, on the brain's clock.
    pub(super) fn next_reply_due(&self) -> Option<Instant> {
        let at = self.state.awaiting.iter().filter_map(|a| a.due_ms).min()?;
        Some(Instant::now() + Duration::from_millis(at.saturating_sub(now_ms())))
    }

    /// Runs every retry check due at `now` (ms since the epoch): a running
    /// turn moves it later; else a retry turn starts for the due messages,
    /// or the failure note posts for those out of tries.
    pub fn fire_reply_checks_at(&mut self, now: u64) {
        if !self
            .state
            .awaiting
            .iter()
            .any(|a| a.due_ms.is_some_and(|d| d <= now))
        {
            return;
        }
        let first = self.reply_waits.first().copied().unwrap_or_default();
        // A turn runs (it sees them), a cut turn waits out its backoff (it
        // runs again on them), or a reply waits in the outbox for the owner
        // (it may answer them): later. Items queued while idle are turns that
        // cannot start (acpmux is down): the tries count, so the failure
        // note still comes.
        let main = self.state.conversation.clone();
        let reply_waits = self.state.outbox.iter().any(|e| {
            Some(&e.conversation) == main.as_ref() && matches!(e.op, Op::MessageSend { .. })
        });
        let busy = self.phase != Phase::Idle || self.resume_at.is_some() || reply_waits;
        if busy {
            for a in self.state.awaiting.iter_mut() {
                if a.due_ms.is_some_and(|d| d <= now) {
                    a.due_ms = Some(now + first.as_millis() as u64);
                }
            }
            self.save();
            return;
        }
        let waits = self.reply_waits.clone();
        let mut retry: Vec<Awaiting> = Vec::new();
        let mut failed: Vec<Awaiting> = Vec::new();
        for a in self.state.awaiting.iter_mut() {
            if a.due_ms.is_none_or(|d| d > now) {
                continue;
            }
            if a.tries >= MAX_REPLY_TRIES {
                failed.push(a.clone());
                continue;
            }
            a.tries += 1;
            // Due again if the retry turn cannot start or ends silent too.
            a.due_ms = Some(now + wait_of(&waits, a.tries).as_millis() as u64);
            retry.push(a.clone());
        }
        let failed_ids: Vec<String> = failed.iter().map(|a| a.id.clone()).collect();
        self.state.awaiting.retain(|a| !failed_ids.contains(&a.id));
        for a in &failed {
            self.post_reply_failure(a);
        }
        if !retry.is_empty() {
            let text = self.nudge_text(&retry);
            (self.log)(&format!(
                "{} message(s) got no reply ({}); starting a retry turn",
                retry.len(),
                retry
                    .iter()
                    .map(|a| a.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            // One retry note waits at a time; a newer one replaces it.
            self.queue.retain(|q| !is_nudge(q));
            self.save();
            self.queue(text, Source::Note);
        } else {
            self.save();
        }
        if !failed.is_empty() {
            self.flush_outbox();
        }
    }

    /// The retry turn's note: which messages wait, why, and that a reply in
    /// words is required.
    fn nudge_text(&self, due: &[Awaiting]) -> String {
        let main = self.state.conversation.clone().unwrap_or_default();
        let lines: Vec<String> = due
            .iter()
            .map(|a| {
                let line = self
                    .chat
                    .logged_id(&format!("{main}#{}", a.seq))
                    .map(|id| format!("line {id}"))
                    .unwrap_or_else(|| format!("message {}", a.id));
                format!(
                    "- {line} \"{}\" ({}; retry {} of {MAX_REPLY_TRIES})",
                    a.preview,
                    a.why.as_deref().unwrap_or(WHY_SILENT),
                    a.tries
                )
            })
            .collect();
        format!(
            "{NO_REPLY_TAG} These messages of the user got no reply:\n{}\nReply to each now, in words (send, reply, or your final text). NO_REPLY and a stop with nothing sent are not allowed for a person's message in this chat. If you cannot do what it asks, say so and why.",
            lines.join("\n")
        )
    }

    /// Posts the failure note for `a`, out of retries, in its thread.
    fn post_reply_failure(&mut self, a: &Awaiting) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let why = a.why.as_deref().unwrap_or(WHY_SILENT);
        let text = failure_text(&a.preview, why, a.tries);
        (self.log)(&format!(
            "message {} got no reply after {} retries ({why}); posting the failure note",
            a.id, a.tries
        ));
        let mut entry = super::answer_entry(
            conversation,
            &format!("no-reply-{}", a.id),
            &text,
            vec![a.id.clone()],
            Vec::new(),
        );
        if let Op::MessageSend { reply_to, .. } = &mut entry.op {
            *reply_to = Some(cmux_conversation::PartRef {
                message_id: a.id.clone(),
                part_index: 0,
            });
        }
        self.state.outbox.push(entry);
        let note = format!(
            "the host posted a failure note for message {}: no turn answered it after {} retries ({why}); answer it only if the user asks again",
            a.id, a.tries
        );
        if let Err(e) = self.chat.append(Kind::Note, &note) {
            (self.log)(&format!("logging the failure note failed: {e}"));
        }
    }
}

/// The text the person sees when no turn could answer a message.
pub fn failure_text(preview: &str, why: &str, tries: u32) -> String {
    format!(
        "I could not answer your message \"{preview}\". I tried {} times and {why}. Please send it again.",
        tries + 1
    )
}

/// Whether `q` is a retry turn's note.
fn is_nudge(q: &super::Queued) -> bool {
    matches!(q.source, Source::Note) && q.text.starts_with(NO_REPLY_TAG)
}

/// Whether a post shows the person something: text, or an attachment.
fn says_something(parts: &[Part]) -> bool {
    parts.iter().any(|p| match p {
        Part::Text { text, .. } => !text.trim().is_empty(),
        Part::Attachment { .. } => true,
        _ => false,
    })
}

fn wait_of(waits: &[Duration], tries: u32) -> Duration {
    waits
        .get(tries as usize)
        .or(waits.last())
        .copied()
        .unwrap_or_default()
}

fn preview(text: &str) -> String {
    let line = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or_default()
        .trim();
    let mut out: String = line.chars().take(PREVIEW_CHARS).collect();
    if line.chars().count() > PREVIEW_CHARS {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_grow_and_stay_at_the_last() {
        let w = REPLY_RETRY_WAITS.to_vec();
        assert_eq!(wait_of(&w, 0), Duration::from_secs(5));
        assert_eq!(wait_of(&w, 2), Duration::from_secs(120));
        assert_eq!(wait_of(&w, 9), Duration::from_secs(120));
    }

    #[test]
    fn a_done_marker_is_no_reply() {
        assert!(!says_something(&[Part::Text {
            text: "  ".into(),
            runs: None
        }]));
        assert!(says_something(&[Part::Text {
            text: "ok".into(),
            runs: None
        }]));
    }

    #[test]
    fn the_failure_note_names_the_message() {
        let t = failure_text("deploy it", WHY_NO_REPLY, 3);
        assert!(t.contains("\"deploy it\""), "{t}");
        assert!(t.contains("4 times"), "{t}");
    }
}
