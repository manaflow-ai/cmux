//! The reliable link (PROTOCOL.md "Reliable link"): every channel frame
//! carries a per-channel sequence, the receiver acks what it has, and the
//! sender keeps what is unacked, so a link whose carrier drops (an address
//! change, a stall, a blackout, a direct/relay path switch) resumes over a new
//! carrier: each side sends its cursors, replays only what the other lacks and
//! drops what it already has. The channels above see no drop at all.
//!
//! Negotiated: both sides list [`RELIABLE_LANE`] in their first signal (like
//! the input lane), and only then does either side set
//! [`crate::LinkConfig::reliable`]. Otherwise the link sends exactly today's
//! frames, so an older phone or Mac is untouched.
//!
//! The bookkeeping is `cmux_remote_protocol::reliable` (the core the
//! Mac-to-remote link's lanes share), keyed here by channel.
//!
//! Wire (types 7 to 10 of [`crate::frame::FrameType`]; type 5 is the parked
//! link's `deflated data`, type 6 a `sequenced` chunk. Never sent to a peer that did not offer
//! `reliable`):
//! - `seq` (channel `c`): `u64 seq | u8 inner type | inner payload`, for every
//!   open, data (plain, deflated or sequenced) and close of channel `c`. Sequences start at 1 per channel and
//!   per direction.
//! - `ack` (channel 0): `u32 n | n x (u32 channel, u64 seq)`: everything of
//!   those channels through `seq` arrived.
//! - `hello` (channel 0), the first frame of every carrier:
//!   `u8 kind | u8 version | 16-byte token | u32 max_peer_opened | u32 n | n x (u32 channel, u64 cursor)`.
//!   kind 0: a new link (the phone names its token); 1: the phone resumes the
//!   link `token`, with its cursors; 2: the Mac took the resume, with its
//!   cursors; 3: the Mac has no such link (the phone opens a new one, as
//!   today). `max_peer_opened`: the highest channel the other side opened
//!   that this side has seen; a channel at or below it with no cursor is
//!   closed here, so its frames are not replayed.
//! - `bye` (channel 0): the link ends on purpose (`Link::close`); a carrier
//!   that ends without one is resumed.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError, Weak};
use std::time::Duration;

use bytes::{Buf, BufMut, Bytes, BytesMut};

use crate::frame::FrameType;

/// The name both sides list in signaling (`lanes`) when they speak the
/// reliable link.
pub const RELIABLE_LANE: &str = "reliable";
/// Bytes one channel may have queued and unacked together before its sender
/// waits (constant per channel, whatever the channel's history): the replay
/// buffer's bound.
pub const REPLAY_BYTES_PER_CHANNEL: usize = 1024 * 1024;
/// How long a dropped carrier may stay down before the link closes as today.
pub const RESUME_WINDOW: Duration = Duration::from_secs(120);
/// Unacked received bytes past which an ack goes out at once.
pub(crate) const ACK_BYTES: usize = 64 * 1024;
/// How long received frames wait for their ack otherwise.
pub(crate) const ACK_DELAY: Duration = Duration::from_millis(20);
/// How long a new carrier waits for the peer's hello.
pub(crate) const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Channels the peer closed, remembered so a frame of theirs this side had
/// already queued is not sent (and logged) after the close.
pub(crate) const FORGOTTEN: usize = 1024;
const VERSION: u8 = 1;

pub type Token = [u8; 16];

/// A reliable link's settings (`LinkConfig::reliable`).
#[derive(Clone)]
pub struct ReliableConfig {
    pub resume_window: Duration,
    pub replay_bytes_per_channel: usize,
    /// Mac side: where links wait for their phone's resume. A new carrier
    /// that opens with a resume hands itself to the link it names.
    pub registry: Option<std::sync::Arc<ResumeRegistry>>,
}

