//! The media lane (cmux-next-ios/verify/browser-video-track.md): real-time video
//! from the Mac to the phone as RTP, beside the link's reliable channels.
//!
//! One transport-agnostic core does the media work, and a carrier only
//! moves packets:
//!
//! - [`sender::SenderCore`] (Mac): H.264 packetization (RFC 6184 via the
//!   `rtp` crate), transport-wide sequence numbers, a NACK history, the
//!   delay-based congestion controller shared with `cmux.rd/1`
//!   (`cmux-rd-core`, fed by TWCC feedback), PLI and FIR as keyframe
//!   requests, and an in-flight window that tells the source when to skip
//!   a frame instead of queueing it.
//! - [`receiver::ReceiverCore`] (phone): a reorder buffer that releases a
//!   frame the moment it is complete (no playout delay), NACKs for gaps,
//!   TWCC feedback (the `interceptor` crate's recorder), and PLI when a
//!   frame is given up, after which only a keyframe is released.
//!
//! Carriers ([`MediaCarrier`]):
//!
//! - [`CarrierKind::WebRtcTrack`]: a video track on the link's own peer
//!   connection (SRTP, same ICE and TURN session). See
//!   [`crate::dial::webrtc`].
//! - [`CarrierKind::WireGuardUdp`]: RTP and RTCP as plain datagrams on
//!   overlay UDP inside the WireGuard tunnel ([`wireguard::WgCarrier`]), with
//!   the same webrtc-rs interceptors bound to the socket and no SRTP
//!   (WireGuard encrypts).
//!
//! The lane is negotiated per carrier: the phone lists [`VIDEO_LANE`] in its
//! offer's lanes and the Mac lists it back only when it attached a sender.
//! A link without the lane carries video the old way (rd shards on a
//! reliable channel).

use std::sync::Arc;

use futures_util::future::BoxFuture;
use tokio::sync::{Mutex, mpsc, watch};

pub mod h264;
pub mod receiver;
pub mod resend;
pub mod routes;
pub mod sender;
pub mod tag;
pub mod track;
pub mod twcc;
pub mod wireguard;

pub use receiver::{ReceivedFrame, ReceiverConfig, ReceiverCore};
pub use sender::{SenderConfig, SenderCore, SenderEvent};

pub use ::webrtc::rtcp;
pub use ::webrtc::rtp;

/// The lane name in the signaling offer and answer (PROTOCOL.md "Lanes").
pub const VIDEO_LANE: &str = "video";
/// RTP clock of the video stream (RFC 6184).
pub const CLOCK_RATE: u32 = 90_000;
/// Largest RTP payload. Leaves room for the RTP header (12), the one-byte
/// header extension block (8), SRTP's tag (10) and the tunnel or TURN
/// framing on a 1280-byte IPv6 path.
pub const RTP_PAYLOAD_MTU: usize = 1100;
/// The transport-wide sequence number header extension (TWCC).
pub const TWCC_URI: &str = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01";
/// The extension id a carrier without SDP uses.
pub const DEFAULT_TWCC_EXT_ID: u8 = 1;
/// The dynamic payload type a carrier without SDP uses.
pub const DEFAULT_PAYLOAD_TYPE: u8 = 102;

pub type RtcpPackets = Vec<Box<dyn rtcp::packet::Packet + Send + Sync>>;

/// How a lane's packets travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CarrierKind {
    /// A video track on the link's WebRTC peer connection.
    WebRtcTrack,
    /// RTP in overlay UDP inside the WireGuard tunnel.
    WireGuardUdp,
}

impl CarrierKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::WebRtcTrack => "webrtc-track",
            Self::WireGuardUdp => "wireguard-udp",
        }
    }
}

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum MediaError {
    #[error("this carrier does not carry media yet")]
    Unsupported,
    #[error("the media lane is closed")]
    Closed,
    #[error("media: {0}")]
    Other(String),
}

/// Moves RTP one way and RTCP back. The Mac's carrier sends RTP and reads
/// RTCP; the phone's reads RTP and sends RTCP. A method a side never uses
/// may stay pending forever.
pub trait MediaCarrier: Send + Sync + 'static {
    fn kind(&self) -> CarrierKind;
    /// The negotiated id of the TWCC header extension.
    fn twcc_ext_id(&self) -> u8;
    /// The largest RTP payload this carrier moves in one packet without
    /// fragmenting.
    fn max_payload(&self) -> usize {
        RTP_PAYLOAD_MTU
    }
    /// Counts the path's network changes (a WireGuard roam on either side),
    /// for carriers whose path can change under them without a new
    /// negotiation. The receiver asks for a keyframe after each; the sender
    /// forgets what was in flight on the old path.
    fn path_changes(&self) -> Option<watch::Receiver<u64>> {
        None
    }
    fn send_rtp<'a>(&'a self, packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>>;
    fn send_rtcp(&self, packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>>;
    /// The next RTP packet; `None` once the carrier ends.
    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>>;
    /// The next RTCP compound; `None` once the carrier ends.
    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>>;
}

