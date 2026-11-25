//! `browser` over the media lane (cmux-next-ios/verify/browser-video-track.md).
//!
//! When the phone asks for `video: "track"` and the link has a media lane (a
//! WebRTC video track, or RTP inside the WireGuard tunnel), hostd becomes the rd viewer of the page's main stream on
//! loopback: it reassembles the host's frames and writes each access unit
//! to the lane, with the capture time as its RTP timestamp. Everything
//! else (rb control, input, clock probes, popup streams) still rides the
//! `browser` channel, unchanged.
//!
//! hostd answers the host's media engine with the feedback a viewer at the
//! end of the real path would send, so the host's own controls (frame gate,
//! congestion controller, recovery) follow the lane's path:
//!
//! - Arrivals: each host datagram is timed through a virtual bottleneck at
//!   the media lane's target bitrate (TWCC-fed). Sending above the target
//!   builds virtual queueing delay, which the host's delay-based controller
//!   reads as overuse, so its VideoToolbox bitrate follows the path without
//!   any change to the host.
//! - Acks: a frame is acknowledged once it is on the track, unless the
//!   lane's in-flight window is full. Then the ack waits, the host's frame
//!   gate holds, and the page's damage coalesces into the next frame: a
//!   congested path skips frames at the source instead of queueing them.
//! - Keyframes: the phone's PLI (or FIR) becomes `need_recovery`, which the
//!   host answers with an IDR. It is asked again until a keyframe is on the
//!   track: the host refuses one that comes too soon after its last forced
//!   IDR, and a lane taken back right after it was lost may wait on the ack
//!   of a frame that went to the phone on the channel.

use std::collections::VecDeque;

use cmux_rd_core::reassembly::{CompleteFrame, Reassembler};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, Feedback, HEADER_LEN, MAX_ARRIVALS, STREAM_DATAGRAM,
    encode_stream_frame, flags,
};

/// The page's main display stream (rb `main_stream`).
pub const MAIN_STREAM: u16 = 0;
/// How long a frame may wait for shards on loopback.
const FRAME_DEADLINE_US: u64 = 250_000;
/// Feedback goes out at least this often while frames flow.
pub const FEEDBACK_INTERVAL_US: u64 = 30_000;
/// A recovery the host has not answered with a keyframe is asked again this
/// much later (the host's minimum forced-IDR interval, `cmux_rd_engine`'s
/// `MIN_FORCED_IDR_INTERVAL_US`).
const RECOVERY_RETRY_US: u64 = 250_000;

/// The rd viewer side of one track-mode splice. Pure; clocked by the caller.
#[derive(Debug)]
pub struct TrackBridge {
    reassembler: Reassembler,
    arrivals: VecDeque<Arrival>,
    /// When the virtual bottleneck is next free (microseconds).
    queue_free_us: f64,
    /// The newest frame on the track.
    released: u32,
    /// The newest frame acknowledged to the host.
    acked: u32,
    /// A keyframe is wanted on the track; asked for until one is there.
    recovery: bool,
    /// When the host was last asked for it.
    recovery_asked_us: Option<u64>,
    last_feedback_us: u64,
    pub frames: u64,
    pub held_acks: u64,
    /// Host datagrams the bridge took.
    pub datagrams: u64,
}

impl Default for TrackBridge {
    fn default() -> Self {
        Self::new()
    }
}

impl TrackBridge {
    pub fn new() -> Self {
        Self {
            reassembler: Reassembler::new(FRAME_DEADLINE_US),
            arrivals: VecDeque::new(),
            queue_free_us: 0.0,
            released: 0,
            acked: 0,
            // Start the phone's decoder at a keyframe.
            recovery: true,
            recovery_asked_us: None,
            last_feedback_us: 0,
            frames: 0,
            held_acks: 0,
            datagrams: 0,
        }
    }

    /// Whether this datagram is the bridge's (the main stream's media);
    /// everything else goes to the phone on the channel.
    pub fn takes(header: &DatagramHeader) -> bool {
        header.stream == MAIN_STREAM
            && matches!(header.kind, DatagramKind::Video | DatagramKind::Fec | DatagramKind::Probe)
    }

    /// One host datagram of the main stream, received at `now_us`, with the
    /// lane's target. Returns the frames that became complete.
    pub fn on_datagram(
        &mut self,
        header: &DatagramHeader,
        payload: &[u8],
        size: usize,
        target_bps: u64,
        now_us: u64,
    ) -> Vec<CompleteFrame> {
        self.datagrams += 1;
        let now = now_us as f64;
        self.queue_free_us = self.queue_free_us.max(now) + size as f64 * 8e6 / target_bps.max(1) as f64;
        if self.arrivals.len() >= 8 * MAX_ARRIVALS {
            self.arrivals.pop_front();
        }
        self.arrivals.push_back(Arrival {
            transport_seq: header.transport_seq,
            arrival_us: self.queue_free_us as u64 as u32,
        });
        if header.kind == DatagramKind::Probe {
            return Vec::new();
        }
        let frames = self.reassembler.push(header, payload, now_us);
        self.note(&frames);
        frames
    }

