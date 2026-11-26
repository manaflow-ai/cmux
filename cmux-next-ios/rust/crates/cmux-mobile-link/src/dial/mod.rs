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
pub(crate) mod dpi;
pub mod portmap;
pub mod relay;
pub(crate) mod turn;
#[doc(hidden)]
pub use dpi::dropped_wireguard_datagrams;
/// Measurement support (cmux-mobile-path-probe).
pub use turn::{TimedAllocation, TurnTransport, timed_allocation};
pub use wireguard::EarlyTurn;
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
            SignalPayload::WgInit { .. } | SignalPayload::WgResumed { .. } => Some(Self::WireGuard),
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
    /// Through the hop/1 UDP PoP relay, with per-leg repair.
    Hop,
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
    /// `hop`, `https-relay`, `none`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Turn => "turn",
            Self::TurnTls => "turn-tls",
            Self::Hop => "hop",
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
    /// WireGuard UDP dropped (the app's debug "Drop WireGuard" mode): this
    /// side acts as behind a firewall whose packet inspection blocks
    /// WireGuard (`dial/dpi.rs`). STUN and TURN's requests pass, every datagram
    /// carrying WireGuard (plain UDP, or TURN over UDP) is dropped both ways,
    /// so only TURN over TLS carries the tunnel.
    pub drop_wireguard_udp: bool,
    /// How TURN over TLS or TCP leaves this device: the system's proxy for
    /// the TURN server (PAC included), the OS trust store, and whether only a
    /// proxy may carry it (the debug "Proxy only" mode). [`crate::egress`].
    pub egress: crate::egress::Egress,
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
    /// Test support: trust these roots and nothing else for TURN over TLS (a
    /// test TURN server's self-signed certificate); wins over `egress.trust`.
    #[doc(hidden)]
    pub turn_tls_roots: Option<std::sync::Arc<rustls::RootCertStore>>,
    /// Where TURN and STUN names resolve: DNS raced against the literals they last resolved
    /// to ([`crate::route_literals`]), so a dial with DNS down still reaches them. The
    /// process's memory by default; a test's own (with its own resolver) otherwise.
    pub routes: std::sync::Arc<crate::route_literals::RouteLiterals>,
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
    /// Offer (phone) or accept (Mac) the reliable link
    /// ([`crate::RELIABLE_LANE`], PROTOCOL.md "Reliable link"): per-channel
    /// seq/ack/replay, so a dropped carrier resumes ([`resume`]) with no
    /// channel closed. Off by default; with either side off the link is
    /// exactly today's.
    pub reliable: bool,
    /// Mac side, with `reliable`: where this paired phone's links wait for
    /// its resume. Keep one per paired device. None: a resume is refused and
    /// the phone dials a new link.
    pub resume_registry: Option<std::sync::Arc<crate::ResumeRegistry>>,
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
    /// WireGuard: the idle air gap for the tunnel's routine path probes
    /// (`cmux_wg::WgNet::set_idle_air_gap`), [`IDLE_AIR_GAP`] by default;
    /// `None` probes on schedule.
    pub idle_air_gap: Option<Duration>,
    /// WireGuard, the dialing phone only: the longest its tunnel stays
    /// silent (`cmux_wg::WgNet::set_air_floor`), [`PHONE_AIR_FLOOR`] by
    /// default; `None` leaves only the persistent keepalive.
    pub air_floor: Option<Duration>,
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

/// The phone's air floor: LTE and NR carriers put an idle radio to sleep
/// after 5 to 12 s of nothing on the air (an LTE RRC inactivity timer; Huang
/// et al., MobiSys 2012, measured 11.6 s), and the next key then waits for
/// the radio's promotion (about 260 ms) and, for the echo, a paging slot (up
/// to 1.28 s). Something goes on the air at least this often, below the
/// shortest timer: at most 13 empty 32-byte keepalives a minute on an idle
/// link, about 25 KB an hour. `typing_echo --radio lte --radio-tail-ms 5000`:
/// 22 radio wakes in 5 min and a first-key p90 of 190 ms without it, 1 wake
/// and 74 ms with it.
pub const PHONE_AIR_FLOOR: Duration = Duration::from_millis(4500);