/// Microseconds since `epoch` (the cores' injected clock).
pub(crate) fn micros_since(epoch: std::time::Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
}

/// The RTP timestamp of a host capture time (host monotonic microseconds).
pub fn rtp_timestamp(capture_us: u64) -> u32 {
    (u128::from(capture_us) * u128::from(CLOCK_RATE) / 1_000_000) as u32
}

/// The capture time (host microseconds) of `rtp_ts`, given the host's clock
/// now: the newest time at or before `host_now_us` with that timestamp.
pub fn capture_us_from_rtp(rtp_ts: u32, host_now_us: u64) -> u64 {
    let now_ts = rtp_timestamp(host_now_us);
    // Signed: a timestamp slightly ahead of the estimate of the host's
    // clock (an offset error larger than the frame's age) is "now", not
    // 2^32 ticks (13 hours) behind.
    let behind_ticks = now_ts.wrapping_sub(rtp_ts) as i32;
    if behind_ticks <= 0 {
        return host_now_us;
    }
    host_now_us.saturating_sub(behind_ticks as u64 * 1_000_000 / u64::from(CLOCK_RATE))
}

/// One frame for the lane (Mac side).
#[derive(Debug, Clone)]
pub struct OutgoingFrame {
    /// H.264 Annex-B access unit.
    pub access_unit: bytes::Bytes,
    /// Host monotonic capture time in microseconds; becomes the RTP timestamp.
    pub capture_us: u64,
}

/// What the Mac's source hears from the lane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SenderState {
    /// The congestion controller's target.
    pub target_bps: u64,
    /// Bytes sent and not yet reported by feedback.
    pub in_flight_bytes: u64,
    /// Skip the next frame at the source rather than queue it.
    pub congested: bool,
    /// Loss among packets the last feedback settled (0.0 to 1.0).
    pub loss: f64,
    /// Smoothed time from sending a packet to hearing of its arrival.
    pub feedback_delay_us: u64,
    /// Keyframe requests (PLI, FIR) received so far.
    pub keyframe_requests: u64,
    pub packets_sent: u64,
    pub nacks_received: u64,
    /// How long packets sent since the last TWCC feedback have waited for
    /// one (0: none waiting). A working path answers every 25 ms.
    pub feedback_wait_us: u64,
}

/// The Mac side of a lane: one source at a time owns it. A newer
/// [`VideoOut::claim`] preempts the older one, whose `preempted` fires.
///
/// A lane has one route per carrier ([`routes`]): the carrier the dial
/// negotiated and, on a WireGuard link, the WebRTC media session's track
/// while one is up ([`VideoOut::add_route`]). Frames go on the preferred
/// usable route and move between routes only at keyframes.
#[derive(Clone)]
pub struct VideoOut {
    inner: Arc<OutInner>,
}

struct OutInner {
    kind: CarrierKind,
    config: SenderConfig,
    owner: watch::Sender<u64>,
    /// The state of the route the source should follow ([`routes::Table::shown`]).
    state: watch::Sender<SenderState>,
    keyframes: tokio::sync::broadcast::Sender<()>,
    next_claim: std::sync::atomic::AtomicU64,
    routes: std::sync::Mutex<routes::Table>,
    /// Bumped on every route change (added, removed, health, a switch).
    version: Arc<watch::Sender<u64>>,
    /// The carrier video rides now.
    active: watch::Sender<Option<CarrierKind>>,
    closed: Option<watch::Receiver<Option<String>>>,
}

impl OutInner {
    fn table(&self) -> std::sync::MutexGuard<'_, routes::Table> {
        self.routes.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn bump(&self) {
        self.version.send_modify(|v| *v = v.wrapping_add(1));
    }
}

impl std::fmt::Debug for VideoOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VideoOut").field("kind", &self.inner.kind).finish_non_exhaustive()
    }
}

/// One source's hold on the lane.
pub struct VideoClaim {
    id: u64,
    inner: Arc<OutInner>,
    owner: watch::Receiver<u64>,
    pub keyframes: tokio::sync::broadcast::Receiver<()>,
}

/// A route added with [`VideoOut::add_route`]; dropping it removes the
/// route (video moves to the next one at its next keyframe).
pub struct RouteHandle {
    id: u64,
    inner: std::sync::Weak<OutInner>,
}

impl Drop for RouteHandle {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            inner.table().remove(self.id);
            inner.bump();
        }
    }
}

