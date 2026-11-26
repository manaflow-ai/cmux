//! Datagram classes beside the link's streams (ultra-connectivity P4).
//!
//! A channel opened with a [`Delivery`] sends every message twice over: in
//! its stream, as a [`crate::frame::FrameType::Sequenced`] frame (reliable,
//! in order, the floor), and as datagrams on the link's datagram lane (sent
//! in the tunnel's interactive class, ahead of every stream, each one
//! [`COPIES`] times). Both carry the channel's message number, so the
//! receiver takes whichever copy arrives first and drops the other:
//!
//! - [`Delivery::Ordered`] (class 0, input): every message, in order. A
//!   message that arrives early waits for the ones before it, and a lost
//!   datagram costs nothing beyond the stream copy's own time.
//! - [`Delivery::Latest`] (class 1, screen state): only messages newer than
//!   the last one delivered. Each message is a whole state, so an older one
//!   that arrives late (its stream copy behind a retransmit) is dropped.
//!
//! On a lossy link the stream's TCP stalls a round trip or a retransmission
//! timeout for each lost segment, and everything behind it waits; the
//! datagram copies of the same messages do not wait for anything. A peer
//! that does not list [`CLASSES_LANE`] gets today's frames.

use std::collections::{BTreeMap, HashMap};

use bytes::{Bytes, BytesMut};
use serde::{Deserialize, Serialize};

/// The lane both sides list when they send and take class datagrams (with
/// [`crate::link::LIVENESS_LANE`]: they share its datagram port).
pub const CLASSES_LANE: &str = "classes";

/// The lane both sides list, beside [`CLASSES_LANE`], for screen datagrams
/// (kind 4, [`Delivery::Screen`]): a screen channel's messages go out in the
/// tunnel's screen class, ahead of every other datagram, each carrying the
/// base the peer last acknowledged, and the receiver acknowledges what it
/// delivers (kind 5). A peer that does not list it (an older build) gets
/// today's frames: `classes` datagrams only, or the stream alone.
pub const SCREEN_LANE: &str = "classes-screen-v1";

/// One side's class lanes: what it lists ([`ClassLanes::lanes`]) and what
/// two sides agree ([`ClassLanes::agreed`]). Both dial sides use it, so a
/// phone and a Mac of different builds always agree the same flags: a lane
/// only when both listed it, and [`SCREEN_LANE`] only with [`CLASSES_LANE`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ClassLanes {
    /// [`CLASSES_LANE`]: input and state channels also send datagrams.
    pub classes: bool,
    /// [`SCREEN_LANE`]: screen channels send screen datagrams.
    pub screen: bool,
}

impl ClassLanes {
    /// This side's offer; `screen` needs `classes`.
    pub fn offer(classes: bool, screen: bool) -> Self {
        Self { classes, screen: classes && screen }
    }

    /// The lanes this side lists, in order (none without `classes`).
    pub fn lanes(self) -> Vec<String> {
        let mut lanes = Vec::new();
        if self.classes {
            lanes.push(CLASSES_LANE.to_owned());
            if self.screen {
                lanes.push(SCREEN_LANE.to_owned());
            }
        }
        lanes
    }

    /// What both sides agree, from this side's offer and the lanes the peer
    /// listed. The answerer lists back exactly this, so the dialer, reading
    /// that list with its own offer, gets the same.
    pub fn agreed(self, peer_lanes: &[String]) -> Self {
        let listed = |name: &str| peer_lanes.iter().any(|lane| lane == name);
        let classes = self.classes && listed(CLASSES_LANE);
        Self { classes, screen: classes && self.screen && listed(SCREEN_LANE) }
    }
}

/// How a channel's messages are delivered when they also travel as datagrams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Delivery {
    /// Class 0: every message, in order (keystrokes).
    Ordered,
    /// Class 1: the newest message only (terminal screen state).
    Latest,
    /// Class 1 as screen datagrams (`SCREEN_LANE`): latest-wins like
    /// [`Delivery::Latest`], but each message names the base the sender knew
    /// the receiver held (see [`screen_message`]), is sent in the screen
    /// class, and is acknowledged. Delivered messages carry a header:
    /// [`ScreenMessage`].
    Screen,
}

