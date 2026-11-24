//! Dialers: each turns a signaling session into one reliable byte stream
//! that a [`crate::Link`] runs on. The phone dials; the Mac answers the
//! first signal of a new session.

use std::any::Any;
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot, watch};

use crate::api::IceServer;
use crate::link::{Link, LinkConfig, Role};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient, SignalingEvent};

pub mod diagnosis;
pub mod relay;
pub(crate) mod turn;
/// Measurement support (cmux-mobile-path-probe).
pub use turn::{TimedAllocation, TurnTransport, timed_allocation};
pub mod webrtc;
pub mod wireguard;

/// The transport switch (PROTOCOL.md "Transport switch").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransportKind {
    WebRtc,
    WireGuard,
}

impl TransportKind {
    /// The transport a session's first signal asks for, if it starts one.
    /// A media session's offer (`mediaFor`) starts no link: see
    /// [`media_session_for`].
    pub fn for_first_signal(payload: &SignalPayload) -> Option<Self> {
        match payload {
            SignalPayload::WebrtcOffer { media_for: Some(_), .. } => None,
            SignalPayload::WebrtcOffer { .. } => Some(Self::WebRtc),
            SignalPayload::WgInit { .. } | SignalPayload::WgRelay { .. } => Some(Self::WireGuard),
            _ => None,
        }
    }

    pub fn dialer(self) -> Box<dyn Dialer> {
        match self {
            Self::WebRtc => Box::new(webrtc::WebRtcDialer),
            Self::WireGuard => Box::new(wireguard::WireGuardDialer),
        }
    }
}

/// The WireGuard link a media session's first signal is for
/// (PROTOCOL.md "Media session"), if it is one.
pub fn media_session_for(payload: &SignalPayload) -> Option<&str> {
    match payload {
        SignalPayload::WebrtcOffer { media_for: Some(link), .. } => Some(link),
        _ => None,
    }
}

/// The lane a WireGuard link lists when its sides support a WebRTC media
/// session beside it (PROTOCOL.md "Media session").
pub const WEBRTC_MEDIA_LANE: &str = "webrtc-media";

/// How the link's bytes travel right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinkPath {
    /// Peer to peer (host, server-reflexive or hole-punched UDP).
    Direct,
    /// Through a TURN server, UDP on both legs.
    Turn,
    /// Through a TURN server whose client leg is TCP or TLS (a network that
    /// blocks UDP); WireGuard only.
    TurnTls,
    /// Through cmux's own WebSocket relay over HTTPS (PROTOCOL.md "WebSocket
    /// relay"), the last resort when neither UDP nor TURN gets through;
    /// WireGuard only.
    HttpsRelay,
    /// No working route at the moment (WireGuard: nothing from the peer
    /// authenticated yet, or every route was refused).
    NoPath,
}

impl LinkPath {
    /// The path's wire name (`link_stat`, the debug probes): `direct`, `turn`, `turn-tls`,
    /// `https-relay`, `none`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Turn => "turn",
            Self::TurnTls => "turn-tls",
            Self::HttpsRelay => "https-relay",
            Self::NoPath => "none",
        }
    }
}

impl TransportKind {
    /// The transport's wire name (`link_stat`): `webrtc` or `wireguard`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WebRtc => "webrtc",
            Self::WireGuard => "wireguard",
        }
    }
}

/// A [`DialOptions::impair_inbound`] hook: whether the datagram came through
/// this side's TURN allocation, where from, and its size in bytes, to its fate
/// (`None` drops it, `Some(delay)` delivers it that much later).
#[doc(hidden)]
pub type ImpairInbound = fn(bool, &std::net::SocketAddr, usize) -> Option<Duration>;

