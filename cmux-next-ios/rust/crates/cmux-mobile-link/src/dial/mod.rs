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

pub(crate) mod turn;
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
            SignalPayload::WgInit { .. } => Some(Self::WireGuard),
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
    /// No working route at the moment (WireGuard: nothing from the peer
    /// authenticated yet, or every route was refused). There is no backend
    /// relay to fall back to any more.
    NoPath,
}

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
    /// Test support: WireGuard drops plain UDP from any address it has not
    /// sent plain UDP to, as an address-restricted NAT in front of this
    /// side would. A peer that roams then reaches this side only after
    /// announcing its new endpoints.
    #[doc(hidden)]
    pub restrict_inbound_udp: bool,
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

impl Default for DialOptions {
    fn default() -> Self {
        Self {
            ice_servers: Vec::new(),
            include_loopback: false,
            exclude_cgnat: false,
            relay_only: false,
            block_udp: false,
            turn_tls_roots: None,
            drop_outbound_udp: false,
            refuse_udp_to: None,
            drop_udp_to: None,
            restrict_inbound_udp: false,
            input_lane: true,
            video_lane: false,
            webrtc_media: false,
            video_drop_permille: 0,
            video_cap_bps: 0,
            video_blackout: None,
            stock_ice_waits: false,
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

/// A byte stream a link can run on.
pub trait LinkStream: AsyncRead + AsyncWrite + Send + Unpin + 'static {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin + 'static> LinkStream for T {}

/// A dialed or answered transport.
pub struct Dialed {
    pub stream: Box<dyn LinkStream>,
    pub path: watch::Receiver<LinkPath>,
    /// Holds the peer connection or tunnel open.
    pub guard: Box<dyn Any + Send>,
    /// The input lane's stream, when both sides negotiated one. It may open
    /// after the main stream; a dropped sender means it failed.
    pub lane: Option<oneshot::Receiver<Box<dyn LinkStream>>>,
    /// The media lane's carrier, when both sides negotiated one.
    pub media: Option<PendingMedia>,
    /// Both sides listed [`WEBRTC_MEDIA_LANE`] (WireGuard).
    pub webrtc_media: bool,
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
    if options.relay_only && kind == TransportKind::WebRtc && turn_url_count(&options.ice_servers) == 0 {
        return Err(DialError::Transport(
            "relay only needs a TURN server, and the service offered none".into(),
        ));
    }
    if kind == TransportKind::WireGuard
        && let Some(reason) = wireguard::missing_turn(options)
    {
        return Err(DialError::Transport(reason.into()));
    }
    let session_id = uuid::Uuid::new_v4().to_string();
    let events = SessionEvents::subscribe(signaling, &session_id);
    let dialer = kind.dialer();
    options.timeline.mark("dial_start");
    let result =
        tokio::time::timeout(options.timeout, dialer.dial(signaling, mac, &session_id, events, options))
            .await;
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
            return Err(DialError::Timeout);
        }
    };
    let link = Link::new(dialed.stream, Role::Phone, link_config, Some(dialed.guard));
    follow_lane(&link, dialed.lane);
    if let Some(media) = dialed.media {
        link.attach_media(media.start(&link));
    }
    options.timeline.mark("link_ready");
    Ok(Connected { link, transport: kind, path: dialed.path, session_id, webrtc_media: dialed.webrtc_media })
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
            return Err(DialError::Timeout);
        }
    };
    let link = Link::new(dialed.stream, Role::Mac, link_config, Some(dialed.guard));
    follow_lane(&link, dialed.lane);
    if let Some(media) = dialed.media {
        link.attach_media(media.start(&link));
    }
    options.timeline.mark("link_ready");
    Ok(Connected { link, transport: kind, path: dialed.path, session_id, webrtc_media: dialed.webrtc_media })
}

#[cfg(test)]
mod tests {
    use super::*;

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
        };
        session_tx.send(SessionEvent::Signal(bye)).unwrap();
        assert!(matches!(events.next().await, Ok(SessionEvent::Signal(_))));

        backend_tx.send(error(Some("new"))).unwrap();
        assert!(matches!(events.next().await, Err(DialError::Refused { .. })));
        backend_tx.send(error(None)).unwrap();
        assert!(matches!(events.next().await, Err(DialError::Refused { .. })));
    }
}