/// The datagram kind of a class message fragment (liveness pings are 1, pongs 2).
pub(crate) const DATAGRAM_CLASS: u8 = 3;
/// The datagram kind of a class-1 (screen) message fragment, for
/// [`Delivery::Latest`] and [`Delivery::Screen`] channels alike: the same
/// header as [`DATAGRAM_CLASS`]. The tunnel sends it as
/// `cmux_wg::Priority::Screen`, repaired only above 1 % loss. A screen
/// channel's payload starts with its base (see [`screen_wire`]).
pub(crate) const DATAGRAM_SCREEN: u8 = 4;
/// A screen acknowledgement: kind, channel (4), the newest message number
/// delivered (8).
pub(crate) const DATAGRAM_SCREEN_ACK: u8 = 5;
pub(crate) const SCREEN_ACK_LEN: usize = 13;
/// A screen message's base when the sender holds none the peer acknowledged:
/// the message is a whole state (a keyframe).
pub const NO_BASE: u64 = u64::MAX;
/// What a screen message carries before its payload: its base (8 bytes).
const SCREEN_BASE: usize = 8;
/// What a delivered screen message carries before its payload: its number
/// and its base (8 bytes each).
pub const SCREEN_HEADER: usize = 16;
/// Kind, channel (4), message number (8), fragment index (2), fragment count (2).
pub(crate) const DATAGRAM_HEADER: usize = 17;
/// Payload bytes per fragment: under the 1232-byte datagram limit of the
/// 1280-byte tunnel MTU with room for the header.
pub(crate) const FRAGMENT: usize = 1180;
/// Messages longer than this go in the stream only.
pub(crate) const MIRROR_MAX: usize = 64 * 1024;
/// Each datagram is sent this many times: at 2 % random loss a message
/// of one datagram is lost to both copies 0.04 % of the time.
pub(crate) const COPIES: usize = 2;
/// Messages the receiver holds ahead of a gap (ordered), or datagram
/// assemblies in progress, before it drops new ones: the stream brings them.
const HELD: usize = 1024;
const ASSEMBLIES: usize = 64;

/// Fragment `message` (number `seq` of `channel`) into class datagrams.
pub(crate) fn datagrams(channel: u32, seq: u64, message: &[u8], delivery: Delivery) -> Vec<Vec<u8>> {
    let kind = match delivery {
        Delivery::Ordered => DATAGRAM_CLASS,
        Delivery::Latest | Delivery::Screen => DATAGRAM_SCREEN,
    };
    fragments_of(kind, channel, seq, message)
}

/// Fragment screen `message` into kind-4 datagrams.
pub(crate) fn screen_datagrams(channel: u32, seq: u64, message: &[u8]) -> Vec<Vec<u8>> {
    fragments_of(DATAGRAM_SCREEN, channel, seq, message)
}

fn fragments_of(kind: u8, channel: u32, seq: u64, message: &[u8]) -> Vec<Vec<u8>> {
    let count = message.len().div_ceil(FRAGMENT).max(1);
    let Ok(count16) = u16::try_from(count) else { return Vec::new() };
    (0..count)
        .map(|index| {
            let start = index * FRAGMENT;
            let part = &message[start.min(message.len())..(start + FRAGMENT).min(message.len())];
            let mut datagram = Vec::with_capacity(DATAGRAM_HEADER + part.len());
            datagram.push(kind);
            datagram.extend_from_slice(&channel.to_be_bytes());
            datagram.extend_from_slice(&seq.to_be_bytes());
            datagram.extend_from_slice(&(index as u16).to_be_bytes());
            datagram.extend_from_slice(&count16.to_be_bytes());
            datagram.extend_from_slice(part);
            datagram
        })
        .collect()
}

/// One class datagram: channel, message number, fragment index and count, payload.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Fragment {
    /// [`DATAGRAM_CLASS`] or [`DATAGRAM_SCREEN`].
    pub kind: u8,
    pub channel: u32,
    pub seq: u64,
    pub index: u16,
    pub count: u16,
    pub payload: Bytes,
}

