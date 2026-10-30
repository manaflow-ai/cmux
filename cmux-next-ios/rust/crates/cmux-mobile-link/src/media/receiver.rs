//! The phone's half of the media core: RTP in, whole frames out, PLI back.
//! webrtc-rs's interceptors send the NACKs (generator) and the TWCC
//! feedback (receiver) on the same packets before they reach this core.
//!
//! What webrtc-rs has no fitting part for is the frame buffer: its
//! `SampleBuilder` releases a frame only when a packet of the *next* frame
//! arrives (one frame interval late, and a still page's last frame never),
//! and it hands on frames whose reference was lost. So this core releases a
//! frame the moment its marker packet completes it, in order, with no
//! playout delay. A gap holds later frames only while a NACK can still
//! recover it ([`ReceiverCore::deadline_us`]); then the frame is given up,
//! the Mac is asked for a keyframe (PLI), and the next keyframe is released
//! however much was skipped. The decoder never sees a frame whose reference
//! is missing.

use std::collections::BTreeMap;
use std::sync::Arc;

use bytes::Bytes;
use tokio::sync::{mpsc, watch};
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtp::packet::Packet;

use super::{InInner, MediaCarrier, ReceiverStats, RtcpPackets, h264};

#[derive(Debug, Clone, Copy)]
pub struct ReceiverConfig {
    /// SSRC of this side's RTCP.
    pub ssrc: u32,
    /// Bounds of the give-up deadline; between them it follows the link's
    /// round trip (a NACK and its resend need one, plus the generator's
    /// interval).
    pub min_deadline_us: u64,
    pub max_deadline_us: u64,
    /// The NACK generator's interval (`crate::dial::webrtc`).
    pub nack_interval_us: u64,
    /// Time between PLIs while waiting for a keyframe.
    pub pli_interval_us: u64,
}

impl Default for ReceiverConfig {
    fn default() -> Self {
        Self {
            ssrc: 0x636e_7872, // "cnxr"
            min_deadline_us: 80_000,
            max_deadline_us: 400_000,
            nack_interval_us: 20_000,
            pli_interval_us: 300_000,
        }
    }
}

/// A complete, decodable frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceivedFrame {
    /// H.264 Annex-B access unit.
    pub access_unit: Vec<u8>,
    pub rtp_timestamp: u32,
    pub keyframe: bool,
    pub packets: u16,
    /// When its last packet arrived (the core's clock).
    pub complete_us: u64,
    /// Some of its packets came back after a NACK.
    pub recovered: bool,
    /// The carrier it came on (set by the lane; None from a bare core).
    pub carrier: Option<super::CarrierKind>,
}

#[derive(Debug, Clone)]
struct Slot {
    payload: Bytes,
    timestamp: u32,
    marker: bool,
    arrival_us: u64,
    recovered: bool,
}

/// Most packets held (about 2 MB).
const MAX_PACKETS: usize = 2048;
/// The largest forward jump in sequence numbers a NACK may still fill; a
/// larger one restarts at a keyframe.
const MAX_GAP: u64 = 512;

#[derive(Debug)]
pub struct ReceiverCore {
    config: ReceiverConfig,
    media_ssrc: u32,
    packets: BTreeMap<u64, Slot>,
    highest: Option<u64>,
    /// The first sequence number of the next frame to release; `None` while
    /// waiting for a keyframe.
    next_seq: Option<u64>,
    blocked_since: Option<u64>,
    /// The next frame is incomplete with nothing missing before its newest
    /// packet (its tail is still on the way, or lost): it waits from the
    /// newest arrival.
    tail_since: Option<u64>,
    last_arrival_us: u64,
    last_pli_us: Option<u64>,
    pli_wanted: bool,
    /// Send one PLI on the next poll without dropping what is buffered.
    pli_now: bool,
    rtt_us: Option<u64>,
    stats: ReceiverStats,
}

impl ReceiverCore {
    pub fn new(config: ReceiverConfig) -> Self {
        Self {
            config,
            media_ssrc: 0,
            packets: BTreeMap::new(),
            highest: None,
            next_seq: None,
            blocked_since: None,
            tail_since: None,
            last_arrival_us: 0,
            last_pli_us: None,
            pli_wanted: true,
            pli_now: false,
            rtt_us: None,
            stats: ReceiverStats::default(),
        }
    }