impl Default for ReliableConfig {
    fn default() -> Self {
        Self {
            resume_window: RESUME_WINDOW,
            replay_bytes_per_channel: REPLAY_BYTES_PER_CHANNEL,
            registry: None,
        }
    }
}

impl std::fmt::Debug for ReliableConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReliableConfig")
            .field("resume_window", &self.resume_window)
            .field("replay_bytes_per_channel", &self.replay_bytes_per_channel)
            .field("registry", &self.registry.is_some())
            .finish()
    }
}

/// Mac side: the reliable links of one paired phone by token, so a new
/// carrier can resume one. Keep one per paired device: a token resumes only
/// a link of the device whose carrier presents it.
#[derive(Default)]
pub struct ResumeRegistry {
    links: Mutex<HashMap<Token, Weak<crate::link::Inner>>>,
}

impl ResumeRegistry {
    /// Registers a new link under `token` unless a live one has it already
    /// (a late carrier of a link another carrier opened).
    pub(crate) fn claim(&self, token: Token, link: Weak<crate::link::Inner>) -> bool {
        let mut links = self.links.lock().unwrap_or_else(PoisonError::into_inner);
        links.retain(|_, link| link.strong_count() > 0);
        if links.contains_key(&token) {
            return false;
        }
        links.insert(token, link);
        true
    }

    pub(crate) fn get(&self, token: &Token) -> Option<std::sync::Arc<crate::link::Inner>> {
        self.links.lock().unwrap_or_else(PoisonError::into_inner).get(token).and_then(Weak::upgrade)
    }

    pub(crate) fn remove(&self, token: &Token) {
        self.links.lock().unwrap_or_else(PoisonError::into_inner).remove(token);
    }

    /// Links registered and still alive.
    pub fn len(&self) -> usize {
        self.links
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .filter(|l| l.strong_count() > 0)
            .count()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl std::fmt::Debug for ResumeRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ResumeRegistry").field("links", &self.len()).finish()
    }
}

/// Whether a reliable link's carrier is up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Carrier {
    Up,
    /// Dropped; the link waits (up to the resume window) for a new one.
    /// Channels stay open; sends queue up to the replay bound.
    Down,
}

/// What a reliable link did, for tests and the connection log.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReliableStats {
    /// Carriers resumed.
    pub resumes: u64,
    /// Round trips the last resume took before data flowed (the phone's).
    pub resume_round_trips: u64,
    /// Frames and payload bytes this side replayed across resumes.
    pub replayed_frames: u64,
    pub replayed_bytes: u64,
    /// Unacked payload bytes this side held when its carriers dropped.
    pub unacked_at_drop_bytes: u64,
    /// Frames this side received twice and dropped.
    pub duplicates_dropped: u64,
    /// Unacked payload bytes held now.
    pub unacked_bytes: u64,
}

/// A channel frame as the log keeps it.
#[derive(Debug, Clone)]
pub(crate) struct Logged {
    pub kind: FrameType,
    pub payload: Bytes,
}

impl AsRef<[u8]> for Logged {
    fn as_ref(&self) -> &[u8] {
        &self.payload
    }
}

pub(crate) fn seq_payload(sequence: u64, kind: FrameType, payload: &[u8]) -> Bytes {
    let mut out = BytesMut::with_capacity(9 + payload.len());
    out.put_u64(sequence);
    out.put_u8(kind as u8);
    out.put_slice(payload);
    out.freeze()
}

pub(crate) fn open_seq(mut payload: Bytes) -> Option<(u64, FrameType, Bytes)> {
    if payload.len() < 9 {
        return None;
    }
    let sequence = payload.get_u64();
    let kind = FrameType::from_u8(payload.get_u8())?;
    // A parked Mac's deflated data is a channel frame like any other.
    matches!(
        kind,
        FrameType::Open | FrameType::Data | FrameType::DeflatedData | FrameType::Sequenced | FrameType::Close
    )
    .then_some((sequence, kind, payload))
}

