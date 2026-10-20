//! Replies and reactions (plans/cmux-next/chief-replies-reactions-DESIGN.md):
//! where a reply in the Chief's DM goes (the thread of the message it
//! answers, by `replies.thread`), and the Chief's two output tools, `react`
//! (a tapback on a user message) and `reply` (a message now, in the thread of
//! a user message). Both tools name the message by the id the Chief sees in
//! its view; the log keeps each user message's `<conversation>#<seq>`.

use cmux_conversation::{Message, Op, PartRef, ReactionKind, Tapback};

use super::Brain;
use crate::chief_settings::ReplyThreads;
use crate::state::OutboxEntry;

/// The reactions `react` takes: the six tapbacks, and `ack` (a like).
pub const REACTIONS: [&str; 7] = [
    "like",
    "love",
    "laugh",
    "emphasize",
    "question",
    "dislike",
    "ack",
];

/// The tapback a `react` reaction names.
pub fn tapback(reaction: &str) -> Result<Tapback, String> {
    Ok(match reaction.trim() {
        "like" | "ack" | "thumbs_up" | "👍" => Tapback::Like,
        "love" | "heart" | "❤️" => Tapback::Love,
        "laugh" | "haha" => Tapback::Laugh,
        "emphasize" | "!!" => Tapback::Emphasize,
        "question" | "?" => Tapback::Question,
        "dislike" | "thumbs_down" | "👎" => Tapback::Dislike,
        other => {
            return Err(format!(
                "react: no reaction {other:?}; one of {}",
                REACTIONS.join(", ")
            ));
        }
    })
}

fn tapback_name(t: Tapback) -> &'static str {
    match t {
        Tapback::Like => "like",
        Tapback::Love => "love",
        Tapback::Laugh => "laugh",
        Tapback::Emphasize => "emphasize",
        Tapback::Question => "question",
        Tapback::Dislike => "dislike",
    }
}

impl Brain {
    /// Records a message of the Chief conversation as it is handled: the
    /// newest seq, and for a user message its seq and, when it is itself a
    /// thread reply, its root (saved, so a later report still finds it).
    pub(super) fn note_main_message(&mut self, message: &Message) {
        self.newest_seq = self.newest_seq.max(message.seq);
        if message.author == self.settings.membership.participant {
            return;
        }
        self.message_seqs.insert(message.id.clone(), message.seq);
        if let Some(root) = &message.thread_root {
            self.state.note_root(&message.id, root);
        }
    }

    /// A message the Chief posted in its conversation (the owner's answer).
    pub(super) fn note_posted(&mut self, conversation: &str, message: &Message) {
        if self.state.conversation.as_deref() == Some(conversation) {
            self.newest_seq = self.newest_seq.max(message.seq);
        }
    }

    /// The thread `(root, parent)` a reply in `conversation` that answers
    /// `answers` goes into: a group message's thread (`reply_threads`), or in
    /// the Chief conversation the thread of its last answered user message,
    /// by `replies.thread`. None: the top level.
    pub(super) fn reply_thread(
        &self,
        conversation: &str,
        answers: &[String],
    ) -> Option<(String, String)> {
        if let Some(thread) = answers.last().and_then(|id| self.reply_threads.get(id)) {
            return Some(thread.clone());
        }
        if self.state.conversation.as_deref() != Some(conversation) {
            return None;
        }
        let last = answers.last()?;
        let thread = || Some((self.state.root_of(last), last.clone()));
        match self.chief.reply_threads {
            ReplyThreads::Never => None,
            ReplyThreads::Always => thread(),
            ReplyThreads::Auto => {
                // Right under its message, as in iMessage: no thread.
                let waiting = self.state.outbox.iter().any(|e| {
                    e.conversation == conversation && matches!(e.op, Op::MessageSend { .. })
                });
                let adjacent = !waiting
                    && self
                        .message_seqs
                        .get(last)
                        .is_some_and(|seq| *seq >= self.newest_seq);
                if adjacent { None } else { thread() }
            }
        }
    }