fn initial_state(config: &SenderConfig) -> SenderState {
    SenderState {
        target_bps: config.cc.start_bps,
        in_flight_bytes: 0,
        congested: false,
        loss: 0.0,
        feedback_delay_us: 0,
        keyframe_requests: 0,
        packets_sent: 0,
        nacks_received: 0,
        feedback_wait_us: 0,
    }
}

impl VideoOut {
    /// Runs the sender core on `carrier` until the carrier ends or `closed`
    /// (the link's close state) says the link closed.
    pub fn start(
        carrier: Arc<dyn MediaCarrier>,
        config: SenderConfig,
        closed: Option<watch::Receiver<Option<String>>>,
    ) -> Self {
        let (keyframes, _) = tokio::sync::broadcast::channel(8);
        let (version, version_rx) = watch::channel(0u64);
        let inner = Arc::new(OutInner {
            kind: carrier.kind(),
            config,
            owner: watch::channel(0).0,
            state: watch::channel(initial_state(&config)).0,
            keyframes,
            next_claim: std::sync::atomic::AtomicU64::new(1),
            routes: std::sync::Mutex::new(routes::Table::default()),
            version: Arc::new(version),
            active: watch::channel(None).0,
            closed: closed.clone(),
        });
        let out = Self { inner };
        let (_, health) = watch::channel(true);
        // The dial's own carrier lives as long as the lane.
        out.spawn_route(carrier, health);
        tokio::spawn(route_watch(Arc::downgrade(&out.inner), version_rx, closed));
        out
    }

    fn spawn_route(&self, carrier: Arc<dyn MediaCarrier>, mut health: watch::Receiver<bool>) -> u64 {
        let (frames_tx, frames_rx) = mpsc::channel(4);
        let (state_tx, state_rx) = watch::channel(initial_state(&self.inner.config));
        let kind = carrier.kind();
        let id = self.inner.table().add(kind, frames_tx, state_rx, health.clone());
        tokio::spawn(sender::run(
            carrier,
            self.inner.config,
            frames_rx,
            state_tx,
            self.inner.keyframes.clone(),
            self.inner.closed.clone(),
        ));
        // Health changes re-run the choice.
        let version = Arc::clone(&self.inner.version);
        tokio::spawn(async move {
            while health.changed().await.is_ok() {
                version.send_modify(|v| *v = v.wrapping_add(1));
            }
        });
        self.inner.bump();
        id
    }

    /// Adds a route on `carrier` (the WebRTC media session's track), usable
    /// while `health` is true. Video moves to it at the next keyframe when
    /// it is preferred.
    pub fn add_route(&self, carrier: Arc<dyn MediaCarrier>, health: watch::Receiver<bool>) -> RouteHandle {
        let id = self.spawn_route(carrier, health);
        RouteHandle { id, inner: Arc::downgrade(&self.inner) }
    }

    /// The carrier the dial negotiated.
    pub fn kind(&self) -> CarrierKind {
        self.inner.kind
    }

    /// The carrier video rides now (None before the first frame).
    pub fn active(&self) -> watch::Receiver<Option<CarrierKind>> {
        self.inner.active.subscribe()
    }

    /// Takes the lane; the previous claim (if any) is preempted.
    pub fn claim(&self) -> VideoClaim {
        let id = self.inner.next_claim.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.inner.owner.send_replace(id);
        VideoClaim {
            id,
            inner: Arc::clone(&self.inner),
            owner: self.inner.owner.subscribe(),
            keyframes: self.inner.keyframes.subscribe(),
        }
    }

    pub fn state(&self) -> SenderState {
        *self.inner.state.borrow()
    }

    /// Whether every route's sender ended.
    pub fn is_closed(&self) -> bool {
        !self.inner.table().alive()
    }
}