/// The idle air gap for routine path probes: with the air floor holding the
/// radio awake, a probe gap only saves bytes, and 20 s saved as much as 30 s
/// (a third of an idle link's datagrams in `typing_echo`).
pub const IDLE_AIR_GAP: Duration = Duration::from_secs(20);

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
            drop_wireguard_udp: false,
            egress: crate::egress::Egress::default(),
            turn_tls_roots: None,
            routes: crate::route_literals::RouteLiterals::shared(),
            drop_outbound_udp: false,
            refuse_udp_to: None,
            drop_udp_to: None,
            on_udp_sent: None,
            restrict_inbound_udp: false,
            impair_inbound: None,
            input_lane: true,
            video_lane: false,
            webrtc_media: false,
            reliable: false,
            resume_registry: None,
            video_drop_permille: 0,
            video_cap_bps: 0,
            video_blackout: None,
            stock_ice_waits: false,
            ultra: UltraSetting::Auto,
            aligned_keepalives: false,
            idle_air_gap: Some(IDLE_AIR_GAP),
            air_floor: Some(PHONE_AIR_FLOOR),
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
/// `relay` (a TURN or hop server, over UDP, TCP or TLS) or `none`.
pub fn route_name(path: LinkPath, peer: Option<std::net::IpAddr>) -> &'static str {
    match (path, peer) {
        (LinkPath::Direct, Some(ip)) if is_lan(ip) => "direct-lan",
        (LinkPath::Direct, Some(_)) => "direct-wan",
        (LinkPath::Direct, None) => "direct",
        (LinkPath::Turn | LinkPath::TurnTls | LinkPath::Hop | LinkPath::HttpsRelay, _) => "relay",
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

/// The two WireGuard static public keys a tunnel handshook with (base64, as
/// in `wg-init` and `wg-resp`): the dialer's (the phone's) and the
/// answerer's (the Mac's). `auth`'s identity proofs cover them (PROTOCOL.md
/// "Mac identity"), so the keys each side signs are the ones its own tunnel
/// authenticated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelKeys {
    pub dialer: String,
    pub answerer: String,
}

/// The WireGuard overlay a link rides, for its own datagram ports (viewport sync, 7424).
#[derive(Clone)]
pub struct Overlay {
    pub net: std::sync::Arc<cmux_wg::WgNet>,
    /// The other side's overlay address.
    pub peer_ip: std::net::IpAddr,
}

/// Runs once the link exists (see [`Dialed::on_link`]).
pub type OnLink = Box<dyn FnOnce(&Link) + Send>;

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
    /// Runs once the link exists (a WireGuard tunnel's lease learns how its
    /// link closes, [`wireguard::dormant`]).
    pub on_link: Option<OnLink>,
    /// Both sides listed [`crate::RELIABLE_LANE`].
    pub reliable: bool,
    /// The tunnel's static keys (WireGuard); `None` on WebRTC.
    pub tunnel_keys: Option<TunnelKeys>,
    /// The tunnel's overlay (WireGuard links only).
    pub overlay: Option<Overlay>,
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
    if options.reliable {
        lanes.push(crate::RELIABLE_LANE.to_owned());
    }
    lanes
}

/// Whether both sides speak the reliable link.
pub(crate) fn reliable_agreed(options: &DialOptions, peer_lanes: &[String]) -> bool {
    options.reliable && peer_lanes.iter().any(|lane| lane == crate::RELIABLE_LANE)
}

