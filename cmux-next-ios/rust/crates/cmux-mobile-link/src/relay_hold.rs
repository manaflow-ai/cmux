//! The relay-held send queue, both ends (RFD 0142 R8; PROTOCOL.md "Relay-held sends"). Pure: the caller owns
//! the relay socket, the clock and the durable store.
//!
//! A send the phone makes while the Mac is not joined to the session's relay goes over the phone's relay
//! socket as `{"type":"hold","id","sealed"}`, where `sealed` is the store-and-forward item
//! ([`crate::mailbox_client::item`]): signed by the phone, sealed to the Mac's box key, the id inside the
//! signature. The relay answers `held` in one relay RTT and keeps it (10 minutes at most); the Mac gets it as
//! `held_item` when it joins and answers `held_ack`, and the phone then hears `delivered`.
//!
//! - [`HoldSender`] (phone): what to send, what to send again after a redial, when a send counts as accepted.
//! - [`HeldInbox`] (Mac): applies an id at most once across redeliveries, lost acks and a killed process,
//!   given the caller persists [`HeldInbox::snapshot`] in the same write as the send's effect.
//!
//! The relay reads the id, the sender, the sealed length and times, never the text. Off unless the backend has
//! `LINK_RELAY_HOLD=on`; an off relay answers `hold_refused` with `off` and the phone uses the mailbox route.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

/// What an item may wait in the relay (the P8 mailbox's default hold), ms.
pub const HOLD_TTL_MS: u64 = 10 * 60 * 1000;
/// Ids the inbox remembers at most; past it the earliest-expiring go first (all long expired in practice).
pub const INBOX_MAX_IDS: usize = 4096;

/// A frame the phone or the Mac writes to the relay socket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Outgoing {
    Hold { id: String, sealed: String },
    HeldAck { id: String },
}

impl Outgoing {
    pub fn to_text(&self) -> String {
        serde_json::to_string(self).expect("hold frames serialize")
    }
}

/// Why the relay would not hold a send.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusedCode {
    /// The relay-held queue is off on this backend.
    Off,
    /// Not a UUID id, or not a sealed base64url string of at most 16384 characters.
    Bad,
    /// The session holds 64 items or 512 KiB of sealed text already.
    Full,
}

/// A frame the relay writes about the queue.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Incoming {
    #[serde(rename_all = "camelCase")]
    Held {
        id: String,
        depth: u32,
        expires_at: u64,
        #[serde(default)]
        delivered: bool,
    },
    HoldRefused {
        #[serde(default)]
        id: Option<String>,
        code: RefusedCode,
    },
    #[serde(rename_all = "camelCase")]
    HeldItem {
        id: String,
        from: String,
        sealed: String,
        at: u64,
        expires_at: u64,
    },
    Delivered {
        id: String,
    },
}

impl Incoming {
    /// The hold frame in `text`, or `None` for any other relay text (`joined`, `peer`, `error`).
    pub fn parse(text: &str) -> Option<Incoming> {
        serde_json::from_str(text).ok()
    }
}

/// Where one of the phone's sends stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendState {
    /// Written to the relay, no answer yet (sent again after a redial).
    Sending,
    /// The relay holds it: the send is done as far as the user is concerned.
    Accepted,
    /// The Mac acked it.
    Delivered,
}

/// What a relay frame changed for the phone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SenderEvent {
    /// Accepted `ms` after the first write of it.
    Accepted {
        id: String,
        ms: u64,
    },
    Delivered {
        id: String,
    },
    /// The relay will not hold it: route it as before (the mailbox, or fail).
    Refused {
        id: String,
        code: RefusedCode,
    },
}

struct Pending {
    sealed: String,
    first_sent_ms: u64,
    state: SendState,
}

/// The phone's side: one per relay session.
#[derive(Default)]
pub struct HoldSender {
    pending: HashMap<String, Pending>,
}

impl HoldSender {
    pub fn new() -> Self {
        Self::default()
    }

    /// The frame for a new send (or the same frame again for an id already sending: one id, one item).
    pub fn send(&mut self, id: &str, sealed: &str, now_ms: u64) -> String {
        let id = id.to_lowercase();
        let entry = self.pending.entry(id.clone()).or_insert(Pending {
            sealed: sealed.to_string(),
            first_sent_ms: now_ms,
            state: SendState::Sending,
        });
        Outgoing::Hold { id, sealed: entry.sealed.clone() }.to_text()
    }

