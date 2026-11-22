//! Streamed browser tabs (cmux-next-ios/verify/browser-stream.md): the phone side
//! of the `browser` link service. The Mac's browser host speaks `cmux.rb/1`
//! on `cmux.rd/1` over the rd stream carrier, spliced through the channel.
//! This runs the shared rd viewer core (`cmux-rd-ffi`: reassembly, NACK and
//! loss feedback, clock probes, exactly-once input) on the library runtime
//! and hands Swift whole access units to decode with VideoToolbox.
//!
//! On a link with a media lane (verify/browser-video-track.md) the page's
//! frames come from the lane instead (RTP on a WebRTC video track or inside
//! the WireGuard tunnel; NACK, TWCC, PLI;
//! a lost frame is skipped to the next keyframe rather than stalling the
//! channel). The channel still carries rb control, input and the clock
//! probes, and the viewer takes frames from either source, so a hostd that
//! ignores `video: "track"` or hands the lane to another tab still works.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::media::{ReceivedFrame, VideoFrames, VideoIn};
use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_proto::{InputEvent, STREAM_CONTROL, flags};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::CmuxMobileError;

/// How long a frame may wait for missing shards, and when to NACK one.
const FRAME_DEADLINE_US: u64 = 500_000;
const NACK_AFTER_US: u64 = 50_000;
/// When an unacknowledged input event is sent again.
const INPUT_RESEND_US: u64 = 50_000;
/// The watchdog (the 2026-10-24 freeze): input the host has not
/// acknowledged for this long, or a write to the channel that waited this
/// long, ends the stream as [`STALLED`] and the app opens it again. Either
/// means the page is no longer answering, however the screen looks.
const INPUT_STALL_US: u64 = 5_000_000;
const SEND_STALL: std::time::Duration = std::time::Duration::from_secs(5);
/// The close code of a stream the watchdog ended.
pub const STALLED: &str = "stalled";
/// Shortest time between two keyframe requests on the media lane from a
/// viewer waiting for its tab's first keyframe there.
const LANE_ASK_INTERVAL_US: u64 = 250_000;

/// One complete video frame.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BrowserFrame {
    /// 0 = the page; popups have their own streams.
    pub stream: u16,
    pub frame: u32,
    pub keyframe: bool,
    /// H.264 Annex-B access unit (SPS and PPS before each IDR).
    pub access_unit: Vec<u8>,
    /// The host's capture time (host monotonic microseconds).
    pub capture_us: u64,
    /// When the frame was complete, on this library's clock (`now_us`).
    pub received_us: u64,
    /// How long ago the host captured it, measured when it was complete:
    /// network, reassembly and host encode. `None` until the clock probes
    /// have an estimate.
    pub age_us: Option<i64>,
}

/// Counters for the overlay and the logs.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct BrowserStats {
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub frames_lost: u64,
    /// `host = viewer + offset`, and the best probe's round trip.
    pub clock_offset_us: Option<i64>,
    pub clock_rtt_us: Option<u32>,
    /// The last frame came on the link's media lane (a WebRTC video track or
    /// RTP inside the WireGuard tunnel), not the channel.
    pub video_track: bool,
    /// Track frames: skipped to a keyframe after an unrecoverable loss, and
    /// packets a NACK brought back.
    pub track_frames_dropped: u64,
    pub track_packets_recovered: u64,
    /// What carried the last frame: `webrtc-track` (a WebRTC video track:
    /// the link's own, or the media session beside a WireGuard link),
    /// `wireguard-udp` (RTP inside the tunnel) or `channel`.
    pub video_carrier: String,
}

/// Receives a browser stream's frames and messages on a library thread.
/// Implementations should hand off quickly (a decode queue).
#[uniffi::export(with_foreign)]
pub trait BrowserObserver: Send + Sync {
    fn on_frame(&self, frame: BrowserFrame);
    /// An rb message from the host (the `body` of an rd `service` message,
    /// `t` starts with `rb.`), or an rd control message (`welcome`,
    /// `started`, `refused`, `ended`).
    fn on_message(&self, json: String);
    fn on_closed(&self, code: String, reason: String);
}