    pub fn stats(&self) -> ReceiverStats {
        self.stats
    }

    /// The link's round trip (its pings), which bounds a NACK's recovery.
    pub fn set_rtt(&mut self, rtt_us: u64) {
        self.rtt_us = Some(rtt_us);
    }

    /// How long a gap may hold later frames before they are given up: two
    /// NACK rounds.
    pub fn deadline_us(&self) -> u64 {
        let adaptive = self
            .rtt_us
            .map_or(self.config.max_deadline_us / 2, |rtt| 2 * (rtt + self.config.nack_interval_us) + 20_000);
        adaptive.clamp(self.config.min_deadline_us, self.config.max_deadline_us)
    }

    /// The decoder lost its state: skip to the next keyframe and ask for one.
    pub fn request_keyframe(&mut self) {
        self.next_seq = None;
        self.blocked_since = None;
        self.tail_since = None;
        self.pli_wanted = true;
        self.last_pli_us = None;
    }

    /// The path changed under the lane (a WireGuard roam): ask the Mac for a
    /// keyframe now, and keep releasing whatever completes meanwhile. A gap
    /// the roam left still waits for its NACK until the deadline.
    pub fn path_changed(&mut self) {
        self.pli_now = true;
    }

    fn unwrap_seq(&self, seq: u16) -> u64 {
        let Some(highest) = self.highest else { return 1 << 32 | u64::from(seq) };
        let base = highest & !0xffff;
        let candidates = [base.wrapping_sub(0x1_0000), base, base + 0x1_0000];
        candidates
            .into_iter()
            .map(|b| b | u64::from(seq))
            .min_by_key(|c| c.abs_diff(highest))
            .unwrap_or(base | u64::from(seq))
    }

    /// Records one RTP packet that arrived at `now_us`.
    pub fn push(&mut self, packet: Packet, now_us: u64) {
        self.media_ssrc = packet.header.ssrc;
        self.stats.packets += 1;
        self.stats.bytes += packet.payload.len() as u64;
        let seq = self.unwrap_seq(packet.header.sequence_number);
        if self.next_seq.is_some_and(|next| seq < next) || self.packets.contains_key(&seq) {
            return;
        }
        // Arrived after a later packet: a NACK's resend (or reordering).
        let recovered = self.highest.is_some_and(|h| seq < h);
        if recovered {
            self.stats.packets_recovered += 1;
        }
        if self.highest.is_some_and(|h| seq > h + MAX_GAP) {
            // A jump this large cannot be NACKed back.
            self.request_keyframe();
        }
        if self.highest.is_none_or(|h| seq > h) {
            self.highest = Some(seq);
        }
        self.last_arrival_us = now_us;
        self.packets.insert(
            seq,
            Slot {
                payload: packet.payload,
                timestamp: packet.header.timestamp,
                marker: packet.header.marker,
                arrival_us: now_us,
                recovered,
            },
        );
        while self.packets.len() > MAX_PACKETS {
            self.packets.pop_first();
        }
    }

    /// The frame starting at `start`: (marker sequence number, frame) when
    /// every packet is here, `None` when one is missing.
    fn assemble(&self, start: u64) -> Option<(u64, ReceivedFrame)> {
        let first = self.packets.get(&start)?;
        let mut payloads = Vec::new();
        let mut seq = start;
        let mut complete_us = 0;
        let mut recovered = false;
        loop {
            let slot = self.packets.get(&seq)?;
            if slot.timestamp != first.timestamp {
                // The frame ended without a marker (never sent so); end here.
                seq -= 1;
                break;
            }
            payloads.push(&slot.payload);
            complete_us = complete_us.max(slot.arrival_us);
            recovered |= slot.recovered;
            if slot.marker {
                break;
            }
            seq += 1;
        }
        let access_unit = h264::depacketize(payloads.iter().copied()).unwrap_or_default();
        let keyframe = h264::is_keyframe(&access_unit);
        Some((
            seq,
            ReceivedFrame {
                access_unit,
                rtp_timestamp: first.timestamp,
                keyframe,
                packets: payloads.len() as u16,
                complete_us,
                recovered,
                carrier: None,
            },
        ))
    }