#[derive(Debug, Clone)]
pub struct DialOptions {
    /// ICE servers (from `GET /v1/ice`). STUN entries also serve WireGuard
    /// endpoint discovery. Empty means host candidates only.
    pub ice_servers: Vec<IceServer>,
    /// Offer loopback candidates and endpoints (tests and same-host runs).
    pub include_loopback: bool,
    /// Never offer or use addresses in 100.64.0.0/10 (Tailscale and other
    /// carrier-grade NAT overlays), so a test measures the public path.
    pub exclude_cgnat: bool,
    /// Relay only (the app's debug "simulate distant network" mode): skip
    /// every direct path. WebRTC uses ICE transport policy `relay` (only
    /// TURN candidates from `ice_servers`). WireGuard never sends plain
    /// UDP: it offers only its TURN relayed address and reaches the peer
    /// through TURN (path `turn`, or `turn-tls` when the allocation had to
    /// use TCP or TLS). Either fails the dial at once without a TURN server.
    pub relay_only: bool,
    /// UDP blocked (the app's debug "simulate a network that blocks UDP"
    /// mode, and the rig's): WireGuard neither sends nor accepts plain UDP
    /// and skips TURN over UDP, so its only path is a TURN allocation over
    /// TLS (or TCP), path `turn-tls`; without a `turns:` or TCP `turn:`
    /// server the dial fails at once. WebRTC ignores it (webrtc-rs has no
    /// TURN over TCP or TLS).
    pub block_udp: bool,
    /// cmux's WebSocket relay (PROTOCOL.md "WebSocket relay"): where this
    /// side joins it when neither plain UDP nor TURN reaches the peer.
    /// `None`: no relay (tests, tools, and the dial fails as before).
    pub relay: Option<relay::RelayEndpoint>,
    /// Debug "Relay via cmux (HTTPS) only" (and the rig's
    /// `CMUX_MOBILE_DEV_FORCE_RELAY`): WireGuard sends no plain UDP, takes no
    /// TURN allocation, and joins the relay at once, so the link rides it
    /// (path `https-relay`); without [`Self::relay`] the dial fails at once.
    pub force_relay: bool,
    /// Join the relay as the dial starts (`relay: "first"`, PROTOCOL.md
    /// "WebSocket relay") when the peer offers that too, rather than 3 s
    /// after nothing reached it. On by default; off dials as a build before
    /// relay-first did (tests of the older join rules).
    pub relay_first: bool,
    /// Where a WireGuard dial records each path's failure, for the error it
    /// returns when none works ([`DialError::Blocked`]). Shared by clones.
    pub diagnosis: diagnosis::Diagnosis,
    /// Test support: how long another confirmed route carries the session
    /// before the relay socket is let go (default 60 s).
    #[doc(hidden)]
    pub relay_leave_after: Option<Duration>,
    /// Test support: trust these roots, not the public web PKI, for TURN
    /// over TLS (a test TURN server's self-signed certificate).
    #[doc(hidden)]
    pub turn_tls_roots: Option<std::sync::Arc<rustls::RootCertStore>>,
    /// Test support: WireGuard silently drops every UDP datagram this side
    /// sends, as when the OS refuses the route (macOS Local Network
    /// privacy) or a firewall drops outbound UDP. Inbound UDP still works.
    #[doc(hidden)]
    pub drop_outbound_udp: bool,
    /// Test support: WireGuard's plain UDP sends to addresses this returns
    /// true for fail as refused by the OS (`EHOSTUNREACH`, as macOS Local
    /// Network privacy answers for LAN peers).
    #[doc(hidden)]
    pub refuse_udp_to: Option<fn(&std::net::SocketAddr) -> bool>,
    /// Test support: WireGuard's plain UDP to addresses this returns true
    /// for is silently lost (the OS takes it, nothing arrives), as when a
    /// side's route to the LAN is broken but the internet works.
    #[doc(hidden)]
    pub drop_udp_to: Option<fn(&std::net::SocketAddr) -> bool>,
    /// Test support: called with each plain UDP datagram's length as
    /// WireGuard hands it to the OS (the bytes a radio sends).
    #[doc(hidden)]
    pub on_udp_sent: Option<fn(&std::net::SocketAddr, usize)>,
    /// Test support: WireGuard drops plain UDP from any address it has not
    /// sent plain UDP to, as an address-restricted NAT in front of this
    /// side would. A peer that roams then reaches this side only after
    /// announcing its new endpoints.
    #[doc(hidden)]
    pub restrict_inbound_udp: bool,
    /// Test and measurement support: what WireGuard does with each datagram
    /// it receives, by whether it came through this side's TURN allocation
    /// and where from, and its size in bytes: `None` drops it (a cut path,
    /// a loss), `Some(delay)` delivers it that much later, ordered by when
    /// it is due (a path's one-way latency; jitter reorders, as on UDP).
    /// `testing::shape_by_profile` (feature `testing`) plays a named phone
    /// link profile.
    #[doc(hidden)]
    pub impair_inbound: Option<ImpairInbound>,
    /// Offer and accept the input lane (PROTOCOL.md "Lanes"): a second
    /// stream for keystrokes and resizes. Off only to measure or test the
    /// single-stream behavior of older peers.
    pub input_lane: bool,
    /// Offer (phone) or accept (Mac) the media lane: browser video as RTP
    /// (verify/browser-video-track.md). On WebRTC it is a video track on the
    /// link's peer connection; on WireGuard it is RTP on overlay UDP inside
    /// the tunnel ([`crate::media::wireguard`]).
    pub video_lane: bool,
    /// WireGuard with the media lane: offer (phone) or accept (Mac) a WebRTC
    /// media session beside the link ([`WEBRTC_MEDIA_LANE`],
    /// [`crate::hybrid`]), which carries browser video while it works.
    pub webrtc_media: bool,
    /// Test and measurement support (Mac side): drop this many of every
    /// 1000 outgoing video RTP packets after the NACK responder kept them.
    #[doc(hidden)]
    pub video_drop_permille: u32,
    /// Test and measurement support (Mac side, WireGuard): a bottleneck of
    /// this many bits per second for outgoing video RTP (0: none).
    #[doc(hidden)]
    pub video_cap_bps: u64,
    /// Test support (Mac side, WireGuard): drop every outgoing video RTP
    /// packet first sent from `.0` after the lane opens for `.1`, and every
    /// resend of those (a loss no NACK recovers).
    #[doc(hidden)]
    pub video_blackout: Option<(Duration, Duration)>,
    /// Measurement support: keep webrtc-rs's stock nomination waits
    /// (srflx 500 ms, prflx 1 s, relay 2 s) for before/after comparisons.
    #[doc(hidden)]
    pub stock_ice_waits: bool,
    /// WireGuard: the person's Settings > Transport > Ultra Mode (Off, Auto
    /// or Always; Auto by default, the Mac's side of the link too). Auto
    /// sends no extra data on a clean link and Reed-Solomon repair data from
    /// the first loss, capped while the phone's network is cellular
    /// ([`wireguard::set_cellular_path`], [`wireguard::ultra_for_dial`]);
    /// Always sends it on every datagram, about 2-3x the bytes.
    /// `CMUX_WG_ULTRA` still wins over it.
    pub ultra: UltraSetting,
    /// Settings → Transport → Align Keepalives (phone only, off by default):
    /// the WireGuard tunnel sends no persistent keepalive, because the link
    /// dialed with [`crate::LinkConfig::aligned`] pings on every 10 s beat
    /// instead ([`crate::keepalive`]).
    pub aligned_keepalives: bool,
    /// Bound on the whole dial or answer.
    pub timeout: Duration,
    /// Dial side, WebRTC: how long an offer waits for the Mac's answer. An
    /// offer sent while the Mac's host was down or restarting is never
    /// answered; this ends that dial long before `timeout` (termfix r13 D2b).
    pub answer_timeout: Duration,
    /// Where the dial or answer records its steps (`offer_sent`,
    /// `ice_connected`, `dtls_connected`, `channel_open`, ...).
    pub timeline: crate::Timeline,
}

