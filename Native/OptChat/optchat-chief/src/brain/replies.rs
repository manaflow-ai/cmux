//! Replies and reactions (plans/cmux-next/chief-replies-reactions-DESIGN.md):
//! where a reply in the Chief's DM goes (the thread of the message it
//! answers, by `replies.thread`), and the Chief's two output tools, `react`
//! (a tapback on a user message) and `reply` (a message now, in the thread of
//! a user message). Both tools name the message by the id the Chief sees in
//! its view; the log keeps each user message's `<conversation>#<seq>`.

use cmux_chief::rules::message_text;
use cmux_conversation::{Message, Op, PartRef, ReactionKind, Tapback};

use super::Brain;
use super::transcript::{TRANSCRIPT_MAX, who};
use crate::chief_settings::ReplyThreads;
use crate::state::OutboxEntry;

/// The most characters of a replied-to message its note keeps.
const REPLY_PARENT_CHARS: usize = 2000;

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

/// The tapback a `react` reaction names (a tapback word, or its iMessage emoji).
pub fn tapback(reaction: &str) -> Result<Tapback, String> {
    Ok(match reaction.trim().trim_end_matches('\u{FE0F}') {
        "like" | "ack" | "thumbs_up" | "👍" => Tapback::Like,
        "love" | "heart" | "❤" => Tapback::Love,
        "laugh" | "haha" | "😂" => Tapback::Laugh,
        "emphasize" | "!!" | "‼" => Tapback::Emphasize,
        "question" | "?" | "❓" => Tapback::Question,
        "dislike" | "thumbs_down" | "👎" => Tapback::Dislike,
        other => {
            return Err(format!(
                "react: no reaction {other:?}; one of {} or one emoji",
                REACTIONS.join(", ")
            ));
        }
    })
}

/// The reaction `react` posts: a tapback (by word or iMessage emoji), else one
/// emoji (no letters, digits, spaces or controls; at most 64 bytes, the owner's
/// limit) as an emoji reaction.
pub fn reaction(text: &str) -> Result<ReactionKind, String> {
    match tapback(text) {
        Ok(t) => Ok(ReactionKind::Tapback(t)),
        Err(refusal) => {
            let text = text.trim();
            let emoji = !text.is_empty() && text.len() <= 64 && text.chars().all(emoji_char);
            if emoji {
                Ok(ReactionKind::Emoji(text.to_owned()))
            } else {
                Err(refusal)
            }
        }
    }
}

/// A character of an emoji: pictographs and symbols, the variation selector,
/// the zero-width joiner, skin tones and flag tags.
fn emoji_char(c: char) -> bool {
    matches!(c as u32,
        0x203C | 0x2049 | 0x2100..=0x2BFF | 0x3030 | 0x303D | 0x3297 | 0x3299
        | 0x1F000..=0x1FAFF | 0xFE0F | 0x200D | 0x20E3 | 0xE0020..=0xE007F)
}

fn reaction_name(kind: &ReactionKind) -> String {
    match kind {
        ReactionKind::Tapback(t) => tapback_name(*t).to_owned(),
        ReactionKind::Emoji(e) => e.clone(),
    }
}