    /// A held packet that begins a keyframe (the parameter sets in a STAP-A,
    /// or an SPS on its own), from the oldest.
    fn keyframe_starts(&self) -> Vec<u64> {
        self.packets
            .iter()
            .filter(|(_, slot)| {
                let nal = slot.payload.first().map_or(0, |b| b & 0x1f);
                nal == 7 || (nal == 24 && slot.payload.get(3).is_some_and(|b| b & 0x1f == 7))
            })
            .map(|(seq, _)| *seq)
            .collect()
    }

    fn release_through(&mut self, marker: u64) {
        self.next_seq = Some(marker + 1);
        while self.packets.first_key_value().is_some_and(|(seq, _)| *seq <= marker) {
            self.packets.pop_first();
        }
        self.blocked_since = None;
        self.tail_since = None;
    }

    /// Releases what is complete and returns the RTCP to send now.
    pub fn poll(&mut self, now_us: u64) -> (Vec<ReceivedFrame>, RtcpPackets) {
        let mut frames = Vec::new();
        loop {
            match self.next_seq {
                Some(next) => match self.assemble(next) {
                    Some((marker, frame)) => {
                        self.release_through(marker);
                        if frame.access_unit.is_empty() {
                            self.stats.frames_dropped += 1;
                            self.request_keyframe();
                            continue;
                        }
                        self.release(frame, &mut frames);
                    }
                    None => {
                        let Some(highest) = self.highest.filter(|h| *h >= next) else {
                            self.blocked_since = None;
                            self.tail_since = None;
                            break;
                        };
                        // A hole (a missing packet before the newest one)
                        // waits from when it was found, however much else
                        // arrives. A frame with nothing missing but its tail
                        // waits from the newest arrival: a large keyframe
                        // still arriving on a slow path is never given up,
                        // and a lost tail (the marker, with nothing after it
                        // for the NACK generator to notice) still is.
                        let hole = (self.packets.range(next..=highest).count() as u64) < highest - next + 1;
                        let since = if hole {
                            self.tail_since = None;
                            *self.blocked_since.get_or_insert(now_us)
                        } else {
                            self.blocked_since = None;
                            *self.tail_since.insert(self.last_arrival_us)
                        };
                        if now_us.saturating_sub(since) < self.deadline_us() {
                            break;
                        }
                        // Give the gap up: restart at a keyframe.
                        tracing::debug!(
                            next,
                            highest,
                            hole,
                            "media receiver: gave a gap up; asking for a keyframe"
                        );
                        self.stats.frames_dropped += 1;
                        self.request_keyframe();
                    }
                },
                None => {
                    let mut released = false;
                    for start in self.keyframe_starts() {
                        if let Some((marker, frame)) = self.assemble(start)
                            && frame.keyframe
                        {
                            let skipped = self.packets.range(..start).count();
                            if skipped > 0 {
                                self.stats.frames_dropped += 1;
                            }
                            self.release_through(marker);
                            self.release(frame, &mut frames);
                            released = true;
                            break;
                        }
                    }
                    if !released {
                        break;
                    }
                }
            }
        }
        let mut rtcp: RtcpPackets = Vec::new();
        let pli_due =
            |last: Option<u64>, interval: u64| last.is_none_or(|t| now_us.saturating_sub(t) >= interval);
        if std::mem::take(&mut self.pli_now)
            && self.media_ssrc != 0
            && pli_due(self.last_pli_us, self.config.pli_interval_us)
        {
            self.last_pli_us = Some(now_us);
            self.stats.plis_sent += 1;
            rtcp.push(Box::new(PictureLossIndication {
                sender_ssrc: self.config.ssrc,
                media_ssrc: self.media_ssrc,
            }));
        } else if self.next_seq.is_none() {
            // Nothing below the newest keyframe start can be used.
            if let Some(&start) = self.keyframe_starts().last() {
                while self.packets.first_key_value().is_some_and(|(seq, _)| *seq < start) {
                    self.packets.pop_first();
                }
            }
            let due =
                self.last_pli_us.is_none_or(|t| now_us.saturating_sub(t) >= self.config.pli_interval_us);
            if self.pli_wanted && due && self.media_ssrc != 0 {
                self.last_pli_us = Some(now_us);
                self.stats.plis_sent += 1;
                rtcp.push(Box::new(PictureLossIndication {
                    sender_ssrc: self.config.ssrc,
                    media_ssrc: self.media_ssrc,
                }));
            }
        }
        (frames, rtcp)
    }