/// Settings > Transport > Ultra Mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum UltraSetting {
    /// No repair data.
    Off,
    /// No extra data on a clean link; repair data within about one round
    /// trip of a loss, capped on cellular.
    #[default]
    Auto,
    /// Repair data on every datagram, cellular too.
    Always,
}

impl UltraSetting {
    /// `"off"`, `"auto"` or `"always"` (what the app stores); anything else
    /// is the default, Auto.
    pub fn parse(text: &str) -> Self {
        match text.trim() {
            "off" => Self::Off,
            "always" => Self::Always,
            _ => Self::Auto,
        }
    }
}

impl Default for DialOptions {
    fn default() -> Self {
        Self {
            ice_servers: Vec::new(),
            relay: None,
            force_relay: false,
            relay_first: true,
            diagnosis: diagnosis::Diagnosis::default(),
            relay_leave_after: None,
            include_loopback: false,
            exclude_cgnat: false,
            relay_only: false,
            block_udp: false,
            turn_tls_roots: None,
            drop_outbound_udp: false,
            refuse_udp_to: None,
            drop_udp_to: None,
            on_udp_sent: None,
            restrict_inbound_udp: false,
            impair_inbound: None,
            input_lane: true,
            video_lane: false,
            webrtc_media: false,
            video_drop_permille: 0,
            video_cap_bps: 0,
            video_blackout: None,
            stock_ice_waits: false,
            ultra: UltraSetting::Auto,
            aligned_keepalives: false,
            timeout: Duration::from_secs(25),
            answer_timeout: Duration::from_secs(8),
            timeline: crate::Timeline::new(),
        }
    }
}

/// The number of TURN URLs (`turn:` or `turns:`) among `servers`.
pub fn turn_url_count(servers: &[IceServer]) -> usize {
    servers
        .iter()
        .flat_map(|server| &server.urls)
        .filter(|url| url.starts_with("turn:") || url.starts_with("turns:"))
        .count()
}

/// The peer address a direct path's bytes go to, for telling the LAN from the internet:
/// `None` on a relayed path, before a route, or where the transport does not say.
pub type PeerAddr = watch::Receiver<Option<std::net::IpAddr>>;

/// A peer address on this network: private, link-local or loopback (IPv4, or IPv6 unique-local
/// and link-local). Tailnet and CGNAT addresses are routed, so they are not.
pub fn is_lan(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => v4.is_private() || v4.is_link_local() || v4.is_loopback(),
        std::net::IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_lan(std::net::IpAddr::V4(v4)),
            None => {
                let first = v6.segments()[0];
                v6.is_loopback()
                    || (first & 0xffc0) == 0xfe80
                    || ((first & 0xfe00) == 0xfc00 && !is_cgnat(ip))
            }
        },
    }
}

/// The route a link's bytes take, as one word: `direct-lan` (a peer address on this network),
/// `direct-wan` (routed: the internet, a tailnet, CGNAT), `direct` (direct, address unknown),
/// `relay` (a TURN server, over UDP, TCP or TLS) or `none`.
pub fn route_name(path: LinkPath, peer: Option<std::net::IpAddr>) -> &'static str {
    match (path, peer) {
        (LinkPath::Direct, Some(ip)) if is_lan(ip) => "direct-lan",
        (LinkPath::Direct, Some(_)) => "direct-wan",
        (LinkPath::Direct, None) => "direct",
        (LinkPath::Turn | LinkPath::TurnTls | LinkPath::HttpsRelay, _) => "relay",
        (LinkPath::NoPath, _) => "none",
    }
}

