//! The WebSocket relay's tail replay (RFD 0142 R3, make-before-break; PROTOCOL.md "WebSocket relay"), as a
//! pure model of `LinkRelay`'s tail in `backend/src/link-relay.ts`. The fake backend
//! ([`crate::testing`]) relays through it, so every Rust test of a link on the relay runs against a relay that
//! replays, as production does (`LINK_RELAY_TAIL` is on unless set to `off`).
//!
//! The relay keeps the last [`TAIL_MS`] of frames it relayed toward each device, or found no socket for, at
//! most [`TAIL_BYTES`] a session, oldest dropped first. When a device joins again (a newer socket replacing
//! one whose network died, or a redial), its frames go out on the new socket at once, oldest first, and leave
//! the tail, so a second rejoin replays nothing twice. The frames are the same WireGuard ciphertext the relay
//! already forwards; the copies that did arrive die in WireGuard's replay window. Memory only, never stored.
//!
//! Pure: the caller owns the sockets and the clock (milliseconds, any epoch, never going back).

use std::collections::VecDeque;

use bytes::Bytes;

/// How far back a rejoin's replay reaches (link-relay.ts `RELAY_TAIL_MS`).
pub const TAIL_MS: u64 = 1000;
/// The most one session's tail holds, both directions (link-relay.ts `RELAY_TAIL_BYTES`).
pub const TAIL_BYTES: usize = 256 * 1024;

/// One kept frame: when it was relayed (or held), toward whom, the stamped frame.
#[derive(Debug, Clone)]
struct Kept {
    at: u64,
    target: String,
    frame: Bytes,
}

/// One session's tail. Oldest first; `keep` and `take` are linear in what they drop or return, not in the tail.
#[derive(Debug, Default)]
pub struct RelayTail {
    frames: VecDeque<Kept>,
    bytes: usize,
}

impl RelayTail {
    pub fn new() -> Self {
        Self::default()
    }

    /// Keep `frame`, relayed (or held) toward `target` at `now`. Past [`TAIL_BYTES`] the oldest frames go; a
    /// frame larger than the whole tail is not kept.
    pub fn keep(&mut self, target: &str, frame: Bytes, now: u64) {
        self.prune(now);
        if frame.len() > TAIL_BYTES {
            return;
        }
        self.bytes += frame.len();
        self.frames.push_back(Kept { at: now, target: target.to_owned(), frame });
        while self.bytes > TAIL_BYTES {
            let Some(old) = self.frames.pop_front() else { break };
            self.bytes -= old.frame.len();
        }
    }

    /// `device` just joined: its frames of the last [`TAIL_MS`], oldest first, taken out of the tail.
    pub fn take(&mut self, device: &str, now: u64) -> Vec<Bytes> {
        self.prune(now);
        if !self.frames.iter().any(|k| k.target == device) {
            return Vec::new();
        }
        let mut mine = Vec::new();
        let mut rest = VecDeque::with_capacity(self.frames.len());
        for kept in self.frames.drain(..) {
            if kept.target == device {
                self.bytes -= kept.frame.len();
                mine.push(kept.frame);
            } else {
                rest.push_back(kept);
            }
        }
        self.frames = rest;
        mine
    }