/// `config` with the reliable link on when both sides agreed on it (a
/// caller's own reliable settings win), and off otherwise: exactly today's.
fn reliable_config(
    mut config: LinkConfig,
    agreed: bool,
    registry: Option<&std::sync::Arc<crate::ResumeRegistry>>,
) -> LinkConfig {
    if !agreed {
        config.reliable = None;
    } else if config.reliable.is_none() {
        config.reliable =
            Some(crate::ReliableConfig { registry: registry.cloned(), ..crate::ReliableConfig::default() });
    }
    config
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
    /// Mac side: this carrier resumed a link already served (its channels
    /// and services run on), so the caller does not serve `link` again.
    /// Phone side: [`resume`] resumed `link`.
    pub resumed: bool,
    /// The tunnel's static keys (WireGuard); `None` on WebRTC.
    pub tunnel_keys: Option<TunnelKeys>,
    /// The WireGuard overlay this link rides (`None` on WebRTC).
    pub overlay: Option<Overlay>,
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

/// Phone side, [`connect`] taking `early`, the TURN allocation a cold dial
/// started as soon as `/v1/ice` answered, beside the signaling socket's open
/// ([`EarlyTurn::for_dial`] on these `options`): its round trips (behind a
/// proxy: a `CONNECT`, TLS through it, then the allocation) overlap the
/// socket's instead of following them. `None` is [`connect`]. An allocation
/// the dial never takes (it was refused, or this future was dropped) is
/// released at once.
pub async fn connect_with_early_turn(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link_config: LinkConfig,
    early: Option<EarlyTurn>,
) -> Result<Connected, DialError> {
    refuse_unreachable(kind, options)?;
    connect_on(signaling, mac, kind, options, link_config, early.filter(|_| kind == TransportKind::WireGuard))
        .await
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
    let early = EarlyTurn::for_dial(kind, options);
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
    let (dialed, session_id) = dial_transport(signaling, mac, kind, options, early).await?;
    let link_config = reliable_config(link_config, dialed.reliable, None);
    let link = Link::new(dialed.stream, Role::Phone, link_config, Some(dialed.guard));
    if let Some(on_link) = dialed.on_link {
        on_link(&link);
    }
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
        resumed: false,
        tunnel_keys: dialed.tunnel_keys,
        overlay: dialed.overlay,
    })
}

/// Phone side: a reliable `link` whose carrier dropped resumes over a new
/// transport to `mac` (dial it before dialing a new link): its channels see
/// no drop. An error (the Mac did not agree on the reliable link, or no
/// longer has this one) closes `link`; dial a new one with [`connect`].
pub async fn resume(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link: &Link,
) -> Result<Connected, DialError> {
    if link.reliable_stats().is_none() {
        return Err(DialError::Unexpected("the link is not a reliable link".into()));
    }
    refuse_unreachable(kind, options)?;
    let (dialed, session_id) = dial_transport(signaling, mac, kind, options, None).await?;
    if !dialed.reliable {
        let _ =
            signaling.send_signal(mac, &session_id, SignalPayload::Bye { reason: "no reliable link".into() });
        link.close("the Mac did not agree on the reliable link");
        return Err(DialError::Unexpected("the Mac did not agree on the reliable link".into()));
    }
    // The input and media lanes stay as they were: a reliable link carries
    // input on its main carrier. Its liveness datagrams ride the new tunnel.
    drop(dialed.lane);
    link.resume_carrier(dialed.stream, Some(dialed.guard))
        .await
        .map_err(|error| DialError::Transport(error.to_string()))?;
    // The new tunnel's lease learns how this link closes.
    if let Some(on_link) = dialed.on_link {
        on_link(link);
    }
    if let Some(hold) = dialed.hold {
        link.set_hold_hook(hold);
    }
    if let Some(liveness) = dialed.liveness {
        link.attach_liveness_datagrams(liveness);
    }
    options.timeline.mark("link_resumed");
    Ok(Connected {
        link: link.clone(),
        transport: kind,
        path: dialed.path,
        peer: dialed.peer,
        session_id,
        webrtc_media: dialed.webrtc_media,
        resumed: true,
        tunnel_keys: dialed.tunnel_keys,
        overlay: dialed.overlay,
    })
}