/// How a note names someone's reaction, and the stable tag its key carries:
/// a tapback as its iMessage glyph and word (`❤️ love`, tag `love`), an emoji
/// as itself (tag `e` + its hash).
pub(super) fn reaction_label(kind: &ReactionKind) -> (String, String) {
    match kind {
        ReactionKind::Tapback(t) => {
            let glyph = match t {
                Tapback::Like => "👍",
                Tapback::Love => "❤️",
                Tapback::Laugh => "😂",
                Tapback::Emphasize => "‼️",
                Tapback::Question => "❓",
                Tapback::Dislike => "👎",
            };
            let name = tapback_name(*t);
            (format!("{glyph} {name}"), name.to_owned())
        }
        ReactionKind::Emoji(e) => (e.clone(), format!("e{:016x}", fnv(e.as_bytes()))),
    }
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

/// The Chief's message in a voice (a desk approval notice): an aside that does
/// not move the Chief's reply off its message, so threading skips it.
fn aside(message: &Message) -> bool {
    crate::voice::of(&message.client_msg_id).is_some()
}

impl Brain {
    /// Records a message of the Chief conversation as it is handled: the
    /// newest seq, and for a user message its seq and, when it is itself a
    /// thread reply, its root (saved, so a later report still finds it).
    pub(super) fn note_main_message(&mut self, message: &Message) {
        let own = message.author == self.settings.membership.participant;
        if !(own && aside(message)) {
            self.newest_seq = self.newest_seq.max(message.seq);
        }
        if own {
            return;
        }
        self.message_seqs.insert(message.id.clone(), message.seq);
        if let Some(root) = &message.thread_root {
            self.state.note_root(&message.id, root);
        }
    }

    /// The message a person's reply points at, logged as a note before the
    /// reply when the log has no line for it (a host bubble, another author's
    /// message): its id, seq, author and text, so the Chief reads what the
    /// person replied to and zoom resolves the note's line. A parent with a
    /// line of its own, and the Chief's own replies, log nothing.
    pub(super) fn note_reply_parent(&mut self, message: &Message) {
        let Some(parent) = &message.reply_to else {
            return;
        };
        let me = self.settings.membership.participant.clone();
        if message.author == me || message.retracted_at.is_some() {
            return;
        }
        let main = message.conversation.clone();
        let logged =
            |brain: &Self, seq: u64| brain.chat.logged_id(&format!("{main}#{seq}")).is_some();
        if self
            .message_seqs
            .get(&parent.message_id)
            .is_some_and(|seq| logged(self, *seq))
        {
            return;
        }
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        let found = match daemon.history(&main, message.seq, TRANSCRIPT_MAX) {
            Ok(older) => older.into_iter().find(|m| m.id == parent.message_id),
            Err(e) => {
                (self.log)(&format!(
                    "reading the message #{} replies to failed: {e}",
                    message.seq
                ));
                return;
            }
        };
        let key = format!("{main}#{}:reply-parent", message.seq);
        let body = match found {
            Some(parent_message) if logged(self, parent_message.seq) => return,
            Some(parent_message) => {
                let text = message_text(&parent_message);
                let text = if text.trim().is_empty() {
                    "(no text: an attachment or card)".to_owned()
                } else {
                    text.chars().take(REPLY_PARENT_CHARS).collect()
                };
                let by = who(self.summary.as_ref(), &parent_message.author, &me);
                format!(
                    "the message #{} replies to {} (#{}, {}): {text}",
                    message.seq, parent.message_id, parent_message.seq, by
                )
            }
            None => format!(
                "the message #{} replies to {}, which is not among the last {TRANSCRIPT_MAX} messages of the conversation; the log has no text for it",
                message.seq, parent.message_id
            ),
        };
        let entry = optchat_host::NewMessage {
            key: Some(key),
            ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &body)
        };
        if let Err(e) = self.chat.append_with(&[entry], |_| Vec::new()) {
            (self.log)(&format!(
                "logging the message #{} replies to failed: {e}",
                message.seq
            ));
        }
    }

    /// A message the Chief posted in its conversation under `key` (the
    /// owner's answer).
    pub(super) fn note_posted(&mut self, conversation: &str, key: &str, message: &Message) {
        if self.state.conversation.as_deref() == Some(conversation)
            && crate::voice::of(key).is_none()
        {
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
                    e.conversation == conversation
                        && matches!(e.op, Op::MessageSend { .. })
                        && crate::voice::of(&e.idempotency_key).is_none()
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

    /// The thread a reply naming view line `view_id` goes into when that line
    /// is no conversation message: for a subagent's report (`[a12] ...`), the
    /// thread of the person's message the subagent answers, as its report
    /// itself would post (`answers_of`); `(conversation, message id, root)`.
    /// None: no person message is behind the line (a note, a tool line, or a
    /// report of a subagent no message started); the reply goes to the top level.
    pub(super) fn thread_behind_line(&self, view_id: u64) -> Option<(String, String, String)> {
        let (_, text) = self.chat.message(view_id)?;
        let id = text.strip_prefix('[')?.split(']').next()?;
        let answers = self.state.spawns.values().find_map(|record| {
            let sub = record.subs.iter().find(|s| s.id == id)?;
            Some(if sub.answers.is_empty() {
                record.answers.clone()
            } else {
                sub.answers.clone()
            })
        })?;
        let message = answers.last()?.clone();
        let conversation = self.state.conversation.clone()?;
        let root = self.state.root_of(&message);
        Some((conversation, message, root))
    }

    /// The conversation message the Chief's view line `view_id` logged.
    pub(super) fn message_of_line(&mut self, tool: &str, view_id: u64) -> Result<Message, String> {
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
        let kind = self::reaction(reaction)?;
        let message = self.message_of_line("react", view_id)?;
        let name = reaction_name(&kind);
        let key = match &kind {
            ReactionKind::Tapback(_) => {
                format!("react-{}-{}-{name}", message.conversation, message.seq)
            }
            ReactionKind::Emoji(e) => format!(
                "react-{}-{}-e{:016x}",
                message.conversation,
                message.seq,
                fnv(e.as_bytes())
            ),
        };
        if self.reacted.contains(&key)
            || self.state.outbox.iter().any(|e| e.idempotency_key == key)
            || message
                .reactions
                .iter()
                .any(|r| r.author == self.settings.membership.participant && r.kind == kind)
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
                reaction: kind.clone(),
            },
        ));
        // A tapback is the Chief's answer to the message it is on (the
        // react tool: "instead of a reply that only acknowledges"): it
        // leaves the reply ledger, so no retry turn adds words to it.
        self.reply_not_needed(std::slice::from_ref(&message.id));
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
        // A line that is no conversation message (a subagent's report): the
        // thread of the person's message behind it, else the top level.
        let (target, outcome) = if self.chat.logged_key(view_id).is_some() {
            let message = self.message_of_line("reply", view_id)?;
            let root = message
                .thread_root
                .clone()
                .unwrap_or_else(|| message.id.clone());
            (
                Some((message.conversation.clone(), message.id.clone(), root)),
                format!("outcome: done. replied in the thread of message {view_id}"),
            )
        } else {
            match self.thread_behind_line(view_id) {
                Some(thread) => (
                    Some(thread),
                    format!(
                        "outcome: done. line {view_id} is a report, not a message: replied in the thread of the message it answers"
                    ),
                ),
                None => (
                    None,
                    format!(
                        "outcome: done. line {view_id} is not a message and no message is behind it: posted at the top level"
                    ),
                ),
            }
        };
        let conversation = match &target {
            Some((c, _, _)) => c.clone(),
            None => self
                .state
                .conversation
                .clone()
                .ok_or("reply: the conversation is not connected yet; try again")?,
        };
        let key = format!(
            "reply-{conversation}-{}-{:016x}",
            target.as_ref().map_or("top", |(_, m, _)| m.as_str()),
            fnv(text.as_bytes())
        );
        if self.state.outbox.iter().any(|e| e.idempotency_key == key) {
            return Ok(format!(
                "outcome: noop. this reply to message {view_id} is already sent"
            ));
        }
        let text = self.link_subagents(text);
        let mut entry = super::reply_entry(conversation, &key, &text);
        if let (
            Some((_, message_id, root)),
            Op::MessageSend {
                reply_to,
                thread_root,
                ..
            },
        ) = (target, &mut entry.op)
        {
            *reply_to = Some(PartRef {
                message_id,
                part_index: 0,
            });
            *thread_root = Some(root);
        }
        let entry = self.reply_with_previews(entry);
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
        Ok(outcome)
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
pub(super) fn fnv(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