    /// Bytes held now (both directions).
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// Frames held now (both directions).
    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    /// Drop what is older than [`TAIL_MS`] at `now`.
    fn prune(&mut self, now: u64) {
        while let Some(front) = self.frames.front() {
            if now.saturating_sub(front.at) <= TAIL_MS {
                break;
            }
            self.bytes -= front.frame.len();
            self.frames.pop_front();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(tag: u8, len: usize) -> Bytes {
        let mut v = vec![tag; len.max(1)];
        v[0] = tag;
        Bytes::from(v)
    }

    #[test]
    fn a_rejoin_gets_its_frames_oldest_first_and_only_once() {
        let mut tail = RelayTail::new();
        tail.keep("phone", frame(1, 10), 0);
        tail.keep("mac", frame(2, 10), 1);
        tail.keep("phone", frame(3, 10), 2);
        let got = tail.take("phone", 3);
        assert_eq!(got.iter().map(|f| f[0]).collect::<Vec<_>>(), vec![1, 3]);
        assert!(tail.take("phone", 4).is_empty(), "a second rejoin replays nothing twice");
        assert_eq!(tail.len(), 1);
        assert_eq!(tail.bytes(), 10);
        assert_eq!(tail.take("mac", 5).iter().map(|f| f[0]).collect::<Vec<_>>(), vec![2]);
        assert!(tail.is_empty());
        assert_eq!(tail.bytes(), 0);
    }

    #[test]
    fn only_the_last_second_is_replayed() {
        let mut tail = RelayTail::new();
        tail.keep("phone", frame(1, 10), 0);
        tail.keep("phone", frame(2, 10), 600);
        tail.keep("phone", frame(3, 10), 1200);
        // At 1601 the frame from 600 is 1001 ms old.
        assert_eq!(tail.take("phone", 1601).iter().map(|f| f[0]).collect::<Vec<_>>(), vec![3]);
        tail.keep("phone", frame(4, 10), 2000);
        // Exactly TAIL_MS old still goes.
        assert_eq!(tail.take("phone", 3000).iter().map(|f| f[0]).collect::<Vec<_>>(), vec![4]);
    }

    #[test]
    fn the_session_bound_drops_the_oldest_and_never_passes_256_kib() {
        let mut tail = RelayTail::new();
        // 300 frames of 1200 B (a WireGuard datagram batch) in the same millisecond: 360 000 B offered.
        for i in 0..300u32 {
            tail.keep(if i % 2 == 0 { "phone" } else { "mac" }, frame((i % 251) as u8, 1200), 5);
            assert!(tail.bytes() <= TAIL_BYTES, "{} > {TAIL_BYTES}", tail.bytes());
        }
        assert_eq!(tail.bytes(), (TAIL_BYTES / 1200) * 1200);
        let phone = tail.take("phone", 6);
        let mac = tail.take("mac", 6);
        assert_eq!(phone.len() + mac.len(), TAIL_BYTES / 1200);
        // The newest frame toward the Mac (i = 299) is kept, the oldest (i = 1) is not.
        assert_eq!(mac.last().map(|f| f[0]), Some((299 % 251) as u8));
        assert_ne!(mac.first().map(|f| f[0]), Some(1));
        assert_eq!(tail.bytes(), 0);
    }

    #[test]
    fn a_frame_larger_than_the_tail_is_not_kept_and_evicts_nothing() {
        let mut tail = RelayTail::new();
        tail.keep("phone", frame(1, 100), 0);
        tail.keep("phone", frame(2, TAIL_BYTES + 1), 1);
        assert_eq!(tail.len(), 1);
        assert_eq!(tail.take("phone", 2).len(), 1);
    }

    #[test]
    fn a_device_with_nothing_kept_gets_nothing() {
        let mut tail = RelayTail::new();
        tail.keep("mac", frame(1, 10), 0);
        assert!(tail.take("phone", 1).is_empty());
        assert_eq!(tail.len(), 1, "the other device's tail stays");
    }

    /// The Durable Object and this model must not drift: the constants are read out of link-relay.ts.
    #[test]
    fn bounds_match_link_relay_ts() {
        let ts = include_str!("../../../../backend/src/link-relay.ts");
        assert!(ts.contains(&format!("export const RELAY_TAIL_MS = {TAIL_MS}\n")), "RELAY_TAIL_MS drifted");
        assert_eq!(TAIL_BYTES, 256 * 1024);
        assert!(ts.contains("export const RELAY_TAIL_BYTES = 256 * 1024\n"), "RELAY_TAIL_BYTES drifted");
    }
}