/// Keeps the lane's shown state and switch keyframes current as routes
/// change, stall or come back.
async fn route_watch(
    inner: std::sync::Weak<OutInner>,
    mut version: watch::Receiver<u64>,
    mut closed: Option<watch::Receiver<Option<String>>>,
) {
    loop {
        let Some(out) = inner.upgrade() else { return };
        let now = std::time::Instant::now();
        let (shown, retry, ask, stalled) = {
            let mut table = out.table();
            let stalled = table.check_stall(now);
            let shown = table.shown(now).and_then(|id| table.route(id)).map(|r| r.state.clone());
            (shown, table.next_retry(now), table.switch_keyframe(now), stalled.then(|| table.current_kind()))
        };
        if let Some(Some(kind)) = stalled {
            tracing::info!(
                carrier = kind.name(),
                "media route stalled (no feedback); video moves to the next route"
            );
        }
        if ask {
            let _ = out.keyframes.send(());
        }
        let mut shown = shown;
        if let Some(state) = shown.as_mut() {
            let value = *state.borrow_and_update();
            out.state.send_if_modified(|s| {
                let changed = *s != value;
                *s = value;
                changed
            });
        }
        drop(out);
        let state_changed = async {
            match shown.as_mut() {
                Some(state) => {
                    let _ = state.changed().await;
                }
                None => std::future::pending().await,
            }
        };
        let retry_due = async {
            match retry {
                Some(at) => tokio::time::sleep_until(at.into()).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            changed = version.changed() => if changed.is_err() { return },
            () = state_changed => {}
            () = retry_due => {}
            () = link_closed(&mut closed) => return,
        }
    }
}

impl VideoClaim {
    /// Whether this claim still owns the lane.
    pub fn owns(&self) -> bool {
        *self.owner.borrow() == self.id
    }

    /// Resolves when a newer claim takes the lane.
    pub async fn preempted(&mut self) {
        let id = self.id;
        let _ = self.owner.wait_for(|owner| *owner != id).await;
    }

    /// Sends one frame on the lane's current route. A preempted claim's
    /// frames are dropped; so is a frame that would start a route without
    /// being a keyframe (the source is asked for one).
    pub async fn send(&self, frame: OutgoingFrame) -> Result<(), MediaError> {
        if !self.owns() {
            return Err(MediaError::Closed);
        }
        let keyframe = h264::is_keyframe(&frame.access_unit);
        let (decision, ask, switch) = self.inner.table().decide(keyframe, std::time::Instant::now());
        if ask {
            let _ = self.inner.keyframes.send(());
        }
        if let Some(switch) = switch {
            if switch.from.is_some() {
                tracing::info!(
                    from = switch.from.map(CarrierKind::name),
                    to = switch.to.name(),
                    "media lane switched route at a keyframe"
                );
            }
            self.inner.active.send_replace(Some(switch.to));
            self.inner.bump();
        }
        match decision {
            routes::Decision::Send { frames, .. } => {
                // A route whose sender just ended loses this frame; the next
                // one goes on another route.
                if frames.send((self.id, frame)).await.is_err() {
                    self.inner.bump();
                }
                Ok(())
            }
            routes::Decision::Drop => Ok(()),
            routes::Decision::Closed => Err(MediaError::Closed),
        }
    }

    pub fn state(&self) -> SenderState {
        *self.inner.state.borrow()
    }

    /// Resolves with `true` once the lane is no longer congested (at once if
    /// it is not), or `false` when the lane's sender ended first.
    pub fn uncongested(&self) -> impl std::future::Future<Output = bool> + Send + 'static {
        let mut state = self.inner.state.subscribe();
        async move { state.wait_for(|s| !s.congested).await.is_ok() }
    }
}

impl Drop for VideoClaim {
    fn drop(&mut self) {
        // Release the lane only if this claim still holds it.
        let id = self.id;
        self.inner.owner.send_if_modified(|owner| {
            if *owner == id {
                *owner = 0;
                true
            } else {
                false
            }
        });
    }
}

/// Counters of the phone's receiver.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReceiverStats {
    pub packets: u64,
    pub bytes: u64,
    pub frames: u64,
    pub keyframes: u64,
    /// Frames given up (missing packets past the deadline) or skipped while
    /// waiting for a keyframe.
    pub frames_dropped: u64,
    pub plis_sent: u64,
    pub packets_recovered: u64,
}

/// The phone side of a lane. [`VideoIn::subscribe`] takes the frames from
/// every earlier subscriber; [`VideoIn::subscribe_shared`] gets them beside
/// the others (each viewer then keeps its own tab's, by [`tag`]).
///
/// A lane may have more than one source (the dial's carrier and a WebRTC
/// media session's track, [`VideoIn::add_source`]), each with its own
/// receiver core. The Mac sends on one at a time and moves only at a
/// keyframe, so subscribers get one stream: a source's frames pass only
/// while it is the current one, and a keyframe from another source makes
/// that one current.
#[derive(Clone)]
pub struct VideoIn {
    inner: Arc<InInner>,
}

pub(crate) struct InInner {
    kind: CarrierKind,
    subscribers: Mutex<Vec<mpsc::Sender<ReceivedFrame>>>,
    sources: std::sync::Mutex<Vec<Source>>,
    next_source: std::sync::atomic::AtomicU64,
    /// Which source's frames pass now.
    gate: std::sync::Mutex<Gate>,
    /// The final counters of sources that ended (added to [`VideoIn::stats`]).
    retired: std::sync::Mutex<ReceiverStats>,
}