enum Command {
    Visible(bool),
    Control(Value),
    Input { event: Vec<u8>, must_deliver: bool },
    Keyframe,
    Decoded(u32),
    Close,
}

/// One open browser tab stream.
#[derive(uniffi::Object)]
pub struct BrowserStream {
    commands: mpsc::UnboundedSender<Command>,
    stats: Arc<Mutex<BrowserStats>>,
    epoch: Instant,
}

#[uniffi::export]
impl BrowserStream {
    /// Sends an rb control message (`rb.open`, `rb.screen`, `rb.navigate`,
    /// `rb.history`, `rb.visibility`, ...), a JSON object with `t`.
    pub fn send_message(&self, json: String) -> Result<(), CmuxMobileError> {
        let body: Value = serde_json::from_str(&json)
            .map_err(|e| CmuxMobileError::InvalidArgument { message: format!("message: {e}") })?;
        if !body.get("t").and_then(Value::as_str).is_some_and(|t| t.starts_with("rb.")) {
            return Err(CmuxMobileError::InvalidArgument { message: "message needs an rb. t".into() });
        }
        self.commands.send(Command::Control(body)).map_err(|_| closed())
    }

    /// Sends an rb input event (`{"e":"pointer",...}`, `wheel`, `key`,
    /// `ime_commit`, ...). `must_deliver` events are repeated until the host
    /// acknowledges them (presses and releases); moves need not be.
    pub fn send_input(&self, json: String, must_deliver: bool) -> Result<(), CmuxMobileError> {
        if json.len() > cmux_rd_proto::MAX_SERVICE_BYTES {
            return Err(CmuxMobileError::InvalidArgument { message: "input event too large".into() });
        }
        let _: Value = serde_json::from_str(&json)
            .map_err(|e| CmuxMobileError::InvalidArgument { message: format!("input: {e}") })?;
        self.commands.send(Command::Input { event: json.into_bytes(), must_deliver }).map_err(|_| closed())
    }

    /// The tab is on screen (or not). A shown tab keeps the WebRTC media
    /// session beside a WireGuard link open; it closes a while after the
    /// last one is hidden. Streams start shown.
    pub fn set_visible(&self, visible: bool) {
        let _ = self.commands.send(Command::Visible(visible));
    }

    /// Asks the host for a keyframe (the decoder lost its state).
    pub fn request_keyframe(&self) {
        let _ = self.commands.send(Command::Keyframe);
    }

    /// Reports how long the last frame took to decode (feeds the host's rate control).
    pub fn note_decode(&self, decode_us: u32) {
        let _ = self.commands.send(Command::Decoded(decode_us));
    }

    pub fn stats(&self) -> BrowserStats {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Microseconds on the clock `BrowserFrame.received_us` uses.
    pub fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    pub fn close(&self) {
        let _ = self.commands.send(Command::Close);
    }
}

impl Drop for BrowserStream {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Close);
    }
}

fn closed() -> CmuxMobileError {
    CmuxMobileError::Closed { message: "the browser stream is closed".into() }
}

/// This stream's share of the link's media lane.
pub(crate) struct Track {
    pub lane: VideoIn,
    pub frames: VideoFrames,
    /// The tag this stream's `open` asked hostd to put on its frames
    /// (`cmux_mobile_link::media::tag`); frames with another tag (or none) are
    /// another tab's.
    pub tag: u32,
}

/// Starts the viewer loop on an open `browser` channel; `track` is the
/// link's media lane with this stream's subscription to it.
pub(crate) fn start(
    sender: Arc<ChannelSender>,
    receiver: ChannelReceiver,
    observer: Arc<dyn BrowserObserver>,
    track: Option<Track>,
    media: Option<cmux_mobile_link::hybrid::MediaManager>,
) -> Arc<BrowserStream> {
    let (commands, rx) = mpsc::unbounded_channel();
    let stats = Arc::new(Mutex::new(BrowserStats::default()));
    let epoch = Instant::now();
    let viewer = Viewer {
        session: Session::new(Carrier::Stream, FRAME_DEADLINE_US, NACK_AFTER_US),
        input: InputChannel::new(Carrier::Stream, INPUT_RESEND_US),
        input_granted: false,
        observer,
        stats: Arc::clone(&stats),
        epoch,
        video_on_lane: track.is_some(),
        track,
        track_frame: 0,
        track_synced: false,
        last_lane_ask_us: None,
        foreign_lane_frames: 0,
        input_waiting_since_us: None,
        demand: media.as_ref().map(cmux_mobile_link::hybrid::MediaManager::acquire),
        media,
    };
    tokio::spawn(viewer.run(sender, receiver, rx));
    Arc::new(BrowserStream { commands, stats, epoch })
}