    /// Advances time: frames past their deadline are dropped.
    pub fn tick(&mut self, now_us: u64) -> Vec<CompleteFrame> {
        let frames = self.reassembler.tick(now_us);
        self.note(&frames);
        frames
    }

    fn note(&mut self, frames: &[CompleteFrame]) {
        if let Some(last) = frames.last() {
            self.released = last.frame;
            self.frames += frames.len() as u64;
        }
        if frames.iter().any(|frame| frame.flags & flags::KEYFRAME != 0) {
            self.recovery = false;
            self.recovery_asked_us = None;
        }
    }

    /// The phone asked for a keyframe (PLI or FIR), or this splice took the
    /// track over: the next feedback asks the host to recover.
    pub fn request_keyframe(&mut self) {
        self.recovery = true;
        self.recovery_asked_us = None;
    }

    /// Whether to ask the host for the wanted keyframe now.
    fn recovery_due(&self, now_us: u64) -> bool {
        self.recovery
            && self.recovery_asked_us.is_none_or(|at| now_us.saturating_sub(at) >= RECOVERY_RETRY_US)
    }

    /// Whether feedback should go now: a frame waits for its ack, recovery
    /// is wanted, or the interval passed with arrivals to report.
    pub fn due(&self, congested: bool, now_us: u64) -> bool {
        (self.released > self.acked && !congested)
            || self.recovery_due(now_us)
            || self.reassembler.need_recovery()
            || (!self.arrivals.is_empty()
                && now_us.saturating_sub(self.last_feedback_us) >= FEEDBACK_INTERVAL_US)
    }