/// Which source's frames pass (see [`VideoIn`]).
#[derive(Debug, Default)]
pub(crate) struct Gate {
    /// The current source (None before the first frame).
    current: Option<u64>,
    /// Per tab ([`tag`]), the RTP timestamp (that tab's host capture time) of
    /// its newest frame that passed: a keyframe older than it never moves the
    /// gate back (a late keyframe of the route the Mac just left). Each tab's
    /// browser host has its own clock, so timestamps of different tabs never
    /// compare: a tab opened minutes later is minutes behind.
    newest_ts: Vec<(Option<u32>, u32)>,
    /// When a frame last passed, and when the gate last asked for a keyframe
    /// because only another source's frames were coming.
    last_pass: Option<std::time::Instant>,
    last_ask: Option<std::time::Instant>,
}

/// Tabs whose newest timestamp the gate keeps.
const GATE_TABS: usize = 16;

/// A source whose frames are the only ones coming waits this long for a
/// keyframe of its own before the gate asks for one.
const GATE_STUCK: std::time::Duration = std::time::Duration::from_millis(250);

/// What the gate does with one frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admit {
    Pass,
    Reject,
    /// Rejected, and nothing has passed for a while: ask for a keyframe.
    RejectAndAsk,
}

impl Gate {
    /// `tag`: the tab the frame belongs to ([`tag`]; `None` from a Mac that
    /// tags nothing).
    pub(crate) fn admit(
        &mut self,
        id: u64,
        keyframe: bool,
        tag: Option<u32>,
        ts: u32,
        now: std::time::Instant,
    ) -> Admit {
        let newest = self.newest_ts.iter().position(|(t, _)| *t == tag);
        let behind =
            newest.and_then(|at| self.newest_ts.get(at)).map(|(_, newest)| ts.wrapping_sub(*newest) as i32);
        let newer = behind.is_none_or(|d| d > 0);
        let stuck = self.last_pass.is_none_or(|at| now.duration_since(at) >= GATE_STUCK);
        // A still page's keyframes are re-encodes of one picture, with one
        // capture time: on the route the Mac moved to, a keyframe as new as
        // the newest passes once the route it left went quiet. (Right after
        // a switch an equal one is a late copy on the left route.)
        let as_new = behind == Some(0) && stuck;
        let pass = self.current.is_none() || (self.current == Some(id)) || (keyframe && (newer || as_new));
        if pass {
            self.current = Some(id);
            if newer {
                // The tab that passed last goes to the end; the oldest tab is forgotten first.
                if let Some(at) = newest {
                    self.newest_ts.remove(at);
                } else if self.newest_ts.len() >= GATE_TABS {
                    self.newest_ts.remove(0);
                }
                self.newest_ts.push((tag, ts));
            }
            self.last_pass = Some(now);
            return Admit::Pass;
        }
        let due = self.last_ask.is_none_or(|at| now.duration_since(at) >= GATE_STUCK);
        if stuck && due {
            self.last_ask = Some(now);
            return Admit::RejectAndAsk;
        }
        Admit::Reject
    }
}

struct Source {
    id: u64,
    kind: CarrierKind,
    keyframe: mpsc::UnboundedSender<()>,
    stats: watch::Receiver<ReceiverStats>,
    /// The dial's own carrier: its end ends the lane.
    primary: bool,
    running: bool,
}

impl InInner {
    fn sources(&self) -> std::sync::MutexGuard<'_, Vec<Source>> {
        self.sources.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Asks every source's receiver for a keyframe (PLI on its carrier).
    fn request_keyframe(&self) {
        for source in self.sources().iter().filter(|s| s.running) {
            let _ = source.keyframe.send(());
        }
    }

    /// Whether `frame` from source `id` passes: the current source's do, and
    /// a newer keyframe from another source makes that one current. A source
    /// stuck behind the gate (the current one went quiet) asks for a keyframe.
    pub(crate) fn admit(&self, id: u64, frame: &ReceivedFrame) -> bool {
        let tag = tag::peek(&frame.access_unit);
        let mut gate = self.gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let verdict = gate.admit(id, frame.keyframe, tag, frame.rtp_timestamp, std::time::Instant::now());
        if verdict != Admit::Pass {
            // Rejections are normal for a moment after a route switch; one
            // that asks means nothing passed for 250 ms (at most 4 a second).
            let newest = gate.newest_ts.iter().find(|(t, _)| *t == tag).map(|(_, ts)| *ts);
            let level_ask = verdict == Admit::RejectAndAsk;
            let current = gate.current;
            drop(gate);
            if level_ask {
                tracing::info!(
                    source = id,
                    ?current,
                    keyframe = frame.keyframe,
                    tag = ?tag.map(|t| format!("{t:08x}")),
                    ts = frame.rtp_timestamp,
                    ?newest,
                    carrier = ?frame.carrier.map(CarrierKind::name),
                    "media gate: nothing passed for 250 ms; asking for a keyframe"
                );
            } else {
                tracing::debug!(
                    source = id,
                    ?current,
                    keyframe = frame.keyframe,
                    ts = frame.rtp_timestamp,
                    ?newest,
                    "media gate: rejected a frame"
                );
            }
        } else {
            drop(gate);
        }
        if verdict == Admit::RejectAndAsk {
            self.request_keyframe();
        }
        verdict == Admit::Pass
    }