/// Whether `ip` is in 100.64.0.0/10 (Tailscale and other CGNAT overlays).
pub fn is_cgnat(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            a == 100 && (64..128).contains(&b)
        }
        // Tailscale's IPv6 range, fd7a:115c:a1e0::/48.
        std::net::IpAddr::V6(v6) => v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// Where a direct path's peer address is, as one word: `lan` (on this network, [`is_lan`]),
/// `tailnet` (100.64.0.0/10 or Tailscale's IPv6 range, [`is_cgnat`]: a tailnet, or a carrier's
/// CGNAT), `wan` (any other routed address) or empty (relayed, no route yet, or unknown). The
/// phone's DEBUG hand-off receipt names it, so a dev link over Tailscale is never taken for the
/// LAN or internet path a user without Tailscale gets.
pub fn peer_scope(peer: Option<std::net::IpAddr>) -> &'static str {
    // An IPv4-mapped IPv6 peer is its IPv4 address.
    let peer = peer.map(|ip| match ip {
        std::net::IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, std::net::IpAddr::V4),
        ip => ip,
    });
    match peer {
        Some(ip) if is_cgnat(ip) => "tailnet",
        Some(ip) if is_lan(ip) => "lan",
        Some(_) => "wan",
        None => "",
    }
}

/// A byte stream a link can run on.
pub trait LinkStream: AsyncRead + AsyncWrite + Send + Unpin + 'static {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin + 'static> LinkStream for T {}

/// A dialed or answered transport.
pub struct Dialed {
    pub stream: Box<dyn LinkStream>,
    pub path: watch::Receiver<LinkPath>,
    pub peer: PeerAddr,
    /// Holds the peer connection or tunnel open.
    pub guard: Box<dyn Any + Send>,
    /// The input lane's stream, when both sides negotiated one. It may open
    /// after the main stream; a dropped sender means it failed.
    pub lane: Option<oneshot::Receiver<Box<dyn LinkStream>>>,
    /// The media lane's carrier, when both sides negotiated one.
    pub media: Option<PendingMedia>,
    /// Both sides listed [`WEBRTC_MEDIA_LANE`] (WireGuard).
    pub webrtc_media: bool,
    /// Holds the transport while the link is parked (WireGuard); `None`
    /// when it cannot be held (WebRTC).
    pub hold: Option<crate::link::HoldHook>,
    /// Pings and pongs as datagrams, when both sides listed
    /// [`crate::link::LIVENESS_LANE`] (WireGuard).
    pub liveness: Option<crate::link::LivenessDatagrams>,
}

/// A negotiated media carrier; the link starts its core once it runs (the
/// phone's receiver needs the link's round trip).
pub enum PendingMedia {
    Send(std::sync::Arc<dyn crate::media::MediaCarrier>),
    Receive(std::sync::Arc<dyn crate::media::MediaCarrier>),
}

impl PendingMedia {
    fn start(self, link: &Link) -> crate::media::MediaLane {
        match self {
            Self::Send(carrier) => crate::media::MediaLane::Out(crate::media::VideoOut::start(
                carrier,
                crate::media::SenderConfig::default(),
                Some(link.closed_state()),
            )),
            Self::Receive(carrier) => crate::media::MediaLane::In(crate::media::VideoIn::start(
                carrier,
                crate::media::ReceiverConfig::default(),
                Some(link.rtt()),
                Some(link.closed_state()),
            )),
        }
    }
}

/// The lanes this side offers in its first signal or answer. `video`: this
/// transport carries the media lane and this side offers (or attached) it.
/// `webrtc_media`: this side offers (or accepts) a WebRTC media session.
pub(crate) fn offered_lanes(options: &DialOptions, video: bool, webrtc_media: bool) -> Vec<String> {
    let mut lanes = Vec::new();
    if options.input_lane {
        lanes.push(crate::link::INPUT_LANE.to_owned());
    }
    if video {
        lanes.push(crate::media::VIDEO_LANE.to_owned());
    }
    if video && webrtc_media {
        lanes.push(WEBRTC_MEDIA_LANE.to_owned());
    }
    lanes
}

/// Whether the peer listed the WebRTC media session lane.
pub(crate) fn webrtc_media_listed(peer_lanes: &[String]) -> bool {
    peer_lanes.iter().any(|lane| lane == WEBRTC_MEDIA_LANE)
}

/// Whether the peer listed the media lane.
pub(crate) fn video_lane_listed(peer_lanes: &[String]) -> bool {
    peer_lanes.iter().any(|lane| lane == crate::media::VIDEO_LANE)
}

/// Whether both sides support the input lane.
pub(crate) fn input_lane_agreed(options: &DialOptions, peer_lanes: &[String]) -> bool {
    options.input_lane && peer_lanes.iter().any(|lane| lane == crate::link::INPUT_LANE)
}

