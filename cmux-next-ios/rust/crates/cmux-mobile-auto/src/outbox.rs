//! A message this phone sent, from the store's answer until the chat's own records show it.
//!
//! The store takes a message into the chat's inbox; the chat's holder reads it later (a Cloud
//! machine may have to start first). Until then the phone draws the message as a waiting
//! prompt, and the chat says "Resuming…" while a machine is being started for it. When the
//! holder's records show the message, the phone's own row goes.
//!
//! The holder gives each inbox message to the chat under the message's id, so the record that
//! shows it names that id. A holder that names it differently is matched by the message's text
//! once the holder has taken it, so the phone's row never stays beside the real one.

use cmux_auto_session::wire::{Delivery, InboxPosted, SessionView};
use serde_json::Value;

use crate::records;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Sent {
    id: String,
    text: String,
    /// What the store said happens to it.
    delivery: Delivery,
    /// The holder has taken the message once it acked the inbox through this number. It is
    /// the inbox's newest number when the store answered, so it is this message's or a later
    /// one's.
    through: u64,
    /// The holder took it.
    taken: bool,
}

/// The messages this phone sent that the chat has not shown yet.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outbox {
    sent: Vec<Sent>,
}

impl Outbox {
    /// The store took `id` (or took it before: the same id again changes nothing). Answers the
    /// record that draws it as waiting, the first time.
    pub fn posted(&mut self, chat: &str, id: &str, text: &str, posted: &InboxPosted) -> Option<Value> {
        if self.sent.iter().any(|sent| sent.id == id) {
            return None;
        }
        let through = posted.session.inbox;
        let taken = through <= posted.session.inbox_acked;
        let position = self.sent.len();
        self.sent.push(Sent {
            id: id.to_owned(),
            text: text.to_owned(),
            delivery: posted.state,
            through,
            taken,
        });
        Some(records::waiting(chat, id, text, position))
    }

    /// The chat as the store answers it now: which messages its holder has taken.
    pub fn viewed(&mut self, view: &SessionView) {
        for sent in &mut self.sent {
            sent.taken = sent.taken || sent.through <= view.inbox_acked;
        }
    }

    /// One of the chat's own records is about to be drawn. When it shows a message this phone
    /// sent, answers the record that takes the phone's waiting row away first.
    pub fn recorded(&mut self, chat: &str, record: &Value) -> Option<Value> {
        let (id, text) = records::prompt_of(record)?;
        let at = self
            .sent
            .iter()
            .position(|sent| sent.id == id)
            .or_else(|| self.sent.iter().position(|sent| sent.taken && sent.text == text))?;
        let sent = self.sent.remove(at);
        Some(records::shown(chat, &sent.id))
    }

    /// What the store answered to the messages the holder has not taken yet: the one furthest
    /// from running (nobody can run it, then a machine is starting, then delivered). None when
    /// the holder took them all.
    pub fn waiting(&self) -> Option<Delivery> {
        let rank = |delivery: Delivery| match delivery {
            Delivery::Delivered => 0,
            Delivery::Resuming => 1,
            Delivery::Queued => 2,
        };
        self.sent
            .iter()
            .filter(|sent| !sent.taken)
            .map(|sent| sent.delivery)
            .max_by_key(|delivery| rank(*delivery))
    }

    /// How many messages the chat has not shown yet.
    pub fn len(&self) -> usize {
        self.sent.len()
    }

    pub fn is_empty(&self) -> bool {
        self.sent.is_empty()
    }
}