    /// The conversation message the Chief's view line `view_id` logged.
    fn message_of_line(&mut self, tool: &str, view_id: u64) -> Result<Message, String> {
        let key = self.chat.logged_key(view_id).ok_or_else(|| {
            format!(
                "{tool}: line {view_id} is not a message in the conversation (a note, a report or a tool line); name a user message"
            )
        })?;
        let (conversation, seq) = key
            .rsplit_once('#')
            .and_then(|(c, s)| Some((c.to_owned(), s.parse::<u64>().ok()?)))
            .ok_or_else(|| format!("{tool}: line {view_id} has no conversation message"))?;
        let daemon = self
            .daemon
            .as_mut()
            .ok_or_else(|| format!("{tool}: the conversation is not connected; try again"))?;
        let messages = daemon
            .history(&conversation, seq + 1, 1)
            .map_err(|e| format!("{tool}: reading message {view_id} failed: {e}"))?;
        let message = messages
            .into_iter()
            .find(|m| m.seq == seq)
            .ok_or_else(|| format!("{tool}: message {view_id} is gone from the conversation"))?;
        if message.author == self.settings.membership.participant {
            return Err(format!(
                "{tool}: line {view_id} is your own message; name a user message"
            ));
        }
        if message.retracted_at.is_some() {
            return Err(format!("{tool}: message {view_id} was retracted"));
        }
        Ok(message)
    }

    /// The `react` tool: a tapback on the user message of view line
    /// `view_id`, posted at once.
    pub(super) fn react(&mut self, view_id: u64, reaction: &str) -> Result<String, String> {
        let tapback = tapback(reaction)?;
        let message = self.message_of_line("react", view_id)?;
        let name = tapback_name(tapback);
        let key = format!("react-{}-{}-{name}", message.conversation, message.seq);
        if self.reacted.contains(&key)
            || self.state.outbox.iter().any(|e| e.idempotency_key == key)
            || message.reactions.iter().any(|r| {
                r.author == self.settings.membership.participant
                    && r.kind == ReactionKind::Tapback(tapback)
            })
        {
            return Ok(format!(
                "outcome: noop. message {view_id} already has your {name}"
            ));
        }
        self.reacted.insert(key.clone());
        self.state.outbox.push(op_entry(
            message.conversation.clone(),
            key,
            Op::ReactionAdd {
                message_id: message.id.clone(),
                part_index: 0,
                reaction: ReactionKind::Tapback(tapback),
            },
        ));
        self.save();
        self.flush_outbox();
        Ok(format!(
            "outcome: done. reacted {name} to message {view_id}"
        ))
    }

    /// The `reply` tool: `text` posted now, in the thread of the user
    /// message of view line `view_id`.
    pub(super) fn reply_now(&mut self, view_id: u64, text: &str) -> Result<String, String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("reply: `text` must be a non-empty text".to_owned());
        }
        let message = self.message_of_line("reply", view_id)?;
        let root = message
            .thread_root
            .clone()
            .unwrap_or_else(|| message.id.clone());
        let key = format!(
            "reply-{}-{}-{:016x}",
            message.conversation,
            message.seq,
            fnv(text.as_bytes())
        );
        if self.state.outbox.iter().any(|e| e.idempotency_key == key) {
            return Ok(format!(
                "outcome: noop. this reply to message {view_id} is already sent"
            ));
        }
        let text = self.link_subagents(text);
        let mut entry = super::reply_entry(message.conversation.clone(), &key, &text);
        if let Op::MessageSend {
            reply_to,
            thread_root,
            ..
        } = &mut entry.op
        {
            *reply_to = Some(PartRef {
                message_id: message.id.clone(),
                part_index: 0,
            });
            *thread_root = Some(root);
        }
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
        Ok(format!(
            "outcome: done. replied in the thread of message {view_id}"
        ))
    }
}

/// An outbox entry for a non-message op.
fn op_entry(conversation: String, key: String, op: Op) -> OutboxEntry {
    OutboxEntry {
        conversation,
        idempotency_key: key,
        op,
        rate_retried: false,
        not_before: None,
        attempted: false,
        rate_attempts: 0,
        previews_until: None,
        plain_text: None,
    }
}

/// A threaded `message.send` the owner refused for its thread (an unknown or
/// bad root or parent): the same parts at the top level, or None when `op`
/// is not one.
pub(super) fn unthreaded(op: &Op, reason: &str) -> Option<Op> {
    let thread_refusal = ["thread", "unknown_message", "invalid_part_index"]
        .iter()
        .any(|r| reason.contains(r));
    match op {
        Op::MessageSend {
            client_msg_id,
            parts,
            reply_to,
            answers,
            answers_pending,
            thread_root,
        } if thread_refusal && (reply_to.is_some() || thread_root.is_some()) => {
            Some(Op::MessageSend {
                client_msg_id: client_msg_id.clone(),
                parts: parts.clone(),
                reply_to: None,
                answers: answers.clone(),
                answers_pending: answers_pending.clone(),
                thread_root: None,
            })
        }
        _ => None,
    }
}

/// FNV-1a, for a stable idempotency key of a reply's text.
fn fnv(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