pub(crate) fn parse_datagram(datagram: &[u8]) -> Option<Fragment> {
    if datagram.len() < DATAGRAM_HEADER || !matches!(datagram[0], DATAGRAM_CLASS | DATAGRAM_SCREEN) {
        return None;
    }
    let channel = u32::from_be_bytes(datagram[1..5].try_into().ok()?);
    let seq = u64::from_be_bytes(datagram[5..13].try_into().ok()?);
    let index = u16::from_be_bytes(datagram[13..15].try_into().ok()?);
    let count = u16::from_be_bytes(datagram[15..17].try_into().ok()?);
    if count == 0 || index >= count || usize::from(count) * FRAGMENT > MIRROR_MAX + FRAGMENT {
        return None;
    }
    Some(Fragment {
        kind: datagram[0],
        channel,
        seq,
        index,
        count,
        payload: Bytes::copy_from_slice(&datagram[DATAGRAM_HEADER..]),
    })
}

/// A [`Delivery::Screen`] channel's state shared by its sender and its
/// route: the newest message the peer acknowledged, and how many copies of
/// each datagram to send.
#[derive(Debug)]
pub(crate) struct ScreenState {
    /// Newest acknowledged message number plus one (0: none).
    acked: std::sync::atomic::AtomicU64,
    copies: std::sync::atomic::AtomicUsize,
}

impl ScreenState {
    pub(crate) fn new() -> Self {
        Self { acked: 0.into(), copies: COPIES.into() }
    }

    pub(crate) fn acknowledge(&self, seq: u64) {
        self.acked.fetch_max(seq.saturating_add(1), std::sync::atomic::Ordering::Relaxed);
    }

    pub(crate) fn base(&self) -> Option<u64> {
        self.acked.load(std::sync::atomic::Ordering::Relaxed).checked_sub(1)
    }

    pub(crate) fn copies(&self) -> usize {
        self.copies.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub(crate) fn set_surface(&self, visible: bool, attending: bool) {
        let copies = if attending { COPIES } else { usize::from(visible) };
        self.copies.store(copies, std::sync::atomic::Ordering::Relaxed);
    }
}

/// A screen acknowledgement datagram for message `seq` of `channel`.
pub(crate) fn screen_ack(channel: u32, seq: u64) -> Vec<u8> {
    let mut datagram = Vec::with_capacity(SCREEN_ACK_LEN);
    datagram.push(DATAGRAM_SCREEN_ACK);
    datagram.extend_from_slice(&channel.to_be_bytes());
    datagram.extend_from_slice(&seq.to_be_bytes());
    datagram
}

pub(crate) fn parse_screen_ack(datagram: &[u8]) -> Option<(u32, u64)> {
    if datagram.len() != SCREEN_ACK_LEN || datagram[0] != DATAGRAM_SCREEN_ACK {
        return None;
    }
    Some((
        u32::from_be_bytes(datagram[1..5].try_into().ok()?),
        u64::from_be_bytes(datagram[5..13].try_into().ok()?),
    ))
}

/// What a sender puts on the wire for a screen message: `base` (or
/// [`NO_BASE`]) and the payload.
pub(crate) fn screen_wire(base: u64, payload: &[u8]) -> Bytes {
    let mut message = BytesMut::with_capacity(SCREEN_BASE + payload.len());
    message.extend_from_slice(&base.to_be_bytes());
    message.extend_from_slice(payload);
    message.freeze()
}

/// A delivered screen message: its number, the base the sender built it
/// against (`None`: a whole state), and the payload. The receiver applies a
/// payload built on a base only if it still holds that state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenMessage {
    pub seq: u64,
    pub base: Option<u64>,
    pub payload: Bytes,
}

/// Read a message delivered on a [`Delivery::Screen`] channel.
pub fn screen_message(delivered: &Bytes) -> Option<ScreenMessage> {
    if delivered.len() < SCREEN_HEADER {
        return None;
    }
    let seq = u64::from_be_bytes(delivered[..8].try_into().ok()?);
    let base = u64::from_be_bytes(delivered[8..16].try_into().ok()?);
    Some(ScreenMessage {
        seq,
        base: (base != NO_BASE).then_some(base),
        payload: delivered.slice(SCREEN_HEADER..),
    })
}

/// A sequenced stream frame's payload: message number, flags (bit 0: the
/// message's last chunk), chunk.
pub(crate) const SEQUENCED_HEADER: usize = 9;
const LAST: u8 = 1;

pub(crate) fn sequenced_payload(seq: u64, last: bool, chunk: &[u8]) -> Bytes {
    let mut payload = BytesMut::with_capacity(SEQUENCED_HEADER + chunk.len());
    payload.extend_from_slice(&seq.to_be_bytes());
    payload.extend_from_slice(&[if last { LAST } else { 0 }]);
    payload.extend_from_slice(chunk);
    payload.freeze()
}