/// Attach the lane to `link` when it opens, or fall back when it fails.
fn follow_lane(link: &Link, lane: Option<oneshot::Receiver<Box<dyn LinkStream>>>) {
    let Some(lane) = lane else { return };
    link.expect_input_lane();
    let link = link.clone();
    tokio::spawn(async move {
        tokio::select! {
            stream = lane => match stream {
                Ok(stream) => link.attach_input_lane(stream),
                Err(_) => link.input_lane_failed("the lane's stream did not open"),
            },
            _ = link.closed() => {}
        }
    });
}

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum DialError {
    #[error("signaling: {0}")]
    Signaling(String),
    #[error("refused by the backend: {code}: {message}")]
    Refused { code: String, message: String },
    #[error("the peer ended the session: {0}")]
    Bye(String),
    #[error("timed out")]
    Timeout,
    #[error("transport: {0}")]
    Transport(String),
    #[error("unexpected signal: {0}")]
    Unexpected(String),
    /// No way to the peer worked, and each one's failure is known
    /// (PROTOCOL.md "When no path works"): the network blocks the link.
    #[error("no path to the peer: {0}")]
    Blocked(Box<diagnosis::PathFailures>),
}

pub type DialFuture<'a> = Pin<Box<dyn Future<Output = Result<Dialed, DialError>> + Send + 'a>>;

/// One transport, both directions.
pub trait Dialer: Send + Sync {
    fn kind(&self) -> TransportKind;

    /// Phone side: start session `session_id` toward `mac` and return the
    /// stream once it is open.
    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a>;

    /// Mac side: answer `first`, the opening signal of a new session.
    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a>;
}

/// The signals and relay frames of one session, plus backend errors.
pub struct SessionEvents {
    pub session: mpsc::UnboundedReceiver<SessionEvent>,
    pub backend: tokio::sync::broadcast::Receiver<SignalingEvent>,
    /// This session's id: a backend error naming another session (say a
    /// relay frame of an ended tunnel answered `offline`) is not ours.
    pub session_id: String,
}

impl SessionEvents {
    pub fn subscribe(signaling: &SignalingClient, session_id: &str) -> Self {
        Self {
            backend: signaling.events(),
            session: signaling.subscribe(session_id),
            session_id: session_id.to_owned(),
        }
    }

    /// The next session event; a backend error for this session (or for no
    /// session in particular) or a disconnect is an error.
    pub async fn next(&mut self) -> Result<SessionEvent, DialError> {
        loop {
            tokio::select! {
                event = self.session.recv() => {
                    return match event {
                        Some(SessionEvent::Disconnected) | None => Err(DialError::Signaling("signaling socket closed".into())),
                        Some(event) => Ok(event),
                    };
                }
                event = self.backend.recv() => match event {
                    Ok(SignalingEvent::Error { code, message, session_id })
                        if session_id.as_ref().is_none_or(|id| *id == self.session_id) =>
                    {
                        return Err(DialError::Refused { code, message });
                    }
                    Ok(SignalingEvent::Disconnected(reason)) => return Err(DialError::Signaling(reason)),
                    _ => {}
                },
            }
        }
    }
}

/// A connected link and how it travels.
pub struct Connected {
    pub link: Link,
    pub transport: TransportKind,
    pub path: watch::Receiver<LinkPath>,
    /// The peer address of a direct path ([`route_name`]).
    pub peer: PeerAddr,
    pub session_id: String,
    /// Both sides agreed on a WebRTC media session beside this (WireGuard)
    /// link; the phone opens it on demand ([`crate::hybrid`]).
    pub webrtc_media: bool,
}

/// Phone side: dial `mac` over `kind` and run a link on the result.
pub async fn connect(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link_config: LinkConfig,
) -> Result<Connected, DialError> {
    refuse_unreachable(kind, options)?;
    connect_on(signaling, mac, kind, options, link_config, None).await
}

/// Phone side, a redial: `signaling` is the signaling reconnect, and the
/// dial ([`connect`]) follows it on the client it gives. A WireGuard dial's
/// TURN allocation starts now, beside the reconnect, instead of after it:
/// its round trips overlap the reconnect's. Nothing is allocated before
/// this is called, and an allocation the dial never takes (the reconnect
/// failed, or this future was dropped) is released at once. Marks
/// `signaling_connected` when the reconnect is done, then [`connect`]'s
/// marks (`turn_early_allocated` when the allocation is in hand). Returns
/// the client with the link.
pub async fn connect_after<E: std::fmt::Display>(
    signaling: impl Future<Output = Result<SignalingClient, E>>,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link_config: LinkConfig,
) -> Result<(SignalingClient, Connected), DialError> {
    refuse_unreachable(kind, options)?;
    let early = (kind == TransportKind::WireGuard).then(|| wireguard::EarlyTurn::start(options));
    let signaling = signaling.await.map_err(|error| DialError::Signaling(error.to_string()))?;
    options.timeline.mark("signaling_connected");
    let connected = connect_on(&signaling, mac, kind, options, link_config, early).await?;
    Ok((signaling, connected))
}