    /// The feedback datagrams for the host, as rd stream frames. `congested`:
    /// the lane's window is full, so the newest frame's ack waits.
    pub fn feedback(&mut self, congested: bool, now_us: u64) -> Vec<u8> {
        let mut out = Vec::new();
        if !self.due(congested, now_us) {
            return out;
        }
        if congested && self.released > self.acked {
            self.held_acks += 1;
        } else {
            self.acked = self.released;
        }
        let asked = self.recovery_due(now_us);
        if asked {
            self.recovery_asked_us = Some(now_us);
        }
        let need_recovery = asked || self.reassembler.need_recovery();
        let mut first = true;
        while first || !self.arrivals.is_empty() {
            let take = self.arrivals.len().min(MAX_ARRIVALS);
            let feedback = Feedback {
                acked_frame: self.acked,
                decode_us: 0,
                need_recovery: need_recovery && first,
                arrivals: self.arrivals.drain(..take).collect(),
                nacks: Vec::new(),
            };
            let mut datagram = Vec::with_capacity(HEADER_LEN + 1024);
            DatagramHeader {
                flags: 0,
                kind: DatagramKind::Feedback,
                stream: MAIN_STREAM,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode_into(&mut datagram);
            datagram.extend_from_slice(&feedback.encode());
            let _ = encode_stream_frame(STREAM_DATAGRAM, &datagram, &mut out);
            first = false;
        }
        self.last_feedback_us = now_us;
        out
    }

    /// When the caller should come back: the reassembly deadline, the
    /// feedback interval or a recovery to ask for again.
    pub fn next_deadline_us(&self, now_us: u64) -> u64 {
        let feedback = if self.arrivals.is_empty() {
            now_us + 100_000
        } else {
            self.last_feedback_us + FEEDBACK_INTERVAL_US
        };
        let recovery = match self.recovery_asked_us {
            Some(at) if self.recovery => at + RECOVERY_RETRY_US,
            _ => u64::MAX,
        };
        self.reassembler.next_expiry_us().unwrap_or(u64::MAX).min(feedback).min(recovery).max(now_us)
    }
}

/// Whether a phone datagram belongs to the bridge in track mode (the
/// phone's own feedback for the main stream, which saw no shards).
pub fn phone_datagram_superseded(payload: &[u8]) -> bool {
    DatagramHeader::decode(payload)
        .is_ok_and(|(header, _)| header.kind == DatagramKind::Feedback && header.stream == MAIN_STREAM)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::flow::Rect;
    use cmux_rd_engine::{Encoded, EngineConfig, MediaEngine};

    /// The real rd media engine as the host, the bridge as its viewer and a
    /// fixed 1.5 Mbit/s lane target: the host's own controller settles near
    /// the lane's target, and every frame reaches the track in order.
    #[test]
    fn the_hosts_bitrate_follows_the_lanes_target() {
        let mut engine = MediaEngine::new(
            EngineConfig {
                width: 804,
                height: 1444,
                max_fps: 60,
                max_datagram: 1332,
                ..EngineConfig::default()
            },
            0,
        );
        let mut bridge = TrackBridge::new();
        let target_bps = 1_500_000u64;
        let mut now = 0u64;
        let mut request = engine.start(now);
        let mut frames = Vec::new();
        let mut targets = Vec::new();
        let mut idrs = 0;
        for _ in 0..1200 {
            now += 8_333;
            if let Some(req) = request.take() {
                targets.push(req.target_kbps);
                idrs += u32::from(req.force_idr);
                // An encoder that hits the target at 60 fps.
                let size = (u64::from(req.target_kbps) * 1000 / 8 / 60).max(200) as usize;
                let mut au = vec![0, 0, 0, 1, if req.force_idr { 0x65 } else { 0x41 }];
                au.resize(size, 0x5a);
                let out = engine
                    .encoded(
                        &req,
                        Some(Encoded { access_unit: au, idr: req.force_idr, t_capture_us: now }),
                        now,
                    )
                    .unwrap();
                for d in &out.datagrams {
                    let (header, payload) = DatagramHeader::decode(d).unwrap();
                    assert!(TrackBridge::takes(&header));
                    frames.extend(bridge.on_datagram(&header, payload, d.len(), target_bps, now));
                }
                request = out.encode;
            }
            let feedback = bridge.feedback(false, now);
            let mut deframer = cmux_rd_proto::StreamDeframer::default();
            deframer.extend(&feedback);
            while let Ok(Some((_, d))) = deframer.next_frame() {
                let out = engine.on_datagram(&d, true, now);
                request = request.or(out.encode);
            }
            let full = Rect { x: 0, y: 0, width: 804, height: 1444 };
            request = request.or(engine.damage(0, full, now));
            request = request.or(engine.poll(now));
        }
        let settled: Vec<u32> = targets[targets.len() - 60..].to_vec();
        let mean = settled.iter().map(|&t| u64::from(t)).sum::<u64>() / settled.len() as u64;
        // Started at 8 Mbit/s; the virtual bottleneck pulls it to the lane.
        assert!(targets[0] >= 7_000, "{}", targets[0]);
        assert!((900..=2_200).contains(&mean), "settled at {mean} kbit/s: {settled:?}");
        assert!(idrs >= 1);
        for w in frames.windows(2) {
            assert!(w[1].frame > w[0].frame);
        }
        assert!(frames.len() > 300, "{}", frames.len());
    }

    /// A full window holds the ack, so the host encodes no further frame
    /// until the lane drains; a keyframe request reaches the host.
    #[test]
    fn a_full_window_holds_the_hosts_frame_gate_and_pli_forces_an_idr() {
        let mut engine = MediaEngine::new(EngineConfig::default(), 0);
        let mut bridge = TrackBridge::new();
        // The engine's first frame is an IDR anyway.
        bridge.recovery = false;
        let mut now = 0;
        let req = engine.start(now).unwrap();
        assert!(req.force_idr);
        let out = engine
            .encoded(
                &req,
                Some(Encoded { access_unit: vec![0, 0, 0, 1, 0x65, 1, 2, 3], idr: true, t_capture_us: 0 }),
                now,
            )
            .unwrap();
        for d in &out.datagrams {
            let (header, payload) = DatagramHeader::decode(d).unwrap();
            assert_eq!(bridge.on_datagram(&header, payload, d.len(), 2_000_000, now).len(), 1);
        }
        let deliver = |engine: &mut MediaEngine, bytes: Vec<u8>, now: u64| {
            let mut deframer = cmux_rd_proto::StreamDeframer::default();
            deframer.extend(&bytes);
            let mut encode = None;
            while let Ok(Some((_, d))) = deframer.next_frame() {
                encode = encode.or(engine.on_datagram(&d, true, now).encode);
            }
            encode
        };
        now += 40_000;
        let full = Rect { x: 0, y: 0, width: 1920, height: 1080 };
        assert!(engine.damage(0, full, now).is_none(), "frame 1 is still in flight");
        // Congested: the ack is held, the gate stays shut.
        assert!(deliver(&mut engine, bridge.feedback(true, now), now).is_none());
        assert_eq!(bridge.held_acks, 1);
        now += 20_000;
        assert!(engine.poll(now).is_none());
        // The window drains: the ack goes and the coalesced damage encodes.
        let next = deliver(&mut engine, bridge.feedback(false, now), now).expect("frame 2");
        assert!(!next.force_idr);
        // The phone's PLI.
        bridge.request_keyframe();
        now += 300_000;
        let _ = engine.encoded(&next, None, now);
        let recovery = deliver(&mut engine, bridge.feedback(false, now), now).expect("recovery");
        assert!(recovery.force_idr);
    }

    /// A tab takes the lane back right after it lost it: the host's newest
    /// frame went to the phone on the channel (the bridge now answers for
    /// the main stream, so the phone's ack of it never reaches the host),
    /// and the IDR the loss asked for is under the host's minimum forced-IDR
    /// interval old, so the new bridge's first recovery is refused. The
    /// bridge keeps asking until a keyframe is on the track (on a loaded
    /// runner `the_shown_tab_takes_the_lane_back_over_webrtc` once waited
    /// out its 10 s with no frame at all).
    #[test]
    fn a_lane_taken_back_right_after_it_was_lost_still_gets_a_keyframe() {
        let mut engine = MediaEngine::new(EngineConfig::default(), 0);
        let encode = |engine: &mut MediaEngine, req: &cmux_rd_engine::EncodeRequest, now: u64| {
            let au = vec![0, 0, 0, 1, if req.force_idr { 0x65 } else { 0x41 }, 1, 2, 3];
            let encoded = Encoded { access_unit: au, idr: req.force_idr, t_capture_us: now };
            engine.encoded(req, Some(encoded), now).unwrap()
        };
        let phone_feedback = |acked_frame: u32, need_recovery: bool| {
            let mut datagram = Vec::new();
            DatagramHeader {
                flags: 0,
                kind: DatagramKind::Feedback,
                stream: MAIN_STREAM,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode_into(&mut datagram);
            datagram
                .extend_from_slice(&Feedback { acked_frame, need_recovery, ..Feedback::default() }.encode());
            datagram
        };
        let full = Rect { x: 0, y: 0, width: 1920, height: 1080 };
        // Frame 1 goes to the phone on the channel; the phone acks it and,
        // as the lane moves away, asks for an IDR: frame 2, also on the
        // channel, whose ack the phone sends after the lane came back.
        let mut now = 0;
        let first = engine.start(now).unwrap();
        let _ = encode(&mut engine, &first, now);
        now += 50_000;
        let second = engine.on_datagram(&phone_feedback(1, true), true, now).encode.expect("the forced IDR");
        assert!(second.force_idr);
        let _ = encode(&mut engine, &second, now);
        // The tab takes the lane back 20 ms later.
        now += 20_000;
        let mut bridge = TrackBridge::new();
        let mut keyframe_at = None;
        while now < 1_000_000 && keyframe_at.is_none() {
            let mut deframer = cmux_rd_proto::StreamDeframer::default();
            deframer.extend(&bridge.feedback(false, now));
            let mut request = None;
            while let Ok(Some((_, d))) = deframer.next_frame() {
                request = request.or(engine.on_datagram(&d, true, now).encode);
            }
            request = request.or(engine.damage(0, full, now)).or(engine.poll(now));
            if let Some(req) = request {
                for d in &encode(&mut engine, &req, now).datagrams {
                    let (header, payload) = DatagramHeader::decode(d).unwrap();
                    let frames = bridge.on_datagram(&header, payload, d.len(), 2_000_000, now);
                    if frames.iter().any(|f| f.flags & cmux_rd_proto::flags::KEYFRAME != 0) {
                        keyframe_at = Some(now);
                    }
                }
            }
            now += 10_000;
        }
        assert!(keyframe_at.is_some(), "no keyframe reached the track in a second");
    }

    #[test]
    fn only_the_main_streams_media_is_the_bridges() {
        let header = |kind, stream| DatagramHeader {
            flags: 0,
            kind,
            stream,
            frame: 1,
            index: 0,
            count: 1,
            fec_count: 0,
            transport_seq: 0,
        };
        assert!(TrackBridge::takes(&header(DatagramKind::Video, 0)));
        assert!(TrackBridge::takes(&header(DatagramKind::Fec, 0)));
        assert!(!TrackBridge::takes(&header(DatagramKind::Video, 3)), "popups stay on the channel");
        assert!(!TrackBridge::takes(&header(DatagramKind::ClockPong, 0)));
        assert!(!TrackBridge::takes(&header(DatagramKind::InputAck, 0)));
        let mut feedback = Vec::new();
        header(DatagramKind::Feedback, 0).encode_into(&mut feedback);
        feedback.extend(Feedback::default().encode());
        assert!(phone_datagram_superseded(&feedback));
    }
}