    /// The carrier of the source whose frames pass now.
    fn current_kind(&self) -> Option<CarrierKind> {
        let id = self.gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner).current?;
        self.sources().iter().find(|s| s.id == id).map(|s| s.kind)
    }

    /// A source's receiver ended. Returns whether the lane ended with it
    /// (its primary source, or the last one).
    pub(crate) fn source_ended(&self, id: u64) -> bool {
        let mut sources = self.sources();
        let mut primary = false;
        for source in sources.iter_mut().filter(|s| s.id == id) {
            source.running = false;
            primary = source.primary;
        }
        // An ended media session's source goes; its counters stay in the sum.
        if !primary && let Some(at) = sources.iter().position(|s| s.id == id) {
            let ended = sources.remove(at);
            let s = *ended.stats.borrow();
            let mut retired = self.retired.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            add_stats(&mut retired, &s);
        }
        primary || !sources.iter().any(|s| s.running)
    }
}

impl std::fmt::Debug for VideoIn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VideoIn").field("kind", &self.inner.kind).finish_non_exhaustive()
    }
}

/// A subscriber's frames; it ends when a newer exclusive subscriber takes
/// over or the lane closes.
pub struct VideoFrames {
    pub frames: mpsc::Receiver<ReceivedFrame>,
    inner: Arc<InInner>,
}

impl VideoFrames {
    /// Asks the Mac for a keyframe (PLI): the decoder lost its state.
    pub fn request_keyframe(&self) {
        self.inner.request_keyframe();
    }
}

/// A source added with [`VideoIn::add_source`]; dropping it stops its
/// receiver.
pub struct SourceHandle {
    stop: watch::Sender<Option<String>>,
}

impl Drop for SourceHandle {
    fn drop(&mut self) {
        self.stop.send_replace(Some("source removed".into()));
    }
}

impl VideoIn {
    /// Runs the receiver core on `carrier` until the carrier ends or `closed`
    /// (the link's close state) says the link closed. `rtt` (the link's ping
    /// round trip) sets how long a gap may wait for a NACK.
    pub fn start(
        carrier: Arc<dyn MediaCarrier>,
        config: ReceiverConfig,
        rtt: Option<watch::Receiver<Option<std::time::Duration>>>,
        closed: Option<watch::Receiver<Option<String>>>,
    ) -> Self {
        let inner = Arc::new(InInner {
            kind: carrier.kind(),
            subscribers: Mutex::new(Vec::new()),
            sources: std::sync::Mutex::new(Vec::new()),
            next_source: std::sync::atomic::AtomicU64::new(1),
            gate: std::sync::Mutex::new(Gate::default()),
            retired: std::sync::Mutex::new(ReceiverStats::default()),
        });
        let lane = Self { inner };
        lane.spawn_source(carrier, config, rtt, closed, true);
        lane
    }

    fn spawn_source(
        &self,
        carrier: Arc<dyn MediaCarrier>,
        config: ReceiverConfig,
        rtt: Option<watch::Receiver<Option<std::time::Duration>>>,
        closed: Option<watch::Receiver<Option<String>>>,
        primary: bool,
    ) {
        let id = self.inner.next_source.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (keyframe_tx, keyframe_rx) = mpsc::unbounded_channel();
        let (stats_tx, stats_rx) = watch::channel(ReceiverStats::default());
        self.inner.sources().push(Source {
            id,
            kind: carrier.kind(),
            keyframe: keyframe_tx,
            stats: stats_rx,
            primary,
            running: true,
        });
        tokio::spawn(receiver::run(
            carrier,
            config,
            Arc::clone(&self.inner),
            id,
            keyframe_rx,
            stats_tx,
            rtt,
            closed,
        ));
    }