/// A dial that cannot work with what `options` offer fails at once.
fn refuse_unreachable(kind: TransportKind, options: &DialOptions) -> Result<(), DialError> {
    if options.relay_only && kind == TransportKind::WebRtc && turn_url_count(&options.ice_servers) == 0 {
        return Err(DialError::Transport(
            "relay only needs a TURN server, and the service offered none".into(),
        ));
    }
    if kind == TransportKind::WireGuard && options.force_relay && options.relay.is_none() {
        return Err(DialError::Transport(
            "relay via cmux needs the service's relay, and there is none".into(),
        ));
    }
    // Without a TURN server the debug UDP-blocked mode still has the relay;
    // relay only is about TURN, so it still needs one.
    let relay_covers = options.force_relay || (options.relay.is_some() && !options.relay_only);
    if kind == TransportKind::WireGuard
        && !relay_covers
        && let Some(reason) = wireguard::missing_turn(options)
    {
        return Err(DialError::Transport(reason.into()));
    }
    Ok(())
}

/// [`connect`] on `signaling`, a WireGuard dial taking the TURN allocation
/// `early` when a redial started one.
async fn connect_on(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link_config: LinkConfig,
    early: Option<wireguard::EarlyTurn>,
) -> Result<Connected, DialError> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let events = SessionEvents::subscribe(signaling, &session_id);
    let dialer = kind.dialer();
    options.timeline.mark("dial_start");
    let dial = match early {
        Some(early) => wireguard::dial_wireguard(signaling, mac, &session_id, events, options, Some(early)),
        None => dialer.dial(signaling, mac, &session_id, events, options),
    };
    // A WireGuard dial whose last way (the relay) failed too ends then, with
    // why, instead of waiting out its timeout.
    let result = tokio::select! {
        result = tokio::time::timeout(options.timeout, dial) => result,
        () = options.diagnosis.given_up() => Ok(Err(options.diagnosis.blocked())),
    };
    let dialed = match result {
        Ok(Ok(dialed)) => dialed,
        Ok(Err(error)) => {
            signaling.unsubscribe(&session_id);
            let _ = signaling.send_signal(mac, &session_id, SignalPayload::Bye { reason: error.to_string() });
            return Err(error);
        }
        Err(_) => {
            signaling.unsubscribe(&session_id);
            let _ = signaling.send_signal(mac, &session_id, SignalPayload::Bye { reason: "timeout".into() });
            return Err(options.diagnosis.timed_out(kind));
        }
    };
    let link = Link::new(dialed.stream, Role::Phone, link_config, Some(dialed.guard));
    if let Some(hold) = dialed.hold {
        link.set_hold_hook(hold);
    }
    follow_lane(&link, dialed.lane);
    if let Some(liveness) = dialed.liveness {
        link.attach_liveness_datagrams(liveness);
    }
    if let Some(media) = dialed.media {
        link.attach_media(media.start(&link));
    }
    options.timeline.mark("link_ready");
    Ok(Connected {
        link,
        transport: kind,
        path: dialed.path,
        peer: dialed.peer,
        session_id,
        webrtc_media: dialed.webrtc_media,
    })
}