/// Phone side: dial `mac` over `kind` (a WireGuard dial taking the TURN
/// allocation `early` when a redial started one); the transport and its
/// session id.
async fn dial_transport(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    early: Option<wireguard::EarlyTurn>,
) -> Result<(Dialed, String), DialError> {
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
    Ok((dialed, session_id))
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
            let _ =
                signaling.send_signal(&peer, &session_id, SignalPayload::Bye { reason: error.to_string() });
            return Err(error);
        }
        Err(_) => {
            let _ =
                signaling.send_signal(&peer, &session_id, SignalPayload::Bye { reason: "timeout".into() });
            return Err(options.diagnosis.timed_out(kind));
        }
    };
    if dialed.reliable {
        // The phone's first frame says whether it opens a new link or
        // resumes one of this device's.
        let link_config = reliable_config(link_config, true, options.resume_registry.as_ref());
        drop(dialed.lane);
        let accepted = crate::Link::accept_reliable(dialed.stream, link_config, Some(dialed.guard))
            .await
            .map_err(|error| DialError::Transport(error.to_string()))?;
        let (link, resumed) = match accepted {
            crate::Accepted::New(link) => (link, false),
            crate::Accepted::Resumed(link) => (link, true),
        };
        if let Some(on_link) = dialed.on_link {
            on_link(&link);
        }
        // A resumed link's new carrier is a new transport: its hook replaces
        // the last carrier's.
        if let Some(hold) = dialed.hold {
            link.set_hold_hook(hold);
        }
        if let Some(liveness) = dialed.liveness {
            link.attach_liveness_datagrams(liveness);
        }
        if !resumed && let Some(media) = dialed.media {
            link.attach_media(media.start(&link));
        }
        options.timeline.mark(if resumed { "link_resumed" } else { "link_ready" });
        return Ok(Connected {
            link,
            transport: kind,
            path: dialed.path,
            peer: dialed.peer,
            session_id,
            webrtc_media: dialed.webrtc_media,
            resumed,
            tunnel_keys: dialed.tunnel_keys,
            overlay: dialed.overlay,
        });
    }
    let link =
        Link::new(dialed.stream, Role::Mac, reliable_config(link_config, false, None), Some(dialed.guard));
    if let Some(on_link) = dialed.on_link {
        on_link(&link);
    }
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
        resumed: false,
        tunnel_keys: dialed.tunnel_keys,
        overlay: dialed.overlay,
    })
}