    /// Adds a source on `carrier` (a WebRTC media session's track) beside
    /// the dial's own, until the handle is dropped, the carrier ends or
    /// `closed` (the link's close state) says the link closed.
    pub fn add_source(
        &self,
        carrier: Arc<dyn MediaCarrier>,
        rtt: Option<watch::Receiver<Option<std::time::Duration>>>,
        mut closed: Option<watch::Receiver<Option<String>>>,
    ) -> SourceHandle {
        let (stop, stop_rx) = watch::channel(None);
        // The source stops on the link's close or the handle's drop.
        if let Some(mut link) = closed.take() {
            let stop = stop.clone();
            tokio::spawn(async move {
                tokio::select! {
                    reason = link.wait_for(Option::is_some) => {
                        let reason = reason.map(|r| r.clone()).unwrap_or(None);
                        stop.send_replace(Some(reason.unwrap_or_else(|| "link closed".into())));
                    }
                    () = stop.closed() => {}
                }
            });
        }
        self.spawn_source(carrier, ReceiverConfig::default(), rtt, Some(stop_rx), false);
        // A new source starts at a keyframe of its own.
        self.inner.request_keyframe();
        SourceHandle { stop }
    }

    /// The carrier the dial negotiated.
    pub fn kind(&self) -> CarrierKind {
        self.inner.kind
    }

    /// The carrier of the frames passing now (the dial's before any).
    pub fn current_kind(&self) -> CarrierKind {
        self.inner.current_kind().unwrap_or(self.inner.kind)
    }

    /// Takes the frames from now on, from every earlier subscriber (and
    /// asks for a keyframe to start from).
    pub async fn subscribe(&self) -> VideoFrames {
        self.subscribe_with(true).await
    }

    /// Gets every frame from now on beside the other subscribers (and asks
    /// for a keyframe to start from). For viewers that keep only their own
    /// tab's frames ([`tag`]).
    pub async fn subscribe_shared(&self) -> VideoFrames {
        self.subscribe_with(false).await
    }

    async fn subscribe_with(&self, exclusive: bool) -> VideoFrames {
        let (tx, rx) = mpsc::channel(8);
        {
            let mut subscribers = self.inner.subscribers.lock().await;
            if exclusive {
                subscribers.clear();
            }
            subscribers.push(tx);
        }
        self.inner.request_keyframe();
        VideoFrames { frames: rx, inner: Arc::clone(&self.inner) }
    }

    /// The counters of every source, summed (ended ones included).
    pub fn stats(&self) -> ReceiverStats {
        let mut sum = *self.inner.retired.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for source in self.inner.sources().iter() {
            add_stats(&mut sum, &source.stats.borrow());
        }
        sum
    }
}

fn add_stats(sum: &mut ReceiverStats, s: &ReceiverStats) {
    sum.packets += s.packets;
    sum.bytes += s.bytes;
    sum.frames += s.frames;
    sum.keyframes += s.keyframes;
    sum.frames_dropped += s.frames_dropped;
    sum.plis_sent += s.plis_sent;
    sum.packets_recovered += s.packets_recovered;
}

/// The lane a dial produced: the Mac's sender or the phone's receiver.
#[derive(Clone, Debug)]
pub enum MediaLane {
    Out(VideoOut),
    In(VideoIn),
}