pub(crate) fn ack_payload(acks: &[(u32, u64)]) -> Bytes {
    let mut out = BytesMut::with_capacity(4 + acks.len() * 12);
    out.put_u32(acks.len() as u32);
    for (channel, sequence) in acks {
        out.put_u32(*channel);
        out.put_u64(*sequence);
    }
    out.freeze()
}

fn read_pairs(payload: &mut Bytes) -> Option<Vec<(u32, u64)>> {
    if payload.len() < 4 {
        return None;
    }
    let count = payload.get_u32() as usize;
    if payload.len() != count.checked_mul(12)? {
        return None;
    }
    Some((0..count).map(|_| (payload.get_u32(), payload.get_u64())).collect())
}

pub(crate) fn open_ack(mut payload: Bytes) -> Option<Vec<(u32, u64)>> {
    read_pairs(&mut payload)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HelloKind {
    New = 0,
    Resume = 1,
    ResumeOk = 2,
    Refused = 3,
    /// A phone's resume of a link it never heard the Mac on: the carrier
    /// may have dropped before the Mac read the link's `New`. The Mac
    /// resumes the link when it has it, and opens it fresh when not.
    Reopen = 4,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Hello {
    pub kind: HelloKind,
    pub token: Token,
    pub max_peer_opened: u32,
    pub cursors: Vec<(u32, u64)>,
}

impl Hello {
    pub fn encode(&self) -> Bytes {
        let mut out = BytesMut::with_capacity(26 + self.cursors.len() * 12);
        out.put_u8(self.kind as u8);
        out.put_u8(VERSION);
        out.put_slice(&self.token);
        out.put_u32(self.max_peer_opened);
        out.put_slice(&ack_payload(&self.cursors));
        out.freeze()
    }

    pub fn decode(mut payload: Bytes) -> Option<Self> {
        if payload.len() < 2 + 16 + 4 + 4 {
            return None;
        }
        let kind = match payload.get_u8() {
            0 => HelloKind::New,
            1 => HelloKind::Resume,
            2 => HelloKind::ResumeOk,
            3 => HelloKind::Refused,
            4 => HelloKind::Reopen,
            _ => return None,
        };
        let _version = payload.get_u8();
        let mut token = [0u8; 16];
        payload.copy_to_slice(&mut token);
        let max_peer_opened = payload.get_u32();
        let cursors = read_pairs(&mut payload)?;
        Some(Self { kind, token, max_peer_opened, cursors })
    }
}

/// A bounded memory of channel ids.
#[derive(Debug, Default)]
pub(crate) struct Forgotten {
    ids: VecDeque<u32>,
}

impl Forgotten {
    pub fn insert(&mut self, channel: u32) {
        if self.ids.len() == FORGOTTEN {
            self.ids.pop_front();
        }
        self.ids.push_back(channel);
    }

    pub fn contains(&self, channel: u32) -> bool {
        self.ids.contains(&channel)
    }
}

pub(crate) fn new_token() -> Token {
    let mut token = [0u8; 16];
    if getrandom::fill(&mut token).is_err() {
        // No randomness: a token from the clock still names this link apart
        // from this phone's others (the registry is per device).
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        token.copy_from_slice(&nanos.to_be_bytes());
    }
    token
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_ack_and_seq_round_trip() {
        let hello = Hello {
            kind: HelloKind::Resume,
            token: [7; 16],
            max_peer_opened: 9,
            cursors: vec![(1, 4), (2, 0)],
        };
        assert_eq!(Hello::decode(hello.encode()), Some(hello));
        assert_eq!(open_ack(ack_payload(&[(3, 99)])), Some(vec![(3, 99)]));
        let (sequence, kind, payload) = open_seq(seq_payload(5, FrameType::Data, b"hi")).unwrap();
        assert_eq!((sequence, kind, &payload[..]), (5, FrameType::Data, &b"hi"[..]));
        assert!(open_seq(seq_payload(5, FrameType::Ping, b"")).is_none());
    }
}
