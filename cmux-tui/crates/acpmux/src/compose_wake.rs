//! What a typing wake was worth: a person writing to a chat on a peer whose link is down wakes
//! that peer's machine (`server/peer_forward.rs` `wake_if_composing`), so its resume runs while
//! they type. This ledger counts how each such wake ended, per peer:
//! - `sent`: a message to that peer went within [`BOUND`] of the first keystroke; its lead (first
//!   keystroke to send) is kept, the time the resume had;
//! - `unsent`: none went within [`BOUND`]: a draft that was never sent, one resume thrown away,
//!   which the machine's idle pause takes back.
//!
//! RFD 0072 ("Starting a chat") left both unmeasured: how long a person types before submit, and
//! how many keystroke resumes are thrown away. `daemon status` `composeWakes` reports them, and
//! each ended wake is one log line (`composeWake`), so the assumed rate becomes a count.
//!
//! Pure apart from the shared ledger: the caller passes the clock (`now_ms`, any monotonic
//! origin). Bounded: one open wake per peer, at most [`PEERS_MAX`] peers open, the last
//! [`LEADS_MAX`] leads kept. Nothing runs in the background: a wake past its bound is closed by
//! the next call that reads the ledger.

use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

use serde_json::{Value, json};

/// The version of `daemon status` `composeWakes`.
pub const VERSION: u32 = 1;
/// A wake with no send this long after its first keystroke is thrown away: the peer's wake
/// window (`peer_wanted.rs` `WAKE_FOR`), after which the wake no longer asks anything of it.
pub const BOUND_MS: u64 = 180_000;
/// The most peers with an open wake; past it the oldest is closed as unsent.
pub const PEERS_MAX: usize = 256;
/// The most recent leads kept for the quantiles.
pub const LEADS_MAX: usize = 256;

/// How one typing wake ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ended {
    /// A message went `lead_ms` after the first keystroke.
    Sent { lead_ms: u64 },
    /// No message went within [`BOUND_MS`].
    Unsent,
}

/// Typing wakes by peer, and how the ended ones ended.
#[derive(Debug, Default)]
pub struct Ledger {
    /// Peer name -> when its open wake's first keystroke came.
    open: HashMap<String, u64>,
    opened: u64,
    sent: u64,
    unsent: u64,
    leads: VecDeque<u64>,
}

impl Ledger {
    /// A person is writing to a chat on `peer` while its link is down. Opens a wake on the first
    /// keystroke; later keystrokes of the same draft change nothing. Whether it opened one.
    pub fn composing(&mut self, peer: &str, now_ms: u64) -> bool {
        self.expire(now_ms);
        if self.open.contains_key(peer) {
            return false;
        }
        if self.open.len() >= PEERS_MAX
            && let Some(oldest) =
                self.open.iter().min_by_key(|(_, at)| **at).map(|(name, _)| name.clone())
        {
            self.open.remove(&oldest);
            self.close(&oldest, Ended::Unsent);
        }
        self.open.insert(peer.to_owned(), now_ms);
        self.opened += 1;
        true
    }

    /// A message went to a chat on `peer`. Ends its open wake as sent; None when none was open
    /// (no typing wake preceded it, or it was already past its bound).
    pub fn sent(&mut self, peer: &str, now_ms: u64) -> Option<Ended> {
        self.expire(now_ms);
        let at = self.open.remove(peer)?;
        let ended = Ended::Sent { lead_ms: now_ms.saturating_sub(at) };
        self.close(peer, ended);
        Some(ended)
    }

    /// Closes every open wake past [`BOUND_MS`] as unsent.
    pub fn expire(&mut self, now_ms: u64) {
        let late: Vec<String> = self
            .open
            .iter()
            .filter(|(_, at)| now_ms.saturating_sub(**at) >= BOUND_MS)
            .map(|(name, _)| name.clone())
            .collect();
        for name in late {
            self.open.remove(&name);
            self.close(&name, Ended::Unsent);
        }
    }

    fn close(&mut self, peer: &str, ended: Ended) {
        match ended {
            Ended::Sent { lead_ms } => {
                self.sent += 1;
                if self.leads.len() == LEADS_MAX {
                    self.leads.pop_front();
                }
                self.leads.push_back(lead_ms);
                tracing::info!(peer = %peer, lead_ms, "composeWake: sent");
            }
            Ended::Unsent => {
                self.unsent += 1;
                tracing::info!(peer = %peer, bound_ms = BOUND_MS, "composeWake: unsent");
            }
        }
    }

    /// `daemon status` `composeWakes`.
    pub fn json(&mut self, now_ms: u64) -> Value {
        self.expire(now_ms);
        let mut leads: Vec<u64> = self.leads.iter().copied().collect();
        leads.sort_unstable();
        let at = |q: f64| -> Option<u64> {
            if leads.is_empty() {
                return None;
            }
            let i = ((leads.len() as f64 * q).ceil() as usize).clamp(1, leads.len()) - 1;
            Some(leads[i])
        };
        let ended = self.sent + self.unsent;
        json!({
            "v": VERSION,
            "boundMs": BOUND_MS,
            "opened": self.opened,
            "open": self.open.len(),
            "sent": self.sent,
            "unsent": self.unsent,
            // Of the wakes that ended, the share thrown away (a draft never sent).
            "unsentShare": (ended > 0).then(|| self.unsent as f64 / ended as f64),
            "leadMs": {
                "n": leads.len(),
                "p50": at(0.5),
                "p90": at(0.9),
                "max": leads.last(),
            },
        })
    }
}

static SHARED: LazyLock<Mutex<Ledger>> = LazyLock::new(Mutex::default);
static ORIGIN: LazyLock<Instant> = LazyLock::new(Instant::now);

fn now_ms() -> u64 {
    ORIGIN.elapsed().as_millis() as u64
}

fn shared() -> std::sync::MutexGuard<'static, Ledger> {
    SHARED.lock().unwrap_or_else(|e| e.into_inner())
}

/// [`Ledger::composing`] on the daemon's ledger.
pub fn composing(peer: &str) -> bool {
    shared().composing(peer, now_ms())
}

/// [`Ledger::sent`] on the daemon's ledger.
pub fn sent(peer: &str) -> Option<Ended> {
    shared().sent(peer, now_ms())
}

/// `daemon status` `composeWakes`, from the daemon's ledger.
pub fn status() -> Value {
    shared().json(now_ms())
}

#[cfg(test)]
#[path = "compose_wake_tests.rs"]
mod tests;