/// Resolves once `closed` (a link's close state) reports a close, or never
/// without one.
pub(crate) async fn link_closed(closed: &mut Option<watch::Receiver<Option<String>>>) {
    match closed.as_mut() {
        Some(state) => {
            let _ = state.wait_for(Option::is_some).await;
        }
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// verify/hybrid-link.md: the phone's gate between the tunnel and the
    /// media session.
    #[test]
    fn a_late_older_keyframe_of_the_left_route_never_takes_the_gate_back() {
        let t0 = std::time::Instant::now();
        let ms = |n| t0 + std::time::Duration::from_millis(n);
        let (tunnel, session) = (1, 2);
        let mut gate = Gate::default();
        assert_eq!(gate.admit(tunnel, true, None, 1000, ms(0)), Admit::Pass);
        assert_eq!(gate.admit(tunnel, false, None, 2500, ms(16)), Admit::Pass);
        // The Mac switches at keyframe K (ts 4000) on the session...
        assert_eq!(gate.admit(session, true, None, 4000, ms(30)), Admit::Pass);
        // ...and an older keyframe K' (ts 3000) it sent on the tunnel just
        // before arrives late over TURN over TLS: it does not pass.
        assert_eq!(gate.admit(tunnel, true, None, 3000, ms(40)), Admit::Reject);
        assert_eq!(gate.admit(tunnel, false, None, 3500, ms(45)), Admit::Reject);
        assert_eq!(gate.admit(session, false, None, 5500, ms(46)), Admit::Pass);
        // Falling back: a newer keyframe from the tunnel takes it.
        assert_eq!(gate.admit(tunnel, true, None, 9000, ms(300)), Admit::Pass);
        assert_eq!(gate.admit(session, false, None, 8000, ms(301)), Admit::Reject);
    }

    /// Each tab's browser host has its own capture clock (its process start),
    /// so a tab opened later has RTP timestamps minutes behind the tab before.
    /// After it takes the lane, a route switch at its keyframe must pass: it
    /// is not a late keyframe of the route the Mac left (2026-10-24 freeze:
    /// the phone rejected every keyframe and asked again 4 times a second).
    #[test]
    fn a_later_tabs_keyframe_on_the_next_route_passes_although_its_clock_is_behind() {
        let t0 = std::time::Instant::now();
        let ms = |n| t0 + std::time::Duration::from_millis(n);
        let (tunnel, session) = (1, 2);
        let (old_tab, new_tab) = (Some(0xa), Some(0xb));
        let minutes = 3 * 60 * 90_000u32;
        let mut gate = Gate::default();
        assert_eq!(gate.admit(session, true, old_tab, minutes, ms(0)), Admit::Pass);
        assert_eq!(gate.admit(session, false, old_tab, minutes + 1500, ms(16)), Admit::Pass);
        // The new tab takes the lane on the same route.
        assert_eq!(gate.admit(session, true, new_tab, 1000, ms(30)), Admit::Pass);
        assert_eq!(gate.admit(session, false, new_tab, 2500, ms(46)), Admit::Pass);
        // The media session fails: the Mac moves to the tunnel at a keyframe.
        assert_eq!(gate.admit(tunnel, true, new_tab, 4000, ms(300)), Admit::Pass);
        assert_eq!(gate.admit(tunnel, false, new_tab, 5500, ms(316)), Admit::Pass);
        // A late keyframe of the same tab on the route it left still does not pass.
        assert_eq!(gate.admit(session, true, new_tab, 3000, ms(320)), Admit::Reject);
    }

    /// The single-tab freeze (verify/browser-freeze/results-2.md): on a still
    /// page the host paints nothing new, so every keyframe a request gets is
    /// a re-encode with the same capture time. The first went out on the
    /// route the Mac left; the copies on the new route have the same
    /// timestamp, and the gate rejected them all and asked again forever.
    #[test]
    fn a_still_pages_keyframe_with_the_same_timestamp_on_the_next_route_passes() {
        let t0 = std::time::Instant::now();
        let ms = |n| t0 + std::time::Duration::from_millis(n);
        let (tunnel, track) = (1, 2);
        let tab = Some(0x7a3d_70b3);
        let mut gate = Gate::default();
        assert_eq!(gate.admit(tunnel, true, tab, 58_241_389, ms(0)), Admit::Pass);
        // The Mac switches at a keyframe of the same still picture.
        assert_eq!(gate.admit(track, true, tab, 58_241_389, ms(10)), Admit::Reject);
        // Asked again: another copy, same timestamp, once the tunnel went quiet.
        assert_eq!(gate.admit(track, true, tab, 58_241_389, ms(270)), Admit::Pass);
        assert_eq!(gate.admit(track, false, tab, 58_241_400, ms(290)), Admit::Pass);
        // A late copy on the route it left, right after, does not take it back.
        assert_eq!(gate.admit(tunnel, true, tab, 58_241_400, ms(300)), Admit::Reject);
    }

    #[test]
    fn a_source_stuck_behind_the_gate_asks_for_a_keyframe() {
        let t0 = std::time::Instant::now();
        let ms = |n| t0 + std::time::Duration::from_millis(n);
        let mut gate = Gate::default();
        assert_eq!(gate.admit(2, true, None, 1000, ms(0)), Admit::Pass);
        // The session went quiet; only the tunnel's P frames come.
        assert_eq!(gate.admit(1, false, None, 2000, ms(100)), Admit::Reject);
        assert_eq!(gate.admit(1, false, None, 3000, ms(260)), Admit::RejectAndAsk);
        assert_eq!(gate.admit(1, false, None, 3500, ms(300)), Admit::Reject, "asked at most every 250 ms");
        assert_eq!(gate.admit(1, false, None, 4000, ms(520)), Admit::RejectAndAsk);
        assert_eq!(gate.admit(1, true, None, 4500, ms(540)), Admit::Pass);
    }

    #[test]
    fn a_timestamp_slightly_ahead_of_the_clock_estimate_is_now() {
        let now = 50_000_000;
        assert_eq!(capture_us_from_rtp(rtp_timestamp(now + 2_000), now), now);
        assert_eq!(capture_us_from_rtp(rtp_timestamp(now), now), now);
    }

    #[test]
    fn rtp_timestamps_round_trip_to_the_capture_time() {
        for capture in [0u64, 1_234_567, 47_721_858_833, 900_000_000_000] {
            for lag in [0u64, 16_000, 900_000] {
                let back = capture_us_from_rtp(rtp_timestamp(capture), capture + lag);
                assert!(back.abs_diff(capture) <= 12, "capture {capture} lag {lag} back {back}");
            }
        }
    }
}