    /// After a redial: every send with no answer yet, again, with its own id (the relay answers a known id
    /// with its first ack and stores nothing new).
    pub fn resend(&self) -> Vec<String> {
        let mut out: Vec<(&String, &Pending)> =
            self.pending.iter().filter(|(_, p)| p.state == SendState::Sending).collect();
        out.sort_by_key(|(_, p)| p.first_sent_ms);
        out.into_iter()
            .map(|(id, p)| Outgoing::Hold { id: id.clone(), sealed: p.sealed.clone() }.to_text())
            .collect()
    }

    pub fn state(&self, id: &str) -> Option<SendState> {
        self.pending.get(&id.to_lowercase()).map(|p| p.state)
    }

    /// A relay text frame; `None` when it is not about one of these sends.
    pub fn on_frame(&mut self, frame: &Incoming, now_ms: u64) -> Option<SenderEvent> {
        match frame {
            Incoming::Held { id, delivered, .. } => {
                let p = self.pending.get_mut(id)?;
                if *delivered {
                    p.state = SendState::Delivered;
                    return Some(SenderEvent::Delivered { id: id.clone() });
                }
                if p.state != SendState::Sending {
                    return None;
                }
                p.state = SendState::Accepted;
                Some(SenderEvent::Accepted { id: id.clone(), ms: now_ms.saturating_sub(p.first_sent_ms) })
            }
            Incoming::Delivered { id } => {
                let p = self.pending.get_mut(id)?;
                if p.state == SendState::Delivered {
                    return None;
                }
                p.state = SendState::Delivered;
                Some(SenderEvent::Delivered { id: id.clone() })
            }
            Incoming::HoldRefused { id: Some(id), code } => {
                let p = self.pending.remove(id)?;
                drop(p);
                Some(SenderEvent::Refused { id: id.clone(), code: *code })
            }
            _ => None,
        }
    }

    /// Forget delivered sends (their ids live on in the Mac's inbox).
    pub fn prune_delivered(&mut self) {
        self.pending.retain(|_, p| p.state != SendState::Delivered);
    }
}

/// What the Mac does with one `held_item`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Not seen: open, verify and apply it, then [`HeldInbox::settle`] in the same durable write, then ack.
    Apply,
    /// Applied before (a redelivery, a lost ack, a restart): do not apply; ack it again.
    AckOnly,
}

/// The Mac's side: the ids it applied, each until its item could no longer be redelivered.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeldInbox {
    /// id -> until when it must be remembered (its item's expiry), ms.
    seen: BTreeMap<String, u64>,
}

impl HeldInbox {
    pub fn new() -> Self {
        Self::default()
    }

    /// Restore what [`Self::snapshot`] wrote; an unreadable snapshot is an error, never an empty inbox
    /// (an empty one would apply every redelivery again).
    pub fn restore(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }

    pub fn snapshot(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("inbox serializes")
    }

    pub fn check(&self, id: &str) -> Verdict {
        if self.seen.contains_key(&id.to_lowercase()) { Verdict::AckOnly } else { Verdict::Apply }
    }

    /// Record `id` as applied; persist [`Self::snapshot`] with the send's effect, before the ack.
    pub fn settle(&mut self, id: &str, expires_at_ms: u64, now_ms: u64) {
        self.seen.insert(id.to_lowercase(), expires_at_ms.max(now_ms));
        self.prune(now_ms);
    }

    /// The ack for `id`.
    pub fn ack(id: &str) -> String {
        Outgoing::HeldAck { id: id.to_lowercase() }.to_text()
    }

    pub fn len(&self) -> usize {
        self.seen.len()
    }

    pub fn is_empty(&self) -> bool {
        self.seen.is_empty()
    }

    fn prune(&mut self, now_ms: u64) {
        self.seen.retain(|_, until| *until > now_ms);
        while self.seen.len() > INBOX_MAX_IDS {
            let oldest = self.seen.iter().min_by_key(|(_, u)| **u).map(|(k, _)| k.clone());
            match oldest {
                Some(k) => self.seen.remove(&k),
                None => break,
            };
        }
    }
}

#[cfg(test)]
mod tests;