/// Run a link on a stream dialed or accepted off signaling (the LAN path,
/// [`crate::lan`]): no session to unsubscribe and no media beside it.
pub(crate) fn run_dialed(
    dialed: Dialed,
    role: Role,
    link_config: LinkConfig,
    transport: TransportKind,
) -> Connected {
    let link = Link::new(dialed.stream, role, link_config, Some(dialed.guard));
    follow_lane(&link, dialed.lane);
    Connected {
        link,
        transport,
        path: dialed.path,
        peer: dialed.peer,
        session_id: uuid::Uuid::new_v4().to_string(),
        webrtc_media: false,
        resumed: false,
        tunnel_keys: dialed.tunnel_keys,
        overlay: dialed.overlay,
    }
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
        assert_eq!(route_name(LinkPath::Hop, None), "relay");
        assert_eq!(route_name(LinkPath::NoPath, None), "none");
    }

    #[test]
    fn the_reliable_link_is_off_unless_both_sides_offer_it() {
        let off = DialOptions::default();
        assert!(!off.reliable);
        assert!(!offered_lanes(&off, true, true).iter().any(|lane| lane == crate::RELIABLE_LANE));
        let on = DialOptions { reliable: true, ..DialOptions::default() };
        let offered = offered_lanes(&on, false, false);
        assert!(offered.iter().any(|lane| lane == crate::RELIABLE_LANE));
        assert!(reliable_agreed(&on, &offered));
        assert!(!reliable_agreed(&on, &offered_lanes(&off, true, true)), "the peer did not offer it");
        assert!(!reliable_agreed(&off, &offered), "this side did not offer it");

        let today = LinkConfig::default();
        assert!(reliable_config(today.clone(), false, None).reliable.is_none());
        let registry = std::sync::Arc::new(crate::ResumeRegistry::default());
        let agreed = reliable_config(today, true, Some(&registry)).reliable.expect("on when agreed");
        assert!(agreed.registry.is_some_and(|r| std::sync::Arc::ptr_eq(&r, &registry)));
    }

    /// Frames one way between a phone and a Mac, with each one's type
    /// noted: what the other end's reader would see.
    fn tap(
        from: tokio::io::DuplexStream,
        to: tokio::io::DuplexStream,
        seen: std::sync::Arc<std::sync::Mutex<Vec<crate::frame::FrameType>>>,
    ) -> (tokio::task::JoinHandle<()>, tokio::task::JoinHandle<()>) {
        use futures_util::{SinkExt, StreamExt};
        use tokio_util::codec::{FramedRead, FramedWrite};
        let one_way = |read, write, seen: std::sync::Arc<std::sync::Mutex<Vec<_>>>| {
            tokio::spawn(async move {
                let mut source = FramedRead::new(read, crate::frame::FrameCodec);
                let mut sink = FramedWrite::new(write, crate::frame::FrameCodec);
                while let Some(Ok(frame)) = source.next().await {
                    seen.lock().unwrap().push(frame.kind);
                    if sink.send(frame).await.is_err() {
                        return;
                    }
                }
                // The end closed its side: the other end reads that too.
                let _ = sink.close().await;
            })
        };
        let (from_read, from_write) = tokio::io::split(from);
        let (to_read, to_write) = tokio::io::split(to);
        (one_way(from_read, to_write, seen.clone()), one_way(to_read, from_write, seen))
    }

    /// A mixed pair, both ways round: an end that never offers `reliable`
    /// (and so knows no frame type above 5) links with one that does, by the
    /// dial's own negotiation, and the link runs without the sequenced mode:
    /// no seq, ack, hello or bye frame crosses the wire in either direction.
    #[tokio::test]
    async fn a_mixed_pair_links_without_the_reliable_frames_either_way() {
        use crate::frame::FrameType;
        use crate::link::ChannelEvent;
        use bytes::Bytes;
        for (phone_new, mac_new) in [(false, true), (true, false)] {
            let label = if phone_new { "new phone, old Mac" } else { "old phone, new Mac" };
            let phone_options = DialOptions { reliable: phone_new, ..DialOptions::default() };
            let mac_options = DialOptions { reliable: mac_new, ..DialOptions::default() };
            let phone_lanes = offered_lanes(&phone_options, false, false);
            let mac_lanes = offered_lanes(&mac_options, false, false);
            let phone_agreed = reliable_agreed(&phone_options, &mac_lanes);
            let mac_agreed = reliable_agreed(&mac_options, &phone_lanes);
            assert!(!phone_agreed && !mac_agreed, "{label}: only one side offered it");
            let quick =
                LinkConfig { keepalive: Some(std::time::Duration::from_millis(20)), ..LinkConfig::default() };
            let registry = std::sync::Arc::new(crate::ResumeRegistry::default());
            let phone_config = reliable_config(quick.clone(), phone_agreed, None);
            let mac_config = reliable_config(quick, mac_agreed, Some(&registry));

            let (phone_end, phone_tap) = tokio::io::duplex(64 * 1024);
            let (mac_tap, mac_end) = tokio::io::duplex(64 * 1024);
            let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
            let (up, down) = tap(phone_tap, mac_tap, seen.clone());
            let phone = Link::new(phone_end, Role::Phone, phone_config, None);
            // As `answer` builds it when the dial did not agree on it.
            let mac = Link::new(mac_end, Role::Mac, mac_config, None);
            assert!(phone.reliable_stats().is_none() && mac.reliable_stats().is_none(), "{label}");

            let server = mac.clone();
            let echo = tokio::spawn(async move {
                let mut incoming = server.accept().await.expect("incoming");
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    incoming.channel.send(bytes).await.unwrap();
                }
            });
            let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
            for round in 0..3u8 {
                channel.send(Bytes::from(vec![round; 1000])).await.unwrap();
                match tokio::time::timeout(std::time::Duration::from_secs(5), channel.recv()).await {
                    Ok(Some(ChannelEvent::Data(bytes))) => {
                        assert_eq!(&bytes[..], &[round; 1000][..], "{label}");
                    }
                    other => panic!("{label}: unexpected {other:?}"),
                }
            }
            phone.ping().await.expect("a round trip");
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            channel.close("done", "").await;
            phone.close("done");
            mac.closed().await;
            let _ = echo.await;
            up.abort();
            down.abort();
            let seen = seen.lock().unwrap().clone();
            assert!(seen.contains(&FrameType::Ping) && seen.contains(&FrameType::Data), "{label}: {seen:?}");
            let reliable_frames: Vec<_> = seen
                .iter()
                .filter(|kind| {
                    matches!(kind, FrameType::Seq | FrameType::Ack | FrameType::Hello | FrameType::Bye)
                })
                .collect();
            assert!(reliable_frames.is_empty(), "{label}: reliable frames on the wire {reliable_frames:?}");
            assert!(seen.iter().all(|kind| (*kind as u8) <= 5), "{label}: {seen:?}");
        }
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
            // The server counts the allocation before its answer reaches the
            // phone, which marks it then: wait for the phone's mark too.
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            while options.timeline.get("turn_early_allocated").is_none() {
                if tokio::time::Instant::now() >= deadline {
                    return Err("the phone never had its early allocation");
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
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