pub(crate) fn parse_sequenced(mut payload: Bytes) -> Option<(u64, bool, Bytes)> {
    if payload.len() < SEQUENCED_HEADER {
        return None;
    }
    let seq = u64::from_be_bytes(payload[..8].try_into().ok()?);
    let last = payload[8] & LAST != 0;
    Some((seq, last, payload.split_off(SEQUENCED_HEADER)))
}

struct Assembly {
    parts: Vec<Option<Bytes>>,
    missing: usize,
}

/// A channel's receiving side: puts stream chunks and datagram fragments
/// back into messages and decides which to deliver.
pub(crate) struct Sequencer {
    delivery: Delivery,
    /// The next message number to deliver (ordered) or the lowest one still
    /// worth delivering (latest).
    next: u64,
    /// Stream chunks of a message whose last chunk has not arrived.
    partial: HashMap<u64, BytesMut>,
    /// Datagram fragments of messages not yet whole.
    assemblies: BTreeMap<u64, Assembly>,
    /// Whole messages waiting for the ones before them (ordered).
    held: BTreeMap<u64, Bytes>,
    /// Messages taken from datagrams before their stream copy.
    pub(crate) won_by_datagram: u64,
}

impl Sequencer {
    pub(crate) fn new(delivery: Delivery) -> Self {
        Self {
            delivery,
            next: 0,
            partial: HashMap::new(),
            assemblies: BTreeMap::new(),
            held: BTreeMap::new(),
            won_by_datagram: 0,
        }
    }

    /// A chunk of message `seq` from the stream: the messages to deliver now.
    pub(crate) fn stream_chunk(&mut self, seq: u64, last: bool, chunk: Bytes) -> Vec<Bytes> {
        if !last {
            if seq >= self.next {
                self.partial.entry(seq).or_default().extend_from_slice(&chunk);
            }
            return Vec::new();
        }
        let message = match self.partial.remove(&seq) {
            Some(mut head) => {
                head.extend_from_slice(&chunk);
                head.freeze()
            }
            None => chunk,
        };
        self.complete(seq, message)
    }

    /// A datagram fragment: the messages to deliver now.
    pub(crate) fn fragment(&mut self, fragment: Fragment) -> Vec<Bytes> {
        let Fragment { seq, index, count, payload, .. } = fragment;
        if seq < self.next || self.held.contains_key(&seq) {
            return Vec::new();
        }
        if count == 1 {
            return self.complete_from_datagram(seq, payload);
        }
        if !self.assemblies.contains_key(&seq) {
            if self.assemblies.len() >= ASSEMBLIES {
                // Keep the oldest: ordered delivery waits on it.
                return Vec::new();
            }
            let parts = vec![None; usize::from(count)];
            self.assemblies.insert(seq, Assembly { parts, missing: usize::from(count) });
        }
        let assembly = self.assemblies.get_mut(&seq).expect("inserted above");
        let Some(slot) = assembly.parts.get_mut(usize::from(index)) else { return Vec::new() };
        if slot.is_some() {
            return Vec::new();
        }
        *slot = Some(payload);
        assembly.missing -= 1;
        if assembly.missing > 0 {
            return Vec::new();
        }
        let assembly = self.assemblies.remove(&seq).expect("present");
        let mut message = BytesMut::new();
        for part in assembly.parts.into_iter().flatten() {
            message.extend_from_slice(&part);
        }
        self.complete_from_datagram(seq, message.freeze())
    }

    fn complete_from_datagram(&mut self, seq: u64, message: Bytes) -> Vec<Bytes> {
        let delivered = self.complete(seq, message);
        if !delivered.is_empty() || self.held.contains_key(&seq) {
            self.won_by_datagram += 1;
        }
        delivered
    }