struct Viewer {
    session: Session,
    input: InputChannel,
    input_granted: bool,
    observer: Arc<dyn BrowserObserver>,
    stats: Arc<Mutex<BrowserStats>>,
    epoch: Instant,
    track: Option<Track>,
    /// Frame numbers of track frames (the RTP stream has none).
    track_frame: u32,
    /// A keyframe of this stream's own tag arrived: later frames decode.
    track_synced: bool,
    /// This tab's newest frame came on the lane (else on the channel): a
    /// decoder's keyframe request goes where its frames come from. The lane
    /// is shared by every tab, and asking it restarts every tab's frames at
    /// a keyframe.
    video_on_lane: bool,
    last_lane_ask_us: Option<u64>,
    /// Lane frames dropped for carrying another tab's tag (diagnostics).
    foreign_lane_frames: u64,
    /// Since when input has waited with no acknowledgement from the host
    /// (reset by every ack, so a long scroll on a live page never trips it).
    input_waiting_since_us: Option<u64>,
    /// The WebRTC media session beside a WireGuard link, and this shown
    /// tab's hold on it.
    media: Option<cmux_mobile_link::hybrid::MediaManager>,
    demand: Option<cmux_mobile_link::hybrid::MediaDemand>,
}

/// Why the channel closed, once a send found it closed: the peer's close
/// stops our sends before its `Closed` event is read, so take that event's
/// code (a refused tab is `forbidden`) over a bare `link_closed`.
async fn peer_close(receiver: &mut ChannelReceiver) -> (String, String) {
    let closed = async {
        while let Some(event) = receiver.recv().await {
            if let ChannelEvent::Closed(info) = event {
                return (info.code, info.reason);
            }
        }
        ("link_closed".to_owned(), String::new())
    };
    tokio::time::timeout(SEND_STALL, closed).await.unwrap_or_else(|_| ("link_closed".to_owned(), String::new()))
}