    fn release(&mut self, frame: ReceivedFrame, out: &mut Vec<ReceivedFrame>) {
        if frame.keyframe {
            self.pli_wanted = false;
            self.stats.keyframes += 1;
        }
        self.stats.frames += 1;
        out.push(frame);
    }

    /// When [`Self::poll`] has work next.
    pub fn next_deadline_us(&self, now_us: u64) -> u64 {
        let mut next = now_us + 1_000_000;
        for since in [self.blocked_since, self.tail_since].into_iter().flatten() {
            next = next.min(since + self.deadline_us());
        }
        if self.next_seq.is_none() && self.pli_wanted {
            next = next.min(self.last_pli_us.map_or(now_us, |t| t + self.config.pli_interval_us));
        }
        next.max(now_us)
    }
}

/// Drives a [`ReceiverCore`] on `carrier` until the carrier ends.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run(
    carrier: Arc<dyn MediaCarrier>,
    config: ReceiverConfig,
    inner: Arc<InInner>,
    source: u64,
    mut keyframes: mpsc::UnboundedReceiver<()>,
    stats: watch::Sender<ReceiverStats>,
    rtt: Option<watch::Receiver<Option<std::time::Duration>>>,
    mut closed: Option<watch::Receiver<Option<String>>>,
) {
    let epoch = std::time::Instant::now();
    let mut core = ReceiverCore::new(config);
    let mut overflows = 0u64;
    let mut path = carrier.path_changes();
    loop {
        if let Some(rtt) = rtt.as_ref().and_then(|r| *r.borrow()) {
            core.set_rtt(u64::try_from(rtt.as_micros()).unwrap_or(u64::MAX));
        }
        let now = super::micros_since(epoch);
        let wake = core.next_deadline_us(now);
        let sleep = tokio::time::sleep(std::time::Duration::from_micros(wake.saturating_sub(now)));
        tokio::select! {
            () = super::link_closed(&mut closed) => break,
            packet = carrier.recv_rtp() => {
                let Some(packet) = packet else { break };
                core.push(packet, super::micros_since(epoch));
            }
            request = keyframes.recv() => {
                if request.is_none() {
                    break;
                }
                core.request_keyframe();
            }
            () = sleep => {}
            changed = async {
                match path.as_mut() {
                    Some(path) => path.changed().await.is_ok(),
                    None => std::future::pending().await,
                }
            } => {
                if changed {
                    core.path_changed();
                } else {
                    path = None;
                }
            }
        }
        let (frames, rtcp) = core.poll(super::micros_since(epoch));
        if !frames.is_empty() {
            let mut subscribers = inner.subscribers.lock().await;
            let mut overflow = false;
            for mut frame in frames {
                frame.carrier = Some(carrier.kind());
                // Another source carries the video now (the Mac moves only
                // at a keyframe): this source's late frames do not pass.
                if !inner.admit(source, &frame) {
                    continue;
                }
                subscribers.retain(|tx| match tx.try_send(frame.clone()) {
                    Ok(()) => true,
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        overflow = true;
                        true
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => false,
                });
            }
            if overflow {
                // The consumer fell behind; restart its decoder at a keyframe.
                overflows += 1;
                if overflows.is_power_of_two() {
                    tracing::info!(
                        source,
                        overflows,
                        "media lane: a viewer is not reading its frames; asking for a keyframe"
                    );
                }
                core.request_keyframe();
            }
        }
        if !rtcp.is_empty() && carrier.send_rtcp(rtcp).await.is_err() {
            break;
        }
        stats.send_replace(core.stats());
    }
    if inner.source_ended(source) {
        inner.subscribers.lock().await.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::OutgoingFrame;
    use crate::media::h264::tests::access_unit;
    use crate::media::sender::{SenderConfig, SenderCore};

    fn frames(sender: &mut SenderCore, n: usize, start: u64) -> Vec<Vec<Packet>> {
        (0..n as u64)
            .map(|i| {
                let t = start + i;
                sender.frame(
                    &OutgoingFrame {
                        access_unit: access_unit(t == 0, 2500 + (t as usize % 7) * 100, (t % 200) as u8 + 2),
                        capture_us: t * 16_667,
                    },
                    t * 16_667,
                )
            })
            .collect()
    }

    fn has_pli(rtcp: &RtcpPackets) -> bool {
        rtcp.iter().any(|p| p.as_any().downcast_ref::<PictureLossIndication>().is_some())
    }

    #[test]
    fn frames_round_trip_in_order_with_no_buffering() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        let sent = frames(&mut sender, 10, 0);
        let mut got = Vec::new();
        for (i, frame) in sent.iter().enumerate() {
            for p in frame {
                receiver.push(p.clone(), i as u64 * 16_667);
            }
            // The frame is out on the same poll its last packet arrived.
            let (out, _) = receiver.poll(i as u64 * 16_667);
            assert_eq!(out.len(), 1, "frame {i}");
            got.extend(out);
        }
        assert!(got[0].keyframe && !got[1].keyframe);
        assert_eq!(got[3].access_unit, access_unit(false, 2800, 5).to_vec());
        assert_eq!(got[1].rtp_timestamp, crate::media::rtp_timestamp(16_667));
        assert_eq!(receiver.stats().frames_dropped, 0);
    }

    #[test]
    fn a_resent_packet_completes_its_frame_and_the_held_frames_follow_in_order() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        receiver.set_rtt(20_000);
        let sent = frames(&mut sender, 3, 0);
        let lost = sent[1][1].clone();
        let mut now = 0;
        for frame in &sent {
            for p in frame {
                if p.header.sequence_number != lost.header.sequence_number {
                    receiver.push(p.clone(), now);
                }
            }
            now += 1_000;
        }
        let (out, _) = receiver.poll(now);
        // Frame 0 is out; frame 2 is complete but waits behind frame 1.
        assert_eq!(out.len(), 1);
        now += 30_000;
        assert!(receiver.poll(now).0.is_empty());
        // The NACK's resend arrives inside the deadline (2 x (20 + 20) + 20 ms).
        receiver.push(lost, now);
        let (out, rtcp) = receiver.poll(now);
        assert_eq!(out.len(), 2);
        assert!(out[0].recovered && !out[1].recovered);
        assert!(!has_pli(&rtcp));
        assert_eq!(receiver.stats().packets_recovered, 1);
        assert_eq!(receiver.stats().frames_dropped, 0);
    }

    #[test]
    fn reordered_packets_inside_a_frame_need_no_resend() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        let mut sent = frames(&mut sender, 2, 0);
        sent[0].reverse();
        for p in sent.iter().flatten() {
            receiver.push(p.clone(), 0);
        }
        let (out, _) = receiver.poll(0);
        assert_eq!(out.len(), 2);
        assert!(out[0].keyframe);
    }

    #[test]
    fn an_unrecoverable_gap_is_dropped_with_a_pli_and_the_next_keyframe_resumes() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        let mut sent = frames(&mut sender, 4, 0);
        let mut now = 0;
        for (i, frame) in sent.iter().enumerate() {
            for (j, p) in frame.iter().enumerate() {
                if !(i == 1 && j == 0) {
                    receiver.push(p.clone(), now);
                }
            }
        }
        let (out, _) = receiver.poll(now);
        assert_eq!(out.len(), 1);
        // NACKs go unanswered past the deadline.
        let mut pli = false;
        for _ in 0..40 {
            now += 20_000;
            let (out, rtcp) = receiver.poll(now);
            assert!(out.is_empty(), "no P-frame after a lost reference");
            pli |= has_pli(&rtcp);
        }
        assert!(pli);
        assert!(receiver.stats().frames_dropped >= 1);
        // The Mac's answer: a keyframe; later P-frames follow it.
        sent.clear();
        let key =
            sender.frame(&OutgoingFrame { access_unit: access_unit(true, 9000, 11), capture_us: now }, now);
        let next = sender.frame(
            &OutgoingFrame { access_unit: access_unit(false, 900, 12), capture_us: now + 16_667 },
            now,
        );
        for p in key.iter().chain(&next) {
            receiver.push(p.clone(), now);
        }
        let (out, _) = receiver.poll(now);
        assert_eq!(out.len(), 2);
        assert!(out[0].keyframe && !out[1].keyframe);
    }

    /// A 100 kB keyframe on a 2.5 Mbit/s path takes about 320 ms to arrive,
    /// longer than the give-up deadline: with no packet missing it is not a
    /// loss, and the frame is released whole when its marker arrives.
    #[test]
    fn a_frame_still_arriving_is_not_given_up() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        receiver.set_rtt(10_000);
        // A running stream: a keyframe and a P-frame are out.
        for p in frames(&mut sender, 2, 0).iter().flatten() {
            receiver.push(p.clone(), 0);
        }
        assert_eq!(receiver.poll(0).0.len(), 2);
        let start = 33_334;
        let key = sender
            .frame(&OutgoingFrame { access_unit: access_unit(true, 100_000, 9), capture_us: start }, start);
        assert!(key.len() > 80);
        let spacing = 330_000 / key.len() as u64;
        let mut now = start;
        for p in &key {
            receiver.push(p.clone(), now);
            let (out, rtcp) = receiver.poll(now);
            if !p.header.marker {
                assert!(out.is_empty());
                assert!(!has_pli(&rtcp), "a PLI at {now} us while the frame was still arriving");
            } else {
                assert_eq!(out.len(), 1);
                assert!(out[0].keyframe);
            }
            now += spacing;
        }
        assert!(now - start > receiver.deadline_us());
        assert_eq!(receiver.stats().frames_dropped, 0);
    }

    /// The last packet of a frame (its marker) is lost and nothing follows
    /// (a still page): no NACK can notice, so the frame is given up after
    /// the deadline from the newest arrival and a PLI asks for a keyframe.
    #[test]
    fn a_lost_tail_with_nothing_after_it_is_given_up() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        receiver.set_rtt(10_000);
        let sent = frames(&mut sender, 3, 0);
        for p in sent[0].iter().chain(&sent[1]) {
            receiver.push(p.clone(), 0);
        }
        assert_eq!(receiver.poll(0).0.len(), 2);
        let tail = &sent[2];
        assert!(tail.len() > 1);
        for p in &tail[..tail.len() - 1] {
            receiver.push(p.clone(), 20_000);
        }
        let (out, rtcp) = receiver.poll(20_000 + receiver.deadline_us() - 1);
        assert!(out.is_empty() && !has_pli(&rtcp));
        assert_eq!(receiver.next_deadline_us(30_000), 20_000 + receiver.deadline_us());
        let (out, rtcp) = receiver.poll(20_000 + receiver.deadline_us());
        assert!(out.is_empty());
        assert!(has_pli(&rtcp));
        assert_eq!(receiver.stats().frames_dropped, 1);
    }

    /// One roam can be announced twice (host endpoints, then the reflexive
    /// ones): the receiver asks for one keyframe, not one per announcement.
    #[test]
    fn path_changes_send_one_pli_per_interval() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        for (i, frame) in frames(&mut sender, 2, 0).iter().enumerate() {
            for p in frame {
                receiver.push(p.clone(), i as u64 * 16_667);
            }
        }
        assert_eq!(receiver.poll(20_000).0.len(), 2);
        receiver.path_changed();
        let (out, rtcp) = receiver.poll(500_000);
        assert!(out.is_empty() && has_pli(&rtcp));
        receiver.path_changed();
        assert!(!has_pli(&receiver.poll(510_000).1), "a second PLI within the interval");
        receiver.path_changed();
        assert!(has_pli(&receiver.poll(900_000).1));
        assert_eq!(receiver.stats().frames_dropped, 0);
    }

    #[test]
    fn a_p_frame_before_the_first_keyframe_is_not_released() {
        let mut sender = SenderCore::new(SenderConfig::default(), 1);
        let mut receiver = ReceiverCore::new(ReceiverConfig::default());
        let sent = frames(&mut sender, 3, 0);
        // Joined late: frame 0 (the keyframe) never arrives.
        for p in sent[1].iter().chain(&sent[2]) {
            receiver.push(p.clone(), 0);
        }
        let (out, rtcp) = receiver.poll(0);
        assert!(out.is_empty());
        assert!(has_pli(&rtcp));
    }
}