    fn complete(&mut self, seq: u64, message: Bytes) -> Vec<Bytes> {
        if seq < self.next {
            return Vec::new();
        }
        let out = match self.delivery {
            Delivery::Latest => {
                self.next = seq + 1;
                vec![message]
            }
            Delivery::Screen => {
                self.next = seq + 1;
                // A message too short to hold its base is not a screen message.
                if message.len() < SCREEN_BASE {
                    Vec::new()
                } else {
                    let mut numbered = BytesMut::with_capacity(8 + message.len());
                    numbered.extend_from_slice(&seq.to_be_bytes());
                    numbered.extend_from_slice(&message);
                    vec![numbered.freeze()]
                }
            }
            Delivery::Ordered if seq == self.next => {
                let mut out = vec![message];
                self.next += 1;
                while let Some(message) = self.held.remove(&self.next) {
                    out.push(message);
                    self.next += 1;
                }
                out
            }
            Delivery::Ordered => {
                if self.held.len() < HELD {
                    self.held.insert(seq, message);
                }
                Vec::new()
            }
        };
        let next = self.next;
        self.assemblies.retain(|&seq, _| seq >= next);
        self.partial.retain(|&seq, _| seq >= next);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fragments(channel: u32, seq: u64, message: &[u8]) -> Vec<Fragment> {
        datagrams(channel, seq, message, Delivery::Latest)
            .iter()
            .map(|d| parse_datagram(d).unwrap())
            .collect()
    }

    #[test]
    fn datagrams_round_trip_and_fragment() {
        let message: Vec<u8> = (0..3500u32).map(|i| i as u8).collect();
        let parts = datagrams(7, 9, &message, Delivery::Latest);
        assert!(parts.iter().all(|d| d[0] == DATAGRAM_SCREEN));
        assert!(datagrams(7, 9, &message, Delivery::Ordered).iter().all(|d| d[0] == DATAGRAM_CLASS));
        assert_eq!(parts.len(), 3);
        assert!(parts.iter().all(|d| d.len() <= DATAGRAM_HEADER + FRAGMENT));
        let mut sequencer = Sequencer::new(Delivery::Latest);
        let mut out = Vec::new();
        for fragment in fragments(7, 9, &message).into_iter().rev() {
            out.extend(sequencer.fragment(fragment));
        }
        assert_eq!(out, vec![Bytes::from(message)]);
        assert!(parse_datagram(&[DATAGRAM_CLASS, 0, 0]).is_none());
        assert!(parse_datagram(&[1; 10]).is_none());
    }

    #[test]
    fn ordered_takes_the_first_copy_waits_for_gaps_and_drops_duplicates() {
        let mut sequencer = Sequencer::new(Delivery::Ordered);
        // Message 1's datagram arrives before message 0: held.
        assert!(sequencer.fragment(fragments(1, 1, b"b").remove(0)).is_empty());
        // Message 0 from the stream releases both.
        assert_eq!(
            sequencer.stream_chunk(0, true, Bytes::from_static(b"a")),
            vec![Bytes::from_static(b"a"), Bytes::from_static(b"b")]
        );
        // The late copies are dropped.
        assert!(sequencer.stream_chunk(1, true, Bytes::from_static(b"b")).is_empty());
        assert!(sequencer.fragment(fragments(1, 0, b"a").remove(0)).is_empty());
        // A chunked stream message.
        assert!(sequencer.stream_chunk(2, false, Bytes::from_static(b"he")).is_empty());
        assert_eq!(
            sequencer.stream_chunk(2, true, Bytes::from_static(b"llo")),
            vec![Bytes::from_static(b"hello")]
        );
        assert_eq!(sequencer.won_by_datagram, 1);
    }

    #[test]
    fn latest_skips_older_messages() {
        let mut sequencer = Sequencer::new(Delivery::Latest);
        assert_eq!(sequencer.fragment(fragments(1, 3, b"s3").remove(0)), vec![Bytes::from_static(b"s3")]);
        // Older states, from either copy, are dropped.
        assert!(sequencer.stream_chunk(1, true, Bytes::from_static(b"s1")).is_empty());
        assert!(sequencer.stream_chunk(3, true, Bytes::from_static(b"s3")).is_empty());
        assert_eq!(
            sequencer.stream_chunk(4, true, Bytes::from_static(b"s4")),
            vec![Bytes::from_static(b"s4")]
        );
    }

    #[test]
    fn sequenced_payload_round_trips() {
        let payload = sequenced_payload(42, true, b"xyz");
        assert_eq!(parse_sequenced(payload), Some((42, true, Bytes::from_static(b"xyz"))));
        assert_eq!(parse_sequenced(Bytes::from_static(b"short")), None);
    }
}