/// Mac side: answer `first` and run a link on the result.
pub async fn answer(
    signaling: &SignalingClient,
    first: SignalEnvelope,
    events: SessionEvents,
    options: &DialOptions,
    link_config: LinkConfig,
) -> Result<Connected, DialError> {
    let kind = TransportKind::for_first_signal(&first.payload)
        .ok_or_else(|| DialError::Unexpected("first signal does not start a session".into()))?;
    let session_id = first.session_id.clone();
    let peer = first.from.clone();
    let dialer = kind.dialer();
    // The Mac never ends its answer early on the diagnosis: the phone says why,
    // and a `bye` from here would only race the phone's own verdict.
    let result =
        tokio::time::timeout(options.timeout, dialer.answer(signaling, first, events, options)).await;
    let dialed = match result {
        Ok(Ok(dialed)) => dialed,
        Ok(Err(error)) => {
            // No bye for an early cue that no `wg-init` followed.
            if !matches!(&error, DialError::Bye(reason) if reason == wireguard::EARLY_CUE_STALE) {
                let _ = signaling.send_signal(
                    &peer,
                    &session_id,
                    SignalPayload::Bye { reason: error.to_string() },
                );
            }
            return Err(error);
        }
        Err(_) => {
            let _ =
                signaling.send_signal(&peer, &session_id, SignalPayload::Bye { reason: "timeout".into() });
            return Err(options.diagnosis.timed_out(kind));
        }
    };
    let link = Link::new(dialed.stream, Role::Mac, link_config, Some(dialed.guard));
    if let Some(hold) = dialed.hold {
        link.set_hold_hook(hold);
    }
    follow_lane(&link, dialed.lane);
    if let Some(liveness) = dialed.liveness {
        link.attach_liveness_datagrams(liveness);
    }
    if let Some(media) = dialed.media {
        link.attach_media(media.start(&link));
    }
    options.timeline.mark("link_ready");
    Ok(Connected {
        link,
        transport: kind,
        path: dialed.path,
        peer: dialed.peer,
        session_id,
        webrtc_media: dialed.webrtc_media,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_route_is_lan_wan_or_relay_by_its_path_and_peer_address() {
        let ip = |text: &str| Some(text.parse::<std::net::IpAddr>().unwrap());
        // A Mac on ethernet and a phone on the same home wifi.
        assert_eq!(route_name(LinkPath::Direct, ip("192.168.1.23")), "direct-lan");
        assert_eq!(route_name(LinkPath::Direct, ip("10.0.0.5")), "direct-lan");
        assert_eq!(route_name(LinkPath::Direct, ip("169.254.3.4")), "direct-lan");
        assert_eq!(route_name(LinkPath::Direct, ip("fe80::1")), "direct-lan");
        assert_eq!(route_name(LinkPath::Direct, ip("fd12:3456::1")), "direct-lan");
        assert_eq!(route_name(LinkPath::Direct, ip("::ffff:192.168.1.23")), "direct-lan");
        // A hole-punched public address, a carrier's CGNAT, a tailnet: routed.
        assert_eq!(route_name(LinkPath::Direct, ip("203.0.113.9")), "direct-wan");
        assert_eq!(route_name(LinkPath::Direct, ip("100.101.102.103")), "direct-wan");
        assert_eq!(route_name(LinkPath::Direct, ip("fd7a:115c:a1e0::1")), "direct-wan");
        assert_eq!(route_name(LinkPath::Direct, ip("2001:db8::1")), "direct-wan");
        assert_eq!(route_name(LinkPath::Direct, None), "direct");
        assert_eq!(route_name(LinkPath::Turn, ip("192.168.1.23")), "relay");
        assert_eq!(route_name(LinkPath::TurnTls, None), "relay");
        assert_eq!(route_name(LinkPath::NoPath, None), "none");
    }

    #[test]
    fn a_peer_is_on_this_network_a_tailnet_or_the_internet() {
        let ip = |text: &str| Some(text.parse::<std::net::IpAddr>().unwrap());
        // A Mac on the phone's own wifi or ethernet.
        assert_eq!(peer_scope(ip("192.168.1.23")), "lan");
        assert_eq!(peer_scope(ip("10.0.0.5")), "lan");
        assert_eq!(peer_scope(ip("fe80::1")), "lan");
        assert_eq!(peer_scope(ip("::ffff:192.168.1.23")), "lan");
        // Tailscale (and a carrier's CGNAT), IPv4, IPv4-mapped and IPv6: never the LAN.
        assert_eq!(peer_scope(ip("100.101.102.103")), "tailnet");
        assert_eq!(peer_scope(ip("100.64.0.1")), "tailnet");
        assert_eq!(peer_scope(ip("::ffff:100.101.102.103")), "tailnet");
        assert_eq!(peer_scope(ip("fd7a:115c:a1e0::1")), "tailnet");
        // A hole-punched public address.
        assert_eq!(peer_scope(ip("203.0.113.9")), "wan");
        assert_eq!(peer_scope(ip("100.128.0.1")), "wan");
        assert_eq!(peer_scope(ip("2001:db8::1")), "wan");
        // A relayed path, or no route yet.
        assert_eq!(peer_scope(None), "");
    }

    /// A Mac on `signaling` that answers every session (`answer`), or
    /// takes them and never answers.
    async fn mac(signaling: &crate::testing::FakeSignaling, answer: bool) -> (String, SignalingClient) {
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &mac_id)
            .await
            .expect("Mac signaling");
        let serving = mac.clone();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Some(session) = serving.next_session().await {
                if !answer {
                    held.push(session);
                    continue;
                }
                let events = SessionEvents {
                    backend: serving.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options) =
                    (serving.clone(), DialOptions { include_loopback: true, ..DialOptions::default() });
                tokio::spawn(async move {
                    if let Ok(connected) = answer_on(&mac, session.first, events, &options).await {
                        // Held for the rest of the test.
                        std::mem::forget(connected);
                    }
                });
            }
        });
        (mac_id, mac)
    }

    async fn answer_on(
        mac: &SignalingClient,
        first: SignalEnvelope,
        events: SessionEvents,
        options: &DialOptions,
    ) -> Result<Connected, DialError> {
        super::answer(mac, first, events, options, LinkConfig::default()).await
    }

    fn relayed(turn: &crate::testing::TestTurn) -> DialOptions {
        DialOptions {
            include_loopback: true,
            relay_only: true,
            ice_servers: vec![turn.udp_only()],
            timeout: Duration::from_secs(10),
            ..DialOptions::default()
        }
    }

    /// Waits up to 5 s for the TURN server to hold `count` allocations.
    async fn held(turn: &crate::testing::TestTurn, count: usize) -> bool {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while turn.allocations() != count {
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        true
    }

    /// A redial's TURN allocation is made while signaling reconnects (the
    /// reconnect here finishes only once the server holds it), and the dial
    /// rides that allocation: no second one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_redial_allocates_turn_while_signaling_reconnects() {
        let signaling = crate::testing::FakeSignaling::start(crate::testing::FakeOptions::default()).await;
        let turn = crate::testing::TestTurn::start().await;
        let (mac_id, _mac) = mac(&signaling, true).await;
        let options = relayed(&turn);
        assert_eq!(turn.allocations(), 0, "nothing is held before the redial");
        let reconnect = async {
            if !held(&turn, 1).await {
                return Err("no TURN allocation while signaling reconnected");
            }
            SignalingClient::connect(&signaling.base_url, "user:alice", "team", "phone")
                .await
                .map_err(|_| "signaling")
        };
        let (_phone, connected) =
            connect_after(reconnect, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
                .await
                .expect("the redial connects");
        assert_eq!(*connected.path.borrow(), LinkPath::Turn);
        let at = |name: &str| options.timeline.get(name).unwrap_or_else(|| panic!("no {name} mark"));
        assert!(at("turn_early_allocated") <= at("signaling_connected"));
        assert!(at("signaling_connected") <= at("dial_start"));
        assert!(at("dial_start") <= at("turn_allocated"));
        assert_eq!(turn.allocations(), 1, "the dial took the early allocation");
    }

    /// An early allocation whose signaling reconnect fails is released.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_redial_whose_signaling_fails_releases_its_turn_allocation() {
        let turn = crate::testing::TestTurn::start().await;
        let options = relayed(&turn);
        let reconnect = async {
            let allocated = held(&turn, 1).await;
            Err::<SignalingClient, _>(if allocated { "signaling down" } else { "not allocated" })
        };
        let result =
            connect_after(reconnect, "mac", TransportKind::WireGuard, &options, LinkConfig::default()).await;
        assert!(
            matches!(&result, Err(DialError::Signaling(reason)) if reason == "signaling down"),
            "{:?}",
            result.err()
        );
        assert!(held(&turn, 0).await, "{} allocations still held", turn.allocations());
    }

    /// A redial dropped mid-dial (the Mac never answers), and one dropped
    /// while signaling still reconnects, hold no allocation afterwards.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_abandoned_redial_releases_its_turn_allocation() {
        let signaling = crate::testing::FakeSignaling::start(crate::testing::FakeOptions::default()).await;
        let turn = crate::testing::TestTurn::start().await;
        let (mac_id, _mac) = mac(&signaling, false).await;
        let options = relayed(&turn);
        let reconnect = SignalingClient::connect(&signaling.base_url, "user:alice", "team", "phone");
        let mut redial = Box::pin(connect_after(
            reconnect,
            &mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
        ));
        let waited = tokio::select! {
            result = &mut redial => panic!("an unanswered dial ended: {:?}", result.err()),
            waited = async {
                let allocated = held(&turn, 1).await;
                // The dial took it and waits for the Mac's answer.
                while options.timeline.get("wg_init_sent").is_none() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                allocated
            } => waited,
        };
        assert!(waited, "the redial allocated");
        drop(redial);
        assert!(held(&turn, 0).await, "{} allocations held after the abandoned dial", turn.allocations());

        let options = relayed(&turn);
        let reconnect = std::future::pending::<Result<SignalingClient, &str>>();
        let mut redial = Box::pin(connect_after(
            reconnect,
            &mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
        ));
        let allocated = tokio::select! {
            _ = &mut redial => unreachable!("the reconnect never ends"),
            allocated = held(&turn, 1) => allocated,
        };
        assert!(allocated, "the redial allocated while signaling reconnects");
        drop(redial);
        assert!(
            held(&turn, 0).await,
            "{} allocations held after the abandoned reconnect",
            turn.allocations()
        );
    }

    fn error(session_id: Option<&str>) -> SignalingEvent {
        SignalingEvent::Error {
            code: "offline".into(),
            message: "device is offline".into(),
            session_id: session_id.map(str::to_owned),
        }
    }

    /// An older peer's relay frame of an ended (or any) tunnel is answered
    /// `relay_retired` with that tunnel's session id; a new dial on the same
    /// socket must not fail on it.
    #[tokio::test]
    async fn another_sessions_error_does_not_fail_this_session() {
        let (session_tx, session) = mpsc::unbounded_channel();
        let (backend_tx, backend) = tokio::sync::broadcast::channel(8);
        let mut events = SessionEvents { session, backend, session_id: "new".into() };
        backend_tx.send(error(Some("old"))).unwrap();
        tokio::task::yield_now().await;
        let bye = SignalEnvelope {
            to: "mac".into(),
            from: "phone".into(),
            session_id: "new".into(),
            payload: SignalPayload::Bye { reason: "test".into() },
            from_user_id: None,
            relay_ticket: None,
        };
        session_tx.send(SessionEvent::Signal(bye)).unwrap();
        assert!(matches!(events.next().await, Ok(SessionEvent::Signal(_))));

        backend_tx.send(error(Some("new"))).unwrap();
        assert!(matches!(events.next().await, Err(DialError::Refused { .. })));
        backend_tx.send(error(None)).unwrap();
        assert!(matches!(events.next().await, Err(DialError::Refused { .. })));
    }
}