impl Viewer {
    fn now(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    async fn run(
        mut self,
        sender: Arc<ChannelSender>,
        mut receiver: ChannelReceiver,
        mut commands: mpsc::UnboundedReceiver<Command>,
    ) {
        // Clock probes (host = viewer + offset) give each frame its age; the
        // engine answers them whatever caps the welcome lists.
        self.session.enable_clock();
        let (code, reason) = loop {
            let deadline = self.deadline();
            let sleep =
                tokio::time::sleep(std::time::Duration::from_micros(deadline.saturating_sub(self.now())));
            let mut out = Vec::new();
            tokio::select! {
                event = receiver.recv() => match event {
                    Some(ChannelEvent::Data(bytes)) => {
                        let now = self.now();
                        if self.session.push_stream(&bytes, now).is_err() {
                            break ("bad_stream".to_owned(), "the host sent an invalid rd stream".to_owned());
                        }
                    }
                    Some(ChannelEvent::Closed(info)) => break (info.code, info.reason),
                    None => break ("link_closed".to_owned(), String::new()),
                },
                command = commands.recv() => match command {
                    Some(Command::Visible(visible)) => {
                        self.demand = if visible { self.media.as_ref().map(cmux_mobile_link::hybrid::MediaManager::acquire) } else { None };
                    }
                    Some(Command::Control(body)) => {
                        let control = serde_json::json!({"t": "service", "service": "rb/1", "body": body});
                        let _ = cmux_rd_proto::encode_stream_frame(
                            STREAM_CONTROL, &serde_json::to_vec(&control).unwrap_or_default(), &mut out);
                    }
                    Some(Command::Input { event, must_deliver }) => {
                        if self.input_granted {
                            self.input.push(InputEvent::Service { must_deliver, bytes: event });
                        }
                    }
                    Some(Command::Keyframe) => {
                        let _ = self.session.request_keyframe(0);
                        if self.video_on_lane && let Some(track) = &self.track {
                            track.frames.request_keyframe();
                        }
                    }
                    Some(Command::Decoded(us)) => {
                        let _ = self.session.note_decode(0, us);
                    }
                    Some(Command::Close) | None => {
                        let _ = sender.close("eof", "closed by the app").await;
                        break ("eof".to_owned(), "closed by the app".to_owned());
                    }
                },
                frame = async {
                    match self.track.as_mut() {
                        Some(track) => track.frames.frames.recv().await,
                        None => std::future::pending().await,
                    }
                } => match frame {
                    Some(frame) => self.lane_frame(frame),
                    // Another tab took the lane: video comes on the channel.
                    None => self.track = None,
                },
                () = sleep => {}
            }
            let now = self.now();
            self.session.tick(now);
            self.drain(now);
            while let Some(bytes) = self.session.feedback(now) {
                out.extend(bytes);
            }
            while let Some(bytes) = self.input.packet(now) {
                out.extend(bytes);
            }
            if self.input.next_deadline_us().is_some() {
                let since = *self.input_waiting_since_us.get_or_insert(now);
                if now.saturating_sub(since) >= INPUT_STALL_US {
                    let reason = "the page stopped answering input";
                    sender.close(STALLED, reason).await;
                    break (STALLED.to_owned(), reason.to_owned());
                }
            } else {
                self.input_waiting_since_us = None;
            }
            if !out.is_empty() {
                match tokio::time::timeout(SEND_STALL, sender.send(out.into())).await {
                    Ok(Ok(())) => {}
                    Ok(Err(_)) => break peer_close(&mut receiver).await,
                    Err(_) => {
                        let reason = "the browser channel stopped moving";
                        sender.close(STALLED, reason).await;
                        break (STALLED.to_owned(), reason.to_owned());
                    }
                }
            }
        };
        self.observer.on_closed(code, reason);
    }

    fn deadline(&self) -> u64 {
        let session = self.session.next_deadline_us();
        let input = self.input.next_deadline_us().unwrap_or(u64::MAX);
        // At least every 100 ms (clock probes, stats).
        session.min(input).min(self.now() + 100_000)
    }

    /// One frame from the media lane: this stream's own (by tag), from its
    /// first keyframe on.
    fn lane_frame(&mut self, mut frame: ReceivedFrame) {
        let Some(track) = &self.track else { return };
        let tag = cmux_mobile_link::media::tag::strip(&mut frame.access_unit);
        if tag != Some(track.tag) {
            // Another tab's (the lane is switching), or an untagged frame.
            self.foreign_lane_frames += 1;
            if self.foreign_lane_frames.is_power_of_two() {
                tracing::info!(
                    count = self.foreign_lane_frames,
                    ours = format!("{:08x}", track.tag),
                    got = ?tag.map(|t| format!("{t:08x}")),
                    keyframe = frame.keyframe,
                    "browser: lane frames for another tab"
                );
            }
            return;
        }
        if !self.track_synced {
            if !frame.keyframe {
                tracing::debug!("browser: a lane P-frame before this tab's first lane keyframe");
                // This tab's claim started mid-stream (or its first
                // keyframe went to the tab before): ask again.
                let now = self.now();
                if self.last_lane_ask_us.is_none_or(|at| now.saturating_sub(at) >= LANE_ASK_INTERVAL_US) {
                    self.last_lane_ask_us = Some(now);
                    track.frames.request_keyframe();
                }
                return;
            }
            self.track_synced = true;
        }
        self.video_on_lane = true;
        self.track_frame(frame);
    }

    /// One frame from the media lane.
    fn track_frame(&mut self, frame: ReceivedFrame) {
        let now = self.now();
        let clock = self.session.clock();
        self.track_frame = self.track_frame.wrapping_add(1);
        // The RTP timestamp is the host's capture time at 90 kHz.
        let host_now = clock.map(|c| i128::from(now) + i128::from(c.offset_us));
        let capture_us = match host_now {
            Some(host_now) => cmux_mobile_link::media::capture_us_from_rtp(
                frame.rtp_timestamp,
                u64::try_from(host_now).unwrap_or(0),
            ),
            None => u64::from(frame.rtp_timestamp) * 100 / 9,
        };
        let age_us = host_now.map(|h| i64::try_from(h - i128::from(capture_us)).unwrap_or(i64::MAX));
        {
            let mut stats = self.stats.lock().unwrap_or_else(PoisonError::into_inner);
            stats.frames += 1;
            stats.keyframes += u64::from(frame.keyframe);
            stats.bytes += frame.access_unit.len() as u64;
            stats.clock_offset_us = clock.map(|c| c.offset_us);
            stats.clock_rtt_us = clock.map(|c| c.rtt_us);
            stats.video_track = true;
            if let Some(track) = &self.track {
                stats.video_carrier = track.lane.current_kind().name().to_owned();
                let lane = track.lane.stats();
                stats.track_frames_dropped = lane.frames_dropped;
                stats.track_packets_recovered = lane.packets_recovered;
            }
        }
        self.observer.on_frame(BrowserFrame {
            stream: 0,
            frame: self.track_frame,
            keyframe: frame.keyframe,
            access_unit: frame.access_unit,
            capture_us,
            received_us: now,
            age_us,
        });
    }

    fn drain(&mut self, now: u64) {
        while let Some(message) = self.session.pop_message() {
            if message.kind != STREAM_CONTROL {
                // The host applied input: it is answering, however much more
                // is still in flight (a pan streams events faster than RTT).
                if self.input.on_ack(&message.bytes).is_ok() {
                    self.input_waiting_since_us = None;
                }
                continue;
            }
            let Ok(control) = serde_json::from_slice::<Value>(&message.bytes) else { continue };
            let body = match control.get("t").and_then(Value::as_str) {
                Some("service") => control.get("body").cloned().unwrap_or(Value::Null),
                Some("welcome") => {
                    self.input_granted = control
                        .get("caps")
                        .and_then(Value::as_array)
                        .is_some_and(|caps| caps.iter().any(|c| c == "input.service"));
                    control
                }
                _ => control,
            };
            if body.get("t").and_then(Value::as_str) == Some("rb.surface.show")
                && let Some(stream) =
                    body.get("stream").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok())
            {
                let _ = self.session.open_stream(stream);
            }
            self.observer.on_message(body.to_string());
        }
        let clock = self.session.clock();
        while let Some((stream, complete)) = self.session.pop_frame() {
            let keyframe = complete.flags & flags::KEYFRAME != 0;
            if stream == 0 {
                // The page's video is on the channel (another tab holds the
                // lane): when this tab takes the lane back, its lane frames
                // start again at a keyframe.
                self.track_synced = false;
                self.video_on_lane = false;
            }
            let capture_us = complete.body.t_capture_us;
            let age_us = clock.map(|c| {
                let host_now = i128::from(now) + i128::from(c.offset_us);
                i64::try_from(host_now - i128::from(capture_us)).unwrap_or(i64::MAX)
            });
            {
                let mut stats = self.stats.lock().unwrap_or_else(PoisonError::into_inner);
                stats.frames += 1;
                stats.keyframes += u64::from(keyframe);
                stats.bytes += complete.body.access_unit.len() as u64;
                stats.clock_offset_us = clock.map(|c| c.offset_us);
                stats.clock_rtt_us = clock.map(|c| c.rtt_us);
                stats.video_track = false;
                stats.video_carrier = "channel".to_owned();
                if let Ok(s) = self.session.stats(stream) {
                    stats.frames_lost = s.frames_lost;
                }
            }
            self.observer.on_frame(BrowserFrame {
                stream,
                frame: complete.frame,
                keyframe,
                access_unit: complete.body.access_unit,
                capture_us,
                received_us: now,
                age_us,
            });
        }
    }
}
