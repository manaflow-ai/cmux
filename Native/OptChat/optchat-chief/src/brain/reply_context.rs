//! Reply context: a person's message in the Chief conversation that replies
//! to an earlier one (a thread reply in Home or iOS) reaches the turn and the
//! log with one short first line naming its target, `(reply to #N: <quote>)`
//! (`optchat_core::reply_marker`), or `(reply to #N)` when the target sits
//! right above it. A message that is no reply reads as before. `#N` is the
//! conversation seq, as the `transcript` tool numbers messages.
//!
//! The targets come from the recent messages of the conversation, every
//! author, as the brain handles them and as a catch-up's snapshot shows
//! them: the last `PAGE`. In memory only; an older target is named
//! `REPLY_EARLIER`.

use std::collections::{HashMap, VecDeque};

use cmux_chief::rules::{PAGE, message_text};
use cmux_conversation::Message;

use super::Brain;

/// The marker of a reply whose target is not among the recent messages.
pub const REPLY_EARLIER: &str = "(reply to an earlier message)";

/// Characters of a target's flattened text kept for its quote: one past
/// `REPLY_QUOTE`, so the quote still shows it was cut.
const QUOTE_KEEP: usize = optchat_core::REPLY_QUOTE + 1;

/// The recent messages of the Chief conversation by id: seq and the head of
/// the text. Holds the last `PAGE` noted.
#[derive(Default)]
pub(super) struct Recent {
    by_id: HashMap<String, (u64, String)>,
    order: VecDeque<String>,
}

impl Recent {
    /// Notes `message` (again after an edit or a retraction: a retracted
    /// target is named without its quote).
    pub(super) fn note(&mut self, message: &Message) {
        let quote: String = if message.retracted_at.is_some() {
            String::new()
        } else {
            message_text(message)
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(QUOTE_KEEP)
                .collect()
        };
        if self
            .by_id
            .insert(message.id.clone(), (message.seq, quote))
            .is_none()
        {
            self.order.push_back(message.id.clone());
        }
        while self.order.len() > PAGE as usize {
            if let Some(old) = self.order.pop_front() {
                self.by_id.remove(&old);
            }
        }
    }
}

impl Brain {
    /// The text a person's message `message` is logged and read with: its
    /// text, after its reply marker when it replies to an earlier message.
    pub(super) fn turn_text(&self, message: &Message) -> String {
        let text = message_text(message);
        match self.reply_marker(message) {
            Some(marker) if text.is_empty() => marker,
            Some(marker) => format!("{marker}\n{text}"),
            None => text,
        }
    }

    /// The marker of `message`'s target: its parent, else its thread's root.
    fn reply_marker(&self, message: &Message) -> Option<String> {
        let target = message
            .reply_to
            .as_ref()
            .map(|r| r.message_id.as_str())
            .or(message.thread_root.as_deref())?;
        Some(match self.recent.by_id.get(target) {
            Some((seq, _)) if seq + 1 == message.seq => optchat_core::reply_marker(*seq, None),
            Some((seq, quote)) => optchat_core::reply_marker(*seq, Some(quote)),
            None => REPLY_EARLIER.to_owned(),
        })
    }
}
