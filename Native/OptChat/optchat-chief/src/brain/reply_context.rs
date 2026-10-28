//! The reply marker of a person's message (a thread reply in Home or iOS):
//! the logged user line starts with one short line naming the message it
//! answers, `(reply to #<line id>: <quote>)`, so the turn and the compactor
//! see the reply target. It is logged once with the message and never
//! changes, so it costs a few bytes and keeps every cached prefix.
//!
//! - Not a reply: nothing.
//! - The target is the message right before it: `(reply to #<line id>)`, or
//!   `(reply to previous message)` when it is the Chief's own message (its
//!   words are the Chief's talk lines); no quote, the view already holds it.
//!   A message right before it that was never logged (it did not wake the
//!   Chief) is quoted like an earlier one.
//! - Otherwise `(reply to #<line id>: <quote>)` for a logged message, or
//!   `(reply to <author>: <quote>)`; the quote is the target's first
//!   `QUOTE_CHARS` characters on one line.

use cmux_chief::rules::message_text;
use cmux_conversation::{Message, Part};

use super::Brain;

/// The quote's length, in characters.
pub const QUOTE_CHARS: usize = 80;

/// Messages read before a reply to find its target and the message before it.
const WINDOW: u32 = 64;

/// Where the reply target sits, as the marker names it.
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    /// The message right before the reply.
    Previous { line: Option<u64> },
    /// An earlier message: its line id, or its author's name, and its quote.
    Earlier {
        line: Option<u64>,
        author: String,
        quote: String,
    },
    /// Not among the messages read (older than `WINDOW`, not a user message).
    Older,
    /// The conversation could not be read: says nothing it does not know.
    Unread,
}

/// The marker line for `target`.
pub fn marker(target: &Target) -> String {
    match target {
        Target::Previous { line: Some(line) } => format!("(reply to #{line})"),
        Target::Previous { line: None } => "(reply to previous message)".to_owned(),
        Target::Earlier {
            line: Some(line),
            quote,
            ..
        } => format!("(reply to #{line}: {quote})"),
        Target::Earlier {
            line: None,
            author,
            quote,
        } => format!("(reply to {author}: {quote})"),
        Target::Older => "(reply to an older message)".to_owned(),
        Target::Unread => "(reply to a message)".to_owned(),
    }
}

/// `text` with `marker` as its first line.
pub fn marked(marker: Option<&str>, text: &str) -> String {
    match marker {
        Some(m) => format!("{m}\n{text}"),
        None => text.to_owned(),
    }
}

/// The first `QUOTE_CHARS` characters of `message` on one line (whitespace
/// runs as one space), with `…` when cut; a message without text names its
/// first attachment.
pub fn quote(message: &Message) -> String {
    if message.retracted_at.is_some() {
        return "[retracted]".to_owned();
    }
    let text = message_text(message);
    let flat: Vec<&str> = text.split_whitespace().collect();
    if flat.is_empty() {
        return message
            .parts
            .iter()
            .find_map(|p| match p {
                Part::Attachment { name, .. } => Some(format!("[attachment {name}]")),
                _ => None,
            })
            .unwrap_or_else(|| "[no text]".to_owned());
    }
    let flat = flat.join(" ");
    if flat.chars().count() <= QUOTE_CHARS {
        return flat;
    }
    let cut: String = flat.chars().take(QUOTE_CHARS).collect();
    format!("{}…", cut.trim_end())
}

/// Whether a person saw `message` before the reply: an aside (a desk notice)
/// or a bubble Home does not draw is not "the message before".
fn shown(message: &Message) -> bool {
    crate::voice::of(&message.client_msg_id).is_none() && super::transcript::visible(message)
}

impl Brain {
    /// The reply marker of `message`, a message of the Chief conversation;
    /// None when it replies to nothing or the conversation cannot be read.
    pub(super) fn reply_marker(&mut self, message: &Message) -> Option<String> {
        let parent = message.reply_to.as_ref()?.message_id.clone();
        let conversation = self.state.conversation.clone()?;
        let daemon = self.daemon.as_mut()?;
        let before = match daemon.history(&conversation, message.seq, WINDOW) {
            Ok(before) => before,
            Err(e) => {
                (self.log)(&format!(
                    "reading the reply target of message {} failed: {e}",
                    message.seq
                ));
                return Some(marker(&Target::Unread));
            }
        };
        let previous = before.iter().rev().find(|m| shown(m)).map(|m| m.id.clone());
        let mut found = before.into_iter().find(|m| m.id == parent);
        if found.is_none()
            && let Some(seq) = self.message_seqs.get(&parent).copied()
        {
            found = daemon
                .history(&conversation, seq + 1, 1)
                .ok()
                .and_then(|m| m.into_iter().find(|m| m.id == parent));
        }
        let Some(target) = found else {
            return Some(marker(&Target::Older));
        };
        let line = self
            .chat
            .logged_id(&format!("{conversation}#{}", target.seq));
        let own = target.author == self.settings.membership.participant;
        let target = if previous.as_deref() == Some(parent.as_str()) && (line.is_some() || own) {
            Target::Previous { line }
        } else {
            Target::Earlier {
                line,
                author: self.author_name(&target.author),
                quote: quote(&target),
            }
        };
        Some(marker(&target))
    }

    /// The short name the marker gives `author`: `Chief`, or their display name.
    fn author_name(&self, author: &str) -> String {
        if author == self.settings.membership.participant {
            return crate::prompt::AGENT.to_owned();
        }
        self.summary
            .as_ref()
            .and_then(|s| s.participants.iter().find(|p| p.id == author))
            .map(|p| p.display_name.trim())
            .filter(|n| !n.is_empty())
            .unwrap_or(author)
            .to_owned()
    }
}
