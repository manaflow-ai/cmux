//! WireGuard transport: a per-session userspace tunnel (cmux-wg: boringtun
//! plus smoltcp). Keys, endpoints and overlay addresses travel in
//! `wg-init` / `wg-resp`. Endpoints are the host address and the
//! STUN-discovered reflexive address of the tunnel's UDP socket; the dialer
//! adds the relayed address of a TURN allocation when `/v1/ice` offers a
//! TURN server (`turn.rs`: UDP first, TLS on 443 when UDP gets none), and
//! so does a Mac whose network answers no STUN. Until the peer confirms a
//! route, every datagram is sent on every route that might work: the route
//! the peer's datagrams arrive on, the TURN allocation, and the peer's
//! endpoints (the hole punch). There is no backend relay (PROTOCOL.md: the
//! relay frames are retired). The link is one TCP stream to
//! `overlayIP:7420`.
//!
//! Roaming (`roam.rs`): after a network change a side moves the session onto
//! a fresh UDP socket and TURN allocation, re-learns its reflexive address,
//! and tells the peer its new endpoints inside the tunnel. The session, its
//! keys and its TCP streams stay.

use std::collections::HashSet;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use base64::Engine;
use bytes::Bytes;
use cmux_transport::PathId;
use cmux_wg::{InterfaceAddress, IpNetwork, Origin, Received, Underlay, WgConfig, WgNet};
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::turn::{TurnCarrier, TurnTransport};
use super::{DialError, DialFuture, DialOptions, Dialed, Dialer, LinkPath, SessionEvents, TransportKind};
use crate::api::stun_servers;
use crate::class_queue::{SendClass, send_class};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient, WG_VERSION};
use crate::timing::Timeline;

pub use super::turn::missing_turn;

#[path = "wireguard_roam.rs"]
mod roam;
use roam::{Control, Session};
pub use roam::{network_changed, rehome, roam_timeline};
#[doc(hidden)]
pub use roam::{roam_session, session_endpoints, simulate_network_loss, simulate_turn_loss};

/// The link's TCP port inside the tunnel (PROTOCOL.md).
pub const LINK_PORT: u16 = 7420;
/// How long the input lane's second connection may take before input stays
/// on the main stream.
const LANE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// Overlay addresses: each tunnel is its own userspace network, so fixed
/// addresses never collide across sessions.
const DIALER_OVERLAY: Ipv4Addr = Ipv4Addr::new(10, 77, 0, 2);
const ANSWER_OVERLAY: Ipv4Addr = Ipv4Addr::new(10, 77, 0, 1);
/// Room for TURN's ChannelData header and the paths' own headers.
const MTU: u16 = 1280;
const KEEPALIVE_SECONDS: u16 = 10;
/// A confirmed route silent this long is no longer trusted: every datagram
/// goes on every route again until the peer confirms one. Longer than the
/// WireGuard keepalive (10 s), shorter than the link keepalive timeout
/// (20 s), so a route that dies in both directions recovers on TURN before
/// the link gives up.
const DIRECT_STALE: Duration = Duration::from_secs(14);
const STUN_WAIT: Duration = Duration::from_millis(1500);
/// Once one STUN server answered, how much longer the others get. Cloudflare
/// lists STUN on 3478 and on 53, and cellular networks often take port 53 for
/// their own DNS or drop it: waiting out [`STUN_WAIT`] for that one held
/// every dial and roam on such a network 1.5 s (link-reliability-20261023.md).
/// A second answer only adds a reflexive address the first usually shares.
const STUN_GRACE: Duration = Duration::from_millis(150);

pub struct WireGuardDialer;

fn transport_error(error: impl std::fmt::Display) -> DialError {
    DialError::Transport(error.to_string())
}

fn keypair() -> (Zeroizing<[u8; 32]>, [u8; 32]) {
    let mut private = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut private[..]).expect("operating system randomness");
    let secret = x25519_dalek::StaticSecret::from(*private);
    let public = x25519_dalek::PublicKey::from(&secret);
    (Zeroizing::new(secret.to_bytes()), public.to_bytes())
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn parse_key(text: &str) -> Result<[u8; 32], DialError> {
    base64::engine::general_purpose::STANDARD
        .decode(text)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| DialError::Unexpected("bad WireGuard public key".into()))
}

/// Receive and send buffer of a tunnel's UDP socket. A roam resends up to
/// [`REPLAY_BYTES`] at once, several times (one per event of the roam), as
/// does the peer, on top of a stream at full rate: the OS default (about
/// 200 KB on Linux) drops part of such bursts, and TCP inside the tunnel then waits out its 1 s
/// retransmission timeout. The OS caps it (Linux `net.core.rmem_max`).
const UDP_BUFFER: usize = 2 * 1024 * 1024;

/// A UDP socket for the tunnel, on any port, with [`UDP_BUFFER`] buffers.
pub(super) fn bind_udp() -> io::Result<UdpSocket> {
    let socket =
        socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    let _ = socket.set_recv_buffer_size(UDP_BUFFER);
    let _ = socket.set_send_buffer_size(UDP_BUFFER);
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)).into())?;
    UdpSocket::from_std(socket.into())
}

/// The machine's primary local address (no packet is sent).
pub fn primary_local_ip() -> Option<IpAddr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect("192.0.2.1:9").ok()?;
    probe.local_addr().ok().map(|addr| addr.ip()).filter(|ip| !ip.is_unspecified())
}

/// Whether this side uses no plain UDP at all (relay only, or UDP blocked).
fn no_plain_udp(options: &DialOptions) -> bool {
    options.relay_only || options.block_udp
}

/// Asked for a TURN allocation (`wanted`) and got none in time, though a TURN
/// server is configured: the session takes it once the server answers.
fn missed_turn(wanted: bool, turn: Option<&TurnCarrier>, options: &DialOptions) -> bool {
    wanted && turn.is_none() && super::turn::turn_servers(&options.ice_servers) != (None, None)
}

/// At most this many host addresses are offered (an announcement carries
/// at most 16 endpoints, with the reflexive and relayed ones).
const MAX_HOST_IPS: usize = 8;

/// The IPv4 addresses of this machine's interfaces (the tunnel's socket is
/// IPv4), as WebRTC gathers its host candidates.
fn interface_ips() -> Vec<IpAddr> {
    webrtc::util::ifaces::ifaces()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|interface| interface.addr.map(|addr| addr.ip()))
        .collect()
}

/// The host addresses offered as endpoints: the primary one (the default
/// route's) first, then every other usable IPv4 interface address. A Mac on
/// Ethernet and Wi-Fi is reachable from a phone on the Wi-Fi only at its
/// Wi-Fi address, and a peer on Tailscale only at its Tailscale one; WebRTC
/// offers them all as host candidates, and so does this. Loopback (added on
/// its own in tests), link-local and IPv6 addresses are left out, and CGNAT
/// (Tailscale) ones when the options exclude them.
fn host_ips(primary: Option<IpAddr>, interfaces: &[IpAddr], options: &DialOptions) -> Vec<IpAddr> {
    let usable = |ip: &IpAddr| match ip {
        IpAddr::V4(v4) => {
            !(v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_broadcast()
                || (options.exclude_cgnat && super::is_cgnat(*ip)))
        }
        IpAddr::V6(_) => false,
    };
    let mut ips: Vec<IpAddr> = Vec::new();
    for ip in primary.into_iter().chain(interfaces.iter().copied()) {
        if usable(&ip) && !ips.contains(&ip) && ips.len() < MAX_HOST_IPS {
            ips.push(ip);
        }
    }
    ips
}

/// Host endpoints of a socket on `port` (no STUN).
fn host_endpoints(port: u16, options: &DialOptions) -> Vec<SocketAddr> {
    if no_plain_udp(options) {
        return Vec::new();
    }
    let mut endpoints = Vec::new();
    if options.include_loopback {
        endpoints.push(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port));
    }
    for ip in host_ips(primary_local_ip(), &interface_ips(), options) {
        endpoints.push(SocketAddr::new(ip, port));
    }
    endpoints
}

/// The IPv4 addresses of the STUN servers in `options`.
async fn resolve_stun(options: &DialOptions) -> Vec<SocketAddr> {
    let mut addresses = Vec::new();
    for server in stun_servers(&options.ice_servers) {
        let Ok(mut found) = tokio::net::lookup_host(server.as_str()).await else { continue };
        if let Some(address) = found.find(SocketAddr::is_ipv4) {
            addresses.push(address);
        }
    }
    addresses
}

/// The endpoints offered to the peer: `endpoints` as text, without CGNAT
/// addresses when the options exclude them.
fn offered(endpoints: impl IntoIterator<Item = SocketAddr>, options: &DialOptions) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for endpoint in endpoints {
        if options.exclude_cgnat && super::is_cgnat(endpoint.ip()) {
            continue;
        }
        let text = endpoint.to_string();
        if !out.contains(&text) {
            out.push(text);
        }
    }
    out
}

/// What [`gather_endpoints`] found.
#[derive(Debug)]
struct Gathered {
    /// Host and server-reflexive endpoints, as offered to the peer.
    endpoints: Vec<String>,
    /// The STUN servers asked (kept for roaming).
    stun: Vec<SocketAddr>,
    /// How many STUN servers answered.
    answered: usize,
}

impl Gathered {
    /// STUN servers were asked and none answered: this network most likely
    /// drops UDP, so this side needs its own TURN allocation.
    fn udp_looks_blocked(&self) -> bool {
        !self.stun.is_empty() && self.answered == 0
    }
}

/// Host and server-reflexive endpoints of `socket`, and the STUN servers
/// used.
async fn gather_endpoints(socket: &UdpSocket, options: &DialOptions) -> Gathered {
    let none = Gathered { endpoints: Vec::new(), stun: Vec::new(), answered: 0 };
    if no_plain_udp(options) {
        return none;
    }
    let port = match socket.local_addr() {
        Ok(addr) => addr.port(),
        Err(_) => return none,
    };
    let mut endpoints = host_endpoints(port, options);
    let servers = resolve_stun(options).await;
    let mut transactions = Vec::new();
    for address in &servers {
        let mut transaction = [0u8; 12];
        getrandom::fill(&mut transaction).expect("operating system randomness");
        if socket.send_to(&cmux_transport::stun::binding_request(transaction), address).await.is_ok() {
            transactions.push(transaction);
        }
    }
    let mut deadline = Instant::now() + STUN_WAIT;
    let mut buffer = [0u8; 1500];
    let mut answered = 0;
    while !transactions.is_empty() {
        let Ok(Ok((len, _))) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await else {
            break;
        };
        let found = transactions.iter().position(|transaction| {
            cmux_transport::stun::parse_binding_success(&buffer[..len], transaction).is_ok_and(|reflexive| {
                if !endpoints.contains(&reflexive) {
                    endpoints.push(reflexive);
                }
                true
            })
        });
        if let Some(index) = found {
            transactions.swap_remove(index);
            answered += 1;
            deadline = deadline.min(Instant::now() + STUN_GRACE);
        }
    }
    Gathered { endpoints: offered(endpoints, options), stun: servers, answered }
}

/// This side's TURN relayed addresses as offered to the peer: all of them,
/// and those whose allocation rides TCP or TLS.
fn relayed_of(turn: Option<&TurnCarrier>) -> (Vec<String>, Vec<String>) {
    let all: Vec<String> = turn.iter().map(|turn| turn.relayed.to_string()).collect();
    let stream =
        turn.iter().filter(|turn| turn.transport.is_stream()).map(|turn| turn.relayed.to_string()).collect();
    (all, stream)
}

/// Whether a TURN server may relay to `addr`: public unicast only (TURN
/// servers refuse private and loopback peers), except loopback in tests.
fn turn_reachable(addr: &SocketAddr, options: &DialOptions) -> bool {
    match addr.ip() {
        IpAddr::V4(ip) => {
            (options.include_loopback && ip.is_loopback())
                || !(ip.is_private()
                    || ip.is_loopback()
                    || ip.is_link_local()
                    || ip.is_unspecified()
                    || super::is_cgnat(IpAddr::V4(ip)))
        }
        IpAddr::V6(ip) => {
            (options.include_loopback && ip.is_loopback())
                || !(ip.is_loopback() || ip.is_unspecified() || (ip.segments()[0] & 0xfe00) == 0xfc00)
        }
    }
}

/// The peer endpoints this side sends to through its TURN allocation. Relay
/// only keeps these: like WebRTC's `relay` policy, only this side's
/// candidates are restricted to relayed ones.
fn turn_targets(endpoints: &[String], options: &DialOptions) -> Vec<SocketAddr> {
    endpoints
        .iter()
        .filter_map(|text| text.parse::<SocketAddr>().ok())
        .filter(|addr| !(options.exclude_cgnat && super::is_cgnat(addr.ip())))
        .filter(|addr| turn_reachable(addr, options))
        .collect()
}

/// The class of a datagram the tunnel's pacer sent in `priority`.
/// Handshake messages, keepalives and anything not WireGuard data keep the
/// class their shape gives (control).
fn send_class_of(datagram: &[u8], priority: cmux_wg::Priority) -> SendClass {
    match send_class(datagram) {
        SendClass::Control => SendClass::Control,
        _ => match priority {
            cmux_wg::Priority::Interactive => SendClass::Input,
            cmux_wg::Priority::Bulk => SendClass::Bulk,
            cmux_wg::Priority::Media => SendClass::Media,
        },
    }
}

/// The peer's endpoints this side may use for plain UDP.
fn usable_endpoints(endpoints: &[String], options: &DialOptions) -> Vec<String> {
    if no_plain_udp(options) {
        return Vec::new();
    }
    endpoints
        .iter()
        .filter(|text| {
            text.parse::<SocketAddr>()
                .is_ok_and(|addr| !(options.exclude_cgnat && super::is_cgnat(addr.ip())))
        })
        .cloned()
        .collect()
}

/// Time between "your datagrams reach me" messages while they keep arriving.
const MARKER_INTERVAL: Duration = Duration::from_secs(3);
/// After a route change the `reach` message is repeated this much later
/// (each wait after the previous one) while the peer's datagrams keep
/// arriving: it is one UDP datagram in the tunnel, and the peer sends on
/// every route until one arrives.
const REACH_REPEATS: [Duration; 3] =
    [Duration::from_millis(100), Duration::from_millis(300), Duration::from_millis(1000)];
/// A route the peer's `reach` chose over the one its datagrams arrive on
/// (reachability is one-way) is kept this long past each such `reach`.
/// An idle link sends only WireGuard keepalives (every 10 s), each answered
/// by one `reach`, so this outlives two of them.
const REACH_PIN: Duration = Duration::from_secs(25);
/// A confirmed route that no `reach` confirmed for this long (2.5 keepalive
/// intervals, so an idle link keeps it) is no longer trusted: our sending
/// on it may have broken while the peer's datagrams still arrive.
const REACH_STALE: Duration = Duration::from_secs(25);
/// A `reach` naming another route than the current one moves the route
/// there only if no `reach` confirmed the current route for this long (one
/// arrives at least every [`MARKER_INTERVAL`] while it works), or if it
/// names a direct route and the current one is relayed (an upgrade).
const REACH_SWITCH_AFTER: Duration = Duration::from_secs(4);
/// How recent an arrival counts as "still arriving" for the route rules.
const RELAYED_RECENT: Duration = Duration::from_secs(1);

/// How a route reaches the peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Carrier {
    /// Plain UDP from the tunnel's socket.
    Udp,
    /// Through this side's TURN allocation.
    Turn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Route {
    carrier: Carrier,
    addr: SocketAddr,
}

/// What a path label needs to know besides the route.
#[derive(Debug, Default)]
struct Labels {
    /// The peer's TURN relayed addresses: plain UDP to one rides the peer's
    /// TURN server.
    peer_relayed: HashSet<SocketAddr>,
    /// Those of them whose allocation rides TCP or TLS.
    peer_relayed_tls: HashSet<SocketAddr>,
}

/// The path label of a route. Plain UDP to one of the peer's TURN relayed
/// addresses rides the peer's TURN server: the answering Mac reaches a
/// relay-only phone that way, so it is [`LinkPath::Turn`] (or
/// [`LinkPath::TurnTls`]) even though this side sends plain UDP.
fn path_of(route: Option<Route>, labels: &Labels, own: Option<TurnTransport>) -> LinkPath {
    match route {
        Some(Route { carrier: Carrier::Udp, addr }) if labels.peer_relayed_tls.contains(&addr) => {
            LinkPath::TurnTls
        }
        Some(Route { carrier: Carrier::Udp, addr }) if labels.peer_relayed.contains(&addr) => LinkPath::Turn,
        Some(Route { carrier: Carrier::Udp, .. }) => LinkPath::Direct,
        Some(Route { carrier: Carrier::Turn, .. }) if own.is_some_and(TurnTransport::is_stream) => {
            LinkPath::TurnTls
        }
        Some(Route { carrier: Carrier::Turn, .. }) => LinkPath::Turn,
        None => LinkPath::NoPath,
    }
}

/// How long after a roam (this side's or the peer's) every datagram also
/// goes to the peer's plain UDP candidates, so a new NAT mapping opens on
/// both sides while the route settles.
const ROAM_SPRAY: Duration = Duration::from_secs(3);
/// Spacing of those extra datagrams inside the window.
const ROAM_SPRAY_GAP: Duration = Duration::from_millis(100);
/// Data messages sent in this long before a roam, a route change or a new
/// TURN allocation are sent again on the new route (the newest that fit
/// [`REPLAY_BYTES`]): those that went into
/// the dead route would otherwise cost TCP inside the tunnel its 1 s
/// minimum retransmission timeout, or after a long outage (airplane mode)
/// its backed-off one. WireGuard's replay window drops the copies that did
/// arrive. As long as the link's own keepalive timeout.
const REPLAY_AGE: Duration = Duration::from_secs(20);
/// At most this many datagrams are kept for that (about 100 ms of a
/// 15 Mbit/s stream; a whole outage of retransmissions and keepalives).
const REPLAY_MAX: usize = 128;
/// A replay sends only the newest of those that fit this many bytes: a
/// burst past what a buffer on the path holds drops part of it (a TURN
/// server's relay socket, which this side does not size, drops what
/// arrives last; the TURN carrier's input class holds as much). About
/// 50 full-size datagrams, half a second of a busy terminal.
const REPLAY_BYTES: usize = 64 * 1024;
const _: () = assert!(REPLAY_BYTES <= crate::class_queue::INPUT_BYTES);
/// A route that flips between two addresses of the same peer (a LAN and a
/// hairpinned public address while candidates are sprayed) replays at most
/// this often; a roam of this side always replays.
const REPLAY_GAP: Duration = Duration::from_secs(1);
/// While the confirmed route is TURN, plain UDP candidates are tried this
/// often, so the session goes back to a direct path once one works again.
const UPGRADE_SPRAY_GAP: Duration = Duration::from_secs(5);
/// A handshake initiation of ours that nothing from the peer has answered
/// yet is sent again after each of these waits (3.75 s in all), on the TURN
/// routes only (through our allocation, and to the peer's relayed
/// addresses): those are what the race below loses, and a copy on every
/// route would count against the peer's handshake rate limit (10 a second
/// per peer, cookie replies past it). The first one can be lost on a route that
/// starts working a moment later: the answering Mac's first initiation
/// reaches the phone's TURN server before the phone has a permission for
/// the Mac, and behind a NAT whose mapping depends on the destination the
/// phone's own initiation (sent to the Mac's announced reflexive address,
/// mapped toward the STUN server) never arrives either. boringtun itself
/// retries only after its REKEY_TIMEOUT (5 s). A duplicate the peer already
/// answered is dropped there (its timestamp is not newer).
const HANDSHAKE_REPEATS: [Duration; 4] = [
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_millis(1000),
    Duration::from_millis(2000),
];

/// Our latest handshake initiation, until the peer answers ([`HANDSHAKE_REPEATS`]).
struct HandshakeRepeat {
    datagram: Bytes,
    class: SendClass,
    /// Repeats already sent.
    sent: usize,
    timer: std::pin::Pin<Box<tokio::time::Sleep>>,
}

/// The carriers: one UDP socket for direct paths and an optional TURN
/// allocation (over UDP, or over TLS where UDP is blocked).
///
/// Reachability can be one-way (one side's OS or firewall drops its
/// outbound UDP), so receiving the peer's datagrams proves only the
/// peer→us direction. Until the peer confirms it receives what we send,
/// every datagram goes on the route its datagrams arrive on and through
/// TURN as well. The confirmation is an in-tunnel `reach` message
/// (PROTOCOL.md), sent by a side whenever an authenticated UDP or TURN
/// datagram from its peer arrives (at most every 3 s, and at once when the
/// route changed). An older peer (protocol version 0) never sends it: its
/// datagrams count as the confirmation, as before the marker existed.
///
/// An address the OS refuses to send to (macOS Local Network privacy
/// returns `EHOSTUNREACH` for LAN peers) is never chosen as the route again,
/// so a peer reachable on the LAN one way and through TURN the other way
/// settles on TURN instead of flapping. A roam forgets those refusals: the
/// new network may route them.
///
/// The roaming side of the tunnel (`roam.rs`) changes the carriers through
/// [`Control`] messages, which the underlay applies before its next send or
/// receive.
struct HybridUnderlay {
    socket: UdpSocket,
    options: DialOptions,
    /// The peer's endpoints as it last announced them.
    peer_endpoints: Vec<String>,
    /// Peer endpoints for plain UDP.
    candidates: Vec<SocketAddr>,
    turn: Option<TurnCarrier>,
    /// Peer endpoints this side reaches through its TURN allocation.
    turn_targets: Vec<SocketAddr>,
    labels: Labels,
    /// The peer speaks protocol version 2: it sends `reach` messages.
    peer_reaches: bool,
    /// The route of the latest authenticated peer datagram (peer→us works).
    direct: Option<Route>,
    last_direct: Option<Instant>,
    /// When plain UDP from the peer last authenticated.
    last_udp: Option<Instant>,
    /// Addresses the OS refused plain UDP to.
    refused: HashSet<SocketAddr>,
    /// The peer said it receives what we send (us→peer works).
    confirmed: bool,
    last_marker: Option<Instant>,
    /// Repeats of `reach` still due after a route change ([`REACH_REPEATS`]).
    reach_repeats: usize,
    /// Asks the session's control task to send the peer a `reach` message
    /// naming the address and carrier its datagram came in on.
    reach_out: mpsc::UnboundedSender<(SocketAddr, Carrier)>,
    /// Where plain UDP from the peer last came from (not its relayed address).
    last_udp_from: Option<SocketAddr>,
    /// The route was chosen by the peer's `reach`, not by where its datagrams
    /// arrive, until then ([`REACH_PIN`]).
    pinned_until: Option<Instant>,
    /// This side's earlier TURN relayed addresses: a `reach` naming one is
    /// stale (it was in flight across a new allocation).
    retired_relayed: Vec<SocketAddr>,
    /// When a `reach` last confirmed the current route.
    last_fit: Option<Instant>,
    /// When a `reach` last told the peer its direct UDP arrives while most
    /// of its datagrams come relayed.
    last_upgrade_reach: Option<Instant>,
    /// When the route last changed.
    route_since: Instant,
    /// When a datagram last arrived on the route.
    last_on_route: Option<Instant>,
    /// When a datagram last arrived relayed (through a TURN server).
    last_relayed_arrival: Option<Instant>,
    path: watch::Sender<LinkPath>,
    control: mpsc::UnboundedReceiver<Control>,
    /// STUN transactions of the current socket still unanswered, and where
    /// the reflexive addresses go.
    stun: Vec<([u8; 12], SocketAddr)>,
    reflexive: Option<mpsc::UnboundedSender<SocketAddr>>,
    /// Until when candidates are sprayed after a roam, and when next.
    spray_until: Option<Instant>,
    next_spray: Option<Instant>,
    /// The current roam's marks, until the new route is confirmed.
    roam: Option<Timeline>,
    /// The socket's network is gone (debug and tests): nothing it sends
    /// leaves and nothing arrives.
    blackhole: bool,
    /// Test support: addresses plain UDP was sent to; with
    /// `DialOptions::restrict_inbound_udp`, UDP from anywhere else is dropped.
    sent_to: HashSet<SocketAddr>,
    /// What was sent lately, for the replay after a route change.
    recent: std::collections::VecDeque<(Instant, Bytes, SendClass)>,
    /// When a route change last replayed.
    last_replay: Option<Instant>,
    /// A replay is due as soon as a route is known: there was none to send
    /// it on (right after a roam). Sending it to every candidate instead
    /// overflowed the peer's socket buffer and lost the very datagrams the
    /// replay is for.
    replay_pending: bool,
    /// The tunnel's receive task, woken when a control message applied on
    /// the send side brings a new socket or TURN allocation: nothing would
    /// otherwise poll it until a timer fires (the old socket's readiness is
    /// what the task waits on).
    recv_waker: Option<std::task::Waker>,
    /// Our handshake initiation still waiting for an answer.
    handshake_repeat: Option<HandshakeRepeat>,
}

const UDP_PATH: PathId = PathId(0);
const TURN_PATH: PathId = PathId(2);

/// What a side's underlay starts with.
struct UnderlaySpec<'a> {
    socket: UdpSocket,
    peer_endpoints: &'a [String],
    peer_relayed: &'a [String],
    peer_relayed_tls: &'a [String],
    peer_version: u32,
    turn: Option<TurnCarrier>,
    reach_out: mpsc::UnboundedSender<(SocketAddr, Carrier)>,
    path: watch::Sender<LinkPath>,
    control: mpsc::UnboundedReceiver<Control>,
}

fn addresses(texts: &[String]) -> HashSet<SocketAddr> {
    texts.iter().filter_map(|text| text.parse().ok()).collect()
}

impl HybridUnderlay {
    fn new(spec: UnderlaySpec<'_>, options: &DialOptions) -> Self {
        let mut underlay = Self {
            socket: spec.socket,
            options: options.clone(),
            peer_endpoints: Vec::new(),
            candidates: Vec::new(),
            turn: spec.turn,
            turn_targets: Vec::new(),
            labels: Labels {
                peer_relayed: addresses(spec.peer_relayed),
                peer_relayed_tls: addresses(spec.peer_relayed_tls),
            },
            peer_reaches: spec.peer_version >= WG_VERSION,
            direct: None,
            last_direct: None,
            last_udp: None,
            refused: HashSet::new(),
            confirmed: false,
            last_marker: None,
            reach_repeats: 0,
            reach_out: spec.reach_out,
            last_udp_from: None,
            pinned_until: None,
            retired_relayed: Vec::new(),
            last_fit: None,
            last_upgrade_reach: None,
            route_since: Instant::now(),
            last_on_route: None,
            last_relayed_arrival: None,
            path: spec.path,
            control: spec.control,
            stun: Vec::new(),
            reflexive: None,
            spray_until: None,
            next_spray: None,
            roam: None,
            blackhole: false,
            sent_to: HashSet::new(),
            recent: std::collections::VecDeque::new(),
            last_replay: None,
            replay_pending: false,
            recv_waker: None,
            handshake_repeat: None,
        };
        underlay.set_peer_endpoints(spec.peer_endpoints.to_vec());
        underlay
    }

    fn set_peer_endpoints(&mut self, endpoints: Vec<String>) {
        self.candidates =
            usable_endpoints(&endpoints, &self.options).iter().filter_map(|text| text.parse().ok()).collect();
        self.peer_endpoints = endpoints;
        self.retarget_turn();
    }

    fn retarget_turn(&mut self) {
        self.turn_targets =
            if self.turn.is_some() { turn_targets(&self.peer_endpoints, &self.options) } else { Vec::new() };
    }

    /// Apply the roaming side's changes.
    fn apply(&mut self, control: Control) {
        let now = Instant::now();
        match control {
            Control::Rebind { socket, stun, reflexive, timeline } => {
                tracing::debug!(local = ?socket.local_addr().ok(), "WireGuard roams onto a new socket");
                // The old route's address stays a candidate (a peer-reflexive
                // one may be in no announcement).
                if let Some(route) = self.direct.take()
                    && route.carrier == Carrier::Udp
                    && !no_plain_udp(&self.options)
                    && !self.candidates.contains(&route.addr)
                {
                    self.candidates.push(route.addr);
                }
                self.socket = socket;
                self.blackhole = false;
                // The old allocation belongs to the old network's 5-tuple; a
                // `reach` still in flight that names it is stale.
                self.retire_turn();
                self.turn_targets.clear();
                self.route_since = now;
                self.last_direct = None;
                self.last_udp = None;
                // A `reach` still in flight names the old network's addresses.
                self.last_udp_from = None;
                self.pinned_until = None;
                self.last_fit = None;
                self.refused.clear();
                self.sent_to.clear();
                self.confirmed = false;
                self.last_marker = None;
                self.spray_until = Some(now + ROAM_SPRAY);
                self.next_spray = None;
                self.stun.clear();
                for server in stun {
                    let mut transaction = [0u8; 12];
                    getrandom::fill(&mut transaction).expect("operating system randomness");
                    let request = cmux_transport::stun::binding_request(transaction);
                    if self.socket.try_send_to(&request, server).is_ok() {
                        self.stun.push((transaction, server));
                    }
                }
                self.reflexive = Some(reflexive);
                self.roam = Some(timeline);
                self.publish_path();
                self.replay_recent(true);
                self.wake_receiver();
            }
            Control::Turn(turn) => {
                tracing::debug!(relayed = %turn.relayed, transport = ?turn.transport, "WireGuard takes a TURN allocation");
                self.retire_turn();
                // The server may hand the old relayed address out again: a
                // `reach` naming it is then about this allocation.
                self.retired_relayed.retain(|addr| *addr != turn.relayed);
                self.turn = Some(turn);
                self.wake_receiver();
                self.retarget_turn();
                self.publish_path();
                // What went into a dead allocation (or nowhere, while a
                // relay-only roam had no carrier) is sent again on the new one.
                if self.direct.is_none_or(|route| route.carrier == Carrier::Turn) {
                    self.replay_recent(true);
                }
            }
            Control::PeerEndpoints { endpoints, relayed, relayed_tls } => {
                tracing::debug!(?endpoints, ?relayed, ?relayed_tls, "WireGuard peer announced new endpoints");
                // An empty list says only that the peer's network changed.
                if !endpoints.is_empty() {
                    // A route a `reach` chose to an address the peer no longer
                    // lists (its old relayed one, after a roam) is over.
                    if self.pinned_until.is_some()
                        && self.direct.is_some_and(|route| !endpoints.contains(&route.addr.to_string()))
                    {
                        self.pinned_until = None;
                        self.demote("the peer left the chosen route's address");
                    }
                    // So is a route to a relayed address the peer replaced (its
                    // old allocation is gone). Relabeled below it would pass for
                    // a direct route, which a relayed arrival never displaces
                    // while it delivered within RELAYED_RECENT: the new relay's
                    // first datagram takes the route instead, and until then
                    // every route gets what is sent.
                    if !relayed.is_empty()
                        && self.direct.is_some_and(|route| {
                            route.carrier == Carrier::Udp
                                && self.labels.peer_relayed.contains(&route.addr)
                                && !relayed.contains(&route.addr.to_string())
                        })
                    {
                        self.direct = None;
                        self.pinned_until = None;
                        self.demote("the peer replaced the route's relayed address");
                    }
                    self.set_peer_endpoints(endpoints);
                    // A roaming phone announces its new TURN address; an
                    // older peer lists none, and the old ones stay (a stale
                    // entry only matters for a datagram from it).
                    if !relayed.is_empty() {
                        self.labels.peer_relayed = addresses(&relayed);
                        self.labels.peer_relayed_tls = addresses(&relayed_tls);
                    }
                    self.publish_path();
                }
                self.spray_until = Some(now + ROAM_SPRAY);
                self.next_spray = None;
                self.last_marker = None;
                // What we sent toward its old network may be lost.
                self.replay_recent(true);
            }
            Control::Reached { from, via_turn } => self.reached(from, via_turn),
            Control::Blackhole => {
                self.blackhole = true;
                self.retire_turn();
                self.turn_targets.clear();
            }
            Control::KillTurn => {
                if let Some(turn) = &self.turn {
                    turn.kill();
                }
            }
        }
    }

    /// The peer's `reach`: our datagrams arrived from `from` (our address as
    /// it saw it), on its TURN allocation when `via_turn`. That names the
    /// carrier that works (our TURN when `from` is our relayed address, else
    /// plain UDP) and whether its destination was the peer's relayed
    /// address. The current route is confirmed only when it is that pair;
    /// otherwise the route becomes that pair (pinned, since our datagrams
    /// may arrive one way while the peer's arrive another).
    fn reached(&mut self, from: Option<SocketAddr>, via_turn: bool) {
        let now = Instant::now();
        let Some(from) = from else {
            // No route named (not sent by this version): the current route.
            self.confirmed = true;
            self.publish_path();
            return;
        };
        if self.retired_relayed.contains(&from) {
            // Sent before this side's TURN allocation was replaced.
            return;
        }
        let carrier = if self.turn.as_ref().is_some_and(|turn| turn.relayed == from) {
            Carrier::Turn
        } else {
            Carrier::Udp
        };
        let fits = |route: &Route, labels: &Labels| {
            route.carrier == carrier && labels.peer_relayed.contains(&route.addr) == via_turn
        };
        if self.direct.is_some_and(|route| fits(&route, &self.labels)) {
            if !self.confirmed {
                tracing::debug!(direct = ?self.direct, "peer confirmed our datagrams reach it");
            }
            self.confirmed = true;
            self.last_fit = Some(now);
            if self.pinned_until.is_some() {
                self.pinned_until = Some(now + REACH_PIN);
            }
        } else if let Some(route) = self.route_for(carrier, via_turn) {
            // Both may work (copies on every route before confirmation): take
            // the named one only to upgrade to a direct route, or when the
            // current one has gone unconfirmed.
            let upgrade =
                self.is_direct(route) && !self.direct.is_some_and(|current| self.is_direct(current));
            // Unconfirmed for a while since it became the route (a `reach`
            // for it would have arrived at least every 3 s if it worked).
            let since = self.last_fit.map_or(self.route_since, |at| at.max(self.route_since));
            let stale = now.duration_since(since) > REACH_SWITCH_AFTER;
            if upgrade || stale {
                tracing::debug!(?route, current = ?self.direct, "the peer receives us on another route; sending there");
                self.direct = Some(route);
                self.route_since = now;
                self.pinned_until = Some(now + REACH_PIN);
                self.confirmed = true;
                self.last_fit = Some(now);
                self.replay_recent(false);
            }
        }
        self.publish_path();
    }

    /// Drop this side's TURN allocation, remembering its relayed address: a
    /// `reach` naming it was sent before the change.
    fn retire_turn(&mut self) {
        if let Some(old) = self.turn.take().map(|turn| turn.relayed) {
            self.retired_relayed.push(old);
            if self.retired_relayed.len() > 8 {
                self.retired_relayed.remove(0);
            }
        }
    }

    /// Plain UDP to one of the peer's own addresses (not its relayed one).
    fn is_direct(&self, route: Route) -> bool {
        route.carrier == Carrier::Udp && !self.labels.peer_relayed.contains(&route.addr)
    }

    /// A route on `carrier` to the peer's relayed address (`via_turn`) or to
    /// one of its plain addresses.
    fn route_for(&self, carrier: Carrier, via_turn: bool) -> Option<Route> {
        if carrier == Carrier::Udp && no_plain_udp(&self.options) {
            // Plain UDP is off here: whatever arrived, it was not ours.
            return None;
        }
        let usable = |addr: &SocketAddr| carrier == Carrier::Turn || !self.refused.contains(addr);
        let addr = if via_turn {
            let mut relayed: Vec<SocketAddr> =
                self.labels.peer_relayed.iter().copied().filter(usable).collect();
            relayed.sort();
            relayed.first().copied()
        } else if carrier == Carrier::Turn {
            self.turn_targets.iter().copied().find(|addr| !self.labels.peer_relayed.contains(addr))
        } else {
            self.last_udp_from.filter(usable)
        }?;
        if carrier == Carrier::Turn && self.turn.is_none() {
            return None;
        }
        Some(Route { carrier, addr })
    }

    /// Keep `datagram` for a replay, with the class it went out in.
    fn record(&mut self, datagram: &[u8], class: SendClass) {
        // Handshake messages are never worth repeating.
        if cmux_transport::classify(datagram) != cmux_transport::DatagramClass::WireGuardData {
            return;
        }
        let now = Instant::now();
        while self.recent.len() >= REPLAY_MAX
            || self.recent.front().is_some_and(|(at, _, _)| now.duration_since(*at) > REPLAY_AGE)
        {
            self.recent.pop_front();
        }
        self.recent.push_back((now, Bytes::copy_from_slice(datagram), class));
    }

    /// Send what went out lately again, on the current route: the newest
    /// that fit [`REPLAY_BYTES`] (what went into a dead route is the
    /// newest), oldest first (out of order, what was lost would also make
    /// TCP inside the tunnel see duplicate ACKs and resend its window). Replays for a route change (not `forced`) happen at
    /// most every [`REPLAY_GAP`].
    fn replay_recent(&mut self, forced: bool) {
        if self.direct.is_none() {
            self.replay_pending = true;
            return;
        }
        self.replay_pending = false;
        let now = Instant::now();
        if !forced {
            if self.last_replay.is_some_and(|last| now.duration_since(last) < REPLAY_GAP) {
                return;
            }
            self.last_replay = Some(now);
        }
        let mut budget = REPLAY_BYTES;
        let mut recent: Vec<(Bytes, SendClass)> = self
            .recent
            .iter()
            .rev()
            .filter(|(at, _, _)| now.duration_since(*at) <= REPLAY_AGE)
            .take_while(|(_, datagram, _)| {
                let fits = datagram.len() <= budget;
                budget = budget.saturating_sub(datagram.len());
                fits
            })
            .map(|(_, datagram, class)| (datagram.clone(), *class))
            .collect();
        recent.reverse();
        if !recent.is_empty() {
            tracing::debug!(count = recent.len(), "WireGuard resends recent datagrams on the new route");
        }
        for (datagram, class) in recent {
            self.transmit(&datagram, class);
        }
    }

    /// Remember a handshake initiation we just sent, to repeat it until the
    /// peer answers (a newer one replaces it).
    fn note_initiation(&mut self, datagram: &[u8], class: SendClass) {
        if cmux_transport::classify(datagram) != cmux_transport::DatagramClass::WireGuardInitiation {
            return;
        }
        self.handshake_repeat = Some(HandshakeRepeat {
            datagram: Bytes::copy_from_slice(datagram),
            class,
            sent: 0,
            timer: Box::pin(tokio::time::sleep(HANDSHAKE_REPEATS[0])),
        });
        // The receive task polls the timer: have it register this one.
        self.wake_receiver();
    }

    /// Send the pending handshake initiation again when its wait is over.
    fn poll_handshake_repeat(&mut self, cx: &mut Context<'_>) {
        loop {
            let Some(repeat) = &mut self.handshake_repeat else { return };
            if repeat.timer.as_mut().poll(cx).is_pending() {
                return;
            }
            repeat.sent += 1;
            let (datagram, class, sent) = (repeat.datagram.clone(), repeat.class, repeat.sent);
            match HANDSHAKE_REPEATS.get(sent) {
                Some(wait) => repeat.timer.as_mut().reset(Instant::now() + *wait),
                None => self.handshake_repeat = None,
            }
            tracing::debug!(repeat = sent, "WireGuard repeats an unanswered handshake initiation");
            self.send_on_relays(&datagram, class);
        }
    }

    /// Through our TURN allocation, and plain UDP to the peer's relayed
    /// addresses (its TURN allocation).
    fn send_on_relays(&mut self, datagram: &[u8], class: SendClass) {
        self.send_turn_targets(datagram, class);
        if no_plain_udp(&self.options) {
            return;
        }
        let mut relayed: Vec<SocketAddr> = self.labels.peer_relayed.iter().copied().collect();
        relayed.sort();
        for addr in relayed {
            if !self.refused.contains(&addr) && !self.send_udp(datagram, addr) {
                self.refused.insert(addr);
            }
        }
    }

    fn wake_receiver(&self) {
        if let Some(waker) = &self.recv_waker {
            waker.wake_by_ref();
        }
    }

    fn drain_control(&mut self) {
        while let Ok(control) = self.control.try_recv() {
            self.apply(control);
        }
    }

    /// Send one UDP datagram; `false` when the OS refused it.
    fn send_udp(&mut self, datagram: &[u8], target: SocketAddr) -> bool {
        if self.options.refuse_udp_to.is_some_and(|refuse| refuse(&target)) {
            return false;
        }
        if self.options.drop_outbound_udp
            || self.options.block_udp
            || self.blackhole
            || self.options.drop_udp_to.is_some_and(|drop| drop(&target))
        {
            return true;
        }
        if self.options.restrict_inbound_udp {
            self.sent_to.insert(target);
        }
        // A full socket drops the datagram; WireGuard and TCP retransmit.
        match self.socket.try_send_to(datagram, target) {
            Ok(_) => true,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => true,
            Err(error) => {
                tracing::trace!(%error, %target, "UDP send failed");
                false
            }
        }
    }

    /// Through this side's TURN allocation to every peer endpoint it can
    /// reach.
    fn send_turn_targets(&self, datagram: &[u8], class: SendClass) {
        if let Some(turn) = &self.turn {
            for target in &self.turn_targets {
                turn.send(datagram, *target, class);
            }
        }
    }

    /// Send on `route`; `false` when it cannot carry anything (the OS
    /// refused the address, which is then never used for plain UDP again,
    /// or the TURN allocation is gone).
    fn send_on(&mut self, route: Route, datagram: &[u8], class: SendClass) -> bool {
        match route.carrier {
            Carrier::Udp => {
                if self.send_udp(datagram, route.addr) {
                    return true;
                }
                self.refused.insert(route.addr);
                false
            }
            Carrier::Turn => match &self.turn {
                Some(turn) if !turn.is_dead() => {
                    turn.send(datagram, route.addr, class);
                    true
                }
                _ => false,
            },
        }
    }

    /// Plain UDP to every usable candidate but `except`.
    fn spray(&mut self, datagram: &[u8], except: Option<SocketAddr>) {
        let mut refused = Vec::new();
        for candidate in self.candidates.clone() {
            if Some(candidate) != except
                && !self.refused.contains(&candidate)
                && !self.send_udp(datagram, candidate)
            {
                refused.push(candidate);
            }
        }
        self.refused.extend(refused);
    }

    /// With a route: also try the other candidates (the peer's relayed
    /// addresses among them), often right after a roam or while the route is
    /// not confirmed (it may work only toward us), now and then while the
    /// route is not plain UDP (so a direct path is found again).
    fn maybe_spray(&mut self, datagram: &[u8], route: Route) {
        let now = Instant::now();
        let roaming = self.spray_until.is_some_and(|until| now < until);
        // A route through a TURN server, ours or the peer's (plain UDP to its
        // relayed address, as a `reach` may choose), is not direct: keep
        // offering the direct candidates so the path upgrades when they work.
        let relayed = route.carrier != Carrier::Udp || self.labels.peer_relayed.contains(&route.addr);
        let gap = if roaming || !self.confirmed {
            ROAM_SPRAY_GAP
        } else if relayed {
            UPGRADE_SPRAY_GAP
        } else {
            return;
        };
        if self.next_spray.is_some_and(|next| now < next) {
            return;
        }
        self.next_spray = Some(now + gap);
        self.spray(datagram, Some(route.addr));
    }

    fn direct_only(&self) -> bool {
        self.confirmed && self.direct.is_some()
    }

    fn publish_path(&mut self) {
        let own = self.turn.as_ref().map(|turn| turn.transport);
        let path = path_of(self.direct, &self.labels, own);
        if self.direct_only()
            && let Some(roam) = self.roam.take()
        {
            roam.mark(if path == LinkPath::Direct { "roam_direct" } else { "roam_turn" });
        }
        self.path.send_if_modified(|current| std::mem::replace(current, path) != path);
    }

    fn demote(&mut self, why: &str) {
        if self.confirmed {
            tracing::debug!(why, "WireGuard route no longer confirmed; sending on every route again");
        }
        self.confirmed = false;
        self.publish_path();
    }

    /// A STUN answer to this socket's own binding request: consumed.
    fn stun_answer(&mut self, datagram: &[u8], source: SocketAddr) -> bool {
        if self.stun.is_empty() {
            return false;
        }
        let Some(index) = self.stun.iter().position(|(_, server)| *server == source) else { return false };
        let Ok(reflexive) = cmux_transport::stun::parse_binding_success(datagram, &self.stun[index].0) else {
            return false;
        };
        self.stun.swap_remove(index);
        if let Some(tx) = &self.reflexive {
            let _ = tx.send(reflexive);
        }
        true
    }

    fn transmit(&mut self, datagram: &[u8], class: SendClass) {
        if self.pinned_until.is_some_and(|until| Instant::now() >= until) {
            // The peer stopped confirming the route its `reach` chose.
            self.pinned_until = None;
            self.demote("chosen route no longer confirmed");
        }
        if self.direct_only()
            && self.peer_reaches
            && self.last_fit.is_some_and(|at| at.elapsed() > REACH_STALE)
        {
            // Datagrams still arrive, but the peer stopped confirming ours.
            self.demote("route no longer confirmed by the peer");
        }
        if self.direct_only() && self.last_direct.is_some_and(|last| last.elapsed() > DIRECT_STALE) {
            // Nothing came back on the route for a while: offer every route
            // again (the peer's `reach` re-confirms this one if it works).
            self.demote("route silent");
        }
        if self.direct_only()
            && let Some(route) = self.direct
        {
            if self.send_on(route, datagram, class) {
                self.maybe_spray(datagram, route);
                return;
            }
            self.direct = None;
            self.demote("send refused");
        }
        // Not confirmed: the route the peer's datagrams arrive on, and every
        // other way, since what we send may not arrive on it.
        match self.direct {
            Some(route) => {
                if !self.send_on(route, datagram, class) {
                    self.direct = None;
                    self.publish_path();
                }
                if route.carrier == Carrier::Udp {
                    self.send_turn_targets(datagram, class);
                }
                self.maybe_spray(datagram, route);
            }
            None => {
                self.spray(datagram, None);
                self.send_turn_targets(datagram, class);
            }
        }
    }
}

impl Underlay for HybridUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        self.drain_control();
        let class = send_class(datagram);
        self.record(datagram, class);
        self.transmit(datagram, class);
        self.note_initiation(datagram, class);
    }

    fn send_classified(&mut self, datagram: &[u8], priority: cmux_wg::Priority) {
        self.drain_control();
        let class = send_class_of(datagram, priority);
        self.record(datagram, class);
        self.transmit(datagram, class);
        self.note_initiation(datagram, class);
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        if !self.recv_waker.as_ref().is_some_and(|waker| waker.will_wake(cx.waker())) {
            self.recv_waker = Some(cx.waker().clone());
        }
        while let Poll::Ready(Some(control)) = self.control.poll_recv(cx) {
            self.apply(control);
        }
        self.poll_handshake_repeat(cx);
        loop {
            let mut read = ReadBuf::new(buffer);
            match self.socket.poll_recv_from(cx, &mut read) {
                Poll::Ready(Ok(source)) => {
                    let len = read.filled().len();
                    if self.blackhole
                        || self.options.block_udp
                        || (self.options.restrict_inbound_udp && !self.sent_to.contains(&source))
                        || self.stun_answer(&buffer[..len], source)
                    {
                        continue;
                    }
                    return Poll::Ready(Ok(Received {
                        len,
                        origin: Origin { path: UDP_PATH, addr: Some(source) },
                    }));
                }
                // ICMP unreachable and friends: keep going on TURN.
                Poll::Ready(Err(error)) => {
                    tracing::trace!(%error, "UDP receive error");
                    if self.blackhole {
                        // A socket whose network went away can fail every
                        // receive at once; wait for the roam instead of spinning.
                        break;
                    }
                    continue;
                }
                Poll::Pending => break,
            }
        }
        if let Some(turn) = &mut self.turn
            && let Poll::Ready(Some((datagram, from))) = turn.inbound.poll_recv(cx)
        {
            let len = datagram.len().min(buffer.len());
            buffer[..len].copy_from_slice(&datagram[..len]);
            return Poll::Ready(Ok(Received { len, origin: Origin { path: TURN_PATH, addr: Some(from) } }));
        }
        Poll::Pending
    }

    fn authenticated(&mut self, origin: Origin) {
        let now = Instant::now();
        let carrier = match origin.path {
            UDP_PATH => Carrier::Udp,
            TURN_PATH => Carrier::Turn,
            _ => return,
        };
        let Some(addr) = origin.addr else { return };
        // The peer answered (or sent anything authenticated): the path works.
        self.handshake_repeat = None;
        let route = Route { carrier, addr };
        if let Some(roam) = &self.roam {
            roam.mark("roam_first_packet");
        }
        if carrier == Carrier::Udp {
            self.last_udp = Some(now);
            if !self.labels.peer_relayed.contains(&addr) {
                self.last_udp_from = Some(addr);
            }
        }
        // Plain UDP wins over TURN while it keeps arriving, an address the OS
        // refuses to send to is never the route, and a route the peer's
        // `reach` chose stays while it is confirmed.
        let udp_fresh = self.last_udp.is_some_and(|last| now.duration_since(last) <= DIRECT_STALE);
        let keep_udp = carrier == Carrier::Turn
            && udp_fresh
            && self.direct.is_some_and(|current| current.carrier == Carrier::Udp);
        let refused = carrier == Carrier::Udp && self.refused.contains(&addr);
        let pinned = self.pinned_until.is_some_and(|until| now < until);
        let arrival_direct = self.is_direct(route);
        // The peer's direct UDP arrives while most of its datagrams come
        // relayed (its route is TURN): tell it at once, so it can upgrade.
        let upgrade = self.peer_reaches
            && arrival_direct
            && self.last_relayed_arrival.is_some_and(|at| now.duration_since(at) <= RELAYED_RECENT)
            && self.last_upgrade_reach.is_none_or(|at| now.duration_since(at) >= ROAM_SPRAY_GAP);
        if upgrade {
            self.last_upgrade_reach = Some(now);
            let _ = self.reach_out.send((addr, carrier));
        }
        if !arrival_direct {
            self.last_relayed_arrival = Some(now);
        }
        if self.direct == Some(route) {
            self.last_on_route = Some(now);
        }
        // A relayed copy never displaces a direct route that still delivers
        // (both arrive while either side sends on every route).
        let downgrade = !arrival_direct
            && self.direct.is_some_and(|current| self.is_direct(current))
            && self.last_on_route.is_some_and(|at| now.duration_since(at) <= RELAYED_RECENT);
        if !keep_udp && !refused && !pinned && !downgrade && self.direct != Some(route) {
            if self.direct.is_some() {
                // The peer confirmed the old route, not this one (our UDP may
                // be dropped silently): send on every route until it confirms
                // what arrives here, and tell it at once that its datagrams
                // reach us here.
                tracing::debug!(?route, "WireGuard route changed");
                self.confirmed = false;
                self.last_fit = None;
                self.last_marker = None;
                self.direct = Some(route);
                self.route_since = now;
                self.last_on_route = Some(now);
                let forced = self.replay_pending;
                self.replay_recent(forced);
            } else {
                self.direct = Some(route);
                self.route_since = now;
                self.last_on_route = Some(now);
                if self.replay_pending {
                    self.replay_recent(true);
                }
            }
        }
        self.last_direct = Some(now);
        if !self.peer_reaches {
            // An older peer's confirmation went through the retired relay and
            // never arrives: what it sends is all we will learn.
            self.confirmed = true;
        } else {
            let due = match self.last_marker {
                // A new route (or a roam): send now, then repeat.
                None => {
                    self.reach_repeats = REACH_REPEATS.len();
                    true
                }
                Some(last) if self.reach_repeats > 0 => {
                    let wait = REACH_REPEATS[REACH_REPEATS.len() - self.reach_repeats];
                    let due = now.duration_since(last) >= wait;
                    if due {
                        self.reach_repeats -= 1;
                    }
                    due
                }
                Some(last) => now.duration_since(last) >= MARKER_INTERVAL,
            };
            if due {
                self.last_marker = Some(now);
                let _ = self.reach_out.send((addr, carrier));
            }
        }
        self.publish_path();
    }

    fn has_peer(&self) -> bool {
        true
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.direct.map(|route| route.addr)
    }
}

/// Holds the tunnel; dropping it ends the session.
struct Guard {
    session: Arc<Session>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.session.close();
    }
}

struct Tunnel {
    session: Arc<Session>,
    path: watch::Receiver<LinkPath>,
}

/// What a side knows when it starts its tunnel.
struct TunnelSpec<'a> {
    session_id: &'a str,
    peer_device: &'a str,
    socket: UdpSocket,
    private_key: Zeroizing<[u8; 32]>,
    peer_key: [u8; 32],
    own_ip: Ipv4Addr,
    peer_ip: Ipv4Addr,
    peer_endpoints: &'a [String],
    /// Which peer endpoints are its TURN relayed addresses (told in
    /// `wg-init` or `wg-resp`): plain UDP to them is a TURN path.
    peer_relayed: &'a [String],
    peer_relayed_tls: &'a [String],
    /// The peer's protocol version (`version` in its `wg-*`).
    peer_version: u32,
    /// What this side offered the peer.
    own_endpoints: Vec<String>,
    turn: Option<TurnCarrier>,
    /// This side keeps a TURN allocation (again after a roam, or when its
    /// stream to the server dies): the phone whenever offered one, the Mac
    /// when its network blocked UDP.
    keeps_turn: bool,
    dialer: bool,
    stun: Vec<SocketAddr>,
}

fn start_tunnel(
    signaling: &SignalingClient,
    spec: TunnelSpec<'_>,
    options: &DialOptions,
) -> Result<Tunnel, DialError> {
    let current = Arc::new(Mutex::new(signaling.clone()));
    let (path_tx, path_rx) = watch::channel(LinkPath::NoPath);
    let (control_tx, control_rx) = mpsc::unbounded_channel();
    let (reach_tx, reach_rx) = mpsc::unbounded_channel();
    let (relayed, relayed_tls) = relayed_of(spec.turn.as_ref());
    let turn_dead = spec.turn.as_ref().map(TurnCarrier::dead);
    let underlay = HybridUnderlay::new(
        UnderlaySpec {
            socket: spec.socket,
            peer_endpoints: spec.peer_endpoints,
            peer_relayed: spec.peer_relayed,
            peer_relayed_tls: spec.peer_relayed_tls,
            peer_version: spec.peer_version,
            turn: spec.turn,
            reach_out: reach_tx,
            path: path_tx,
            control: control_rx,
        },
        options,
    );
    let host = |ip: Ipv4Addr| IpNetwork::new(IpAddr::V4(ip), 32).expect("host prefix");
    let config = WgConfig {
        private_key: spec.private_key,
        addresses: vec![InterfaceAddress { address: IpAddr::V4(spec.own_ip), prefix: 32 }],
        mtu: MTU,
        peer_public_key: spec.peer_key,
        preshared_key: None,
        allowed_ips: vec![host(spec.peer_ip)],
        endpoint: None,
        persistent_keepalive: Some(KEEPALIVE_SECONDS),
        peer_addresses: vec![IpAddr::V4(spec.peer_ip)],
    };
    let net = WgNet::start_with_underlay(config, underlay).map_err(transport_error)?;
    let session = Session::register(roam::SessionParts {
        session_id: spec.session_id.to_owned(),
        peer: spec.peer_device.to_owned(),
        dialer: spec.dialer,
        peer_ip: spec.peer_ip,
        signaling: current,
        net: Arc::new(Mutex::new(Some(Arc::new(net)))),
        control: control_tx,
        reach: reach_rx,
        options: options.clone(),
        stun: spec.stun,
        endpoints: spec.own_endpoints,
        relayed: (relayed, relayed_tls),
        keeps_turn: spec.keeps_turn,
        turn_dead,
    });
    Ok(Tunnel { session, path: path_rx })
}

/// The running tunnel, unless `bye` already dropped it.
fn running(net: &Arc<Mutex<Option<Arc<WgNet>>>>) -> Result<Arc<WgNet>, DialError> {
    net.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .ok_or_else(|| DialError::Bye("tunnel closed".into()))
}

impl Dialer for WireGuardDialer {
    fn kind(&self) -> TransportKind {
        TransportKind::WireGuard
    }

    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        mut events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let socket = bind_udp().map_err(transport_error)?;
            let (gathered, turn) =
                tokio::join!(gather_endpoints(&socket, options), TurnCarrier::allocate(options));
            if no_plain_udp(options) && turn.is_none() {
                return Err(DialError::Transport("no TURN allocation, and plain UDP is off".into()));
            }
            let turn_missed = missed_turn(true, turn.as_ref(), options);
            let Gathered { mut endpoints, stun, .. } = gathered;
            let (relayed, relayed_tls) = relayed_of(turn.as_ref());
            endpoints.extend(relayed.iter().cloned());
            if let Some(turn) = &turn {
                options.timeline.mark(if turn.transport.is_stream() {
                    "turn_tls_allocated"
                } else {
                    "turn_allocated"
                });
            }
            options.timeline.mark("endpoints_gathered");
            let (private_key, public_key) = keypair();
            let own_endpoints = endpoints.clone();
            signaling
                .send_signal(
                    mac,
                    session_id,
                    SignalPayload::WgInit {
                        public_key: b64(&public_key),
                        endpoints,
                        overlay_ip: DIALER_OVERLAY.to_string(),
                        lanes: super::offered_lanes(options, options.video_lane, options.webrtc_media),
                        relayed,
                        relayed_tls,
                        version: WG_VERSION,
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            options.timeline.mark("wg_init_sent");
            let agreed;
            let video_agreed;
            let webrtc_media_agreed;
            let (peer_key, peer_endpoints, peer_ip, peer_relayed, peer_relayed_tls, peer_version) = loop {
                match events.next().await? {
                    SessionEvent::Signal(envelope) => match envelope.payload {
                        SignalPayload::WgResp {
                            public_key,
                            endpoints,
                            overlay_ip,
                            lanes,
                            relayed,
                            relayed_tls,
                            version,
                        } => {
                            options.timeline.mark("wg_resp_received");
                            let ip: Ipv4Addr = overlay_ip
                                .parse()
                                .map_err(|_| DialError::Unexpected("wg-resp overlayIP is not IPv4".into()))?;
                            agreed = super::input_lane_agreed(options, &lanes);
                            video_agreed = options.video_lane && super::video_lane_listed(&lanes);
                            webrtc_media_agreed =
                                video_agreed && options.webrtc_media && super::webrtc_media_listed(&lanes);
                            break (parse_key(&public_key)?, endpoints, ip, relayed, relayed_tls, version);
                        }
                        SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                        // A Mac that roamed before this side saw its answer:
                        // the tunnel learns its endpoints from inside.
                        SignalPayload::WgEndpoints { .. } => {}
                        other => return Err(DialError::Unexpected(format!("{other:?}"))),
                    },
                    SessionEvent::Disconnected => return Err(DialError::Signaling("disconnected".into())),
                }
            };
            if peer_ip == DIALER_OVERLAY {
                return Err(DialError::Unexpected("peer overlay address collides".into()));
            }
            let spec = TunnelSpec {
                session_id,
                peer_device: mac,
                socket,
                private_key,
                peer_key,
                own_ip: DIALER_OVERLAY,
                peer_ip,
                peer_endpoints: &peer_endpoints,
                peer_relayed: &peer_relayed,
                peer_relayed_tls: &peer_relayed_tls,
                peer_version,
                own_endpoints,
                turn,
                keeps_turn: true,
                dialer: true,
                stun,
            };
            let tunnel = start_tunnel(signaling, spec, options)?;
            tunnel.session.follow(events.session);
            let guard = Guard { session: Arc::clone(&tunnel.session) };
            let net = tunnel.session.net()?;
            tunnel.session.start_control(&net).await;
            if turn_missed {
                tunnel.session.retry_missing_turn();
            }
            // The media lane's port is bound before the link stream opens, so
            // the Mac's first frames (sent once a browser tab claims the lane)
            // find it.
            let media = if video_agreed {
                match crate::media::wireguard::WgCarrier::open(
                    &net,
                    IpAddr::V4(peer_ip),
                    crate::media::wireguard::Direction::Receive,
                    crate::media::wireguard::StreamSpec::h264_video(),
                    tunnel.session.path_changes(),
                    crate::media::wireguard::Impairment::default(),
                )
                .await
                {
                    Ok(carrier) => {
                        options.timeline.mark("video_lane");
                        Some(super::PendingMedia::Receive(carrier))
                    }
                    Err(error) => {
                        tracing::info!(%error, "no media lane on this tunnel; video stays on the channel");
                        None
                    }
                }
            } else {
                None
            };
            let link_addr = SocketAddr::new(IpAddr::V4(peer_ip), LINK_PORT);
            let stream = net.connect(link_addr).await.map_err(transport_error)?;
            // The input lane: a second TCP stream to the same port, opened
            // after the main one so the Mac tells them apart by order. Its
            // own socket buffers keep keystrokes out of the main stream's
            // 256 KiB send buffer.
            let lane = agreed.then(|| {
                let (tx, rx) = oneshot::channel();
                tokio::spawn(async move {
                    match tokio::time::timeout(LANE_TIMEOUT, net.connect(link_addr)).await {
                        Ok(Ok(stream)) => {
                            let _ = tx.send(Box::new(stream) as Box<dyn super::LinkStream>);
                        }
                        Ok(Err(error)) => tracing::info!(%error, "input lane did not connect"),
                        Err(_) => tracing::info!("input lane did not connect in time"),
                    }
                });
                rx
            });
            // A media session needs the tunnel's lane as its floor.
            let webrtc_media = webrtc_media_agreed && media.is_some();
            Ok(Dialed {
                stream: Box::new(stream),
                path: tunnel.path,
                guard: Box::new(guard),
                lane,
                media,
                webrtc_media,
            })
        })
    }

    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let SignalPayload::WgInit {
                public_key,
                endpoints: peer_endpoints,
                overlay_ip,
                lanes,
                relayed: peer_relayed,
                relayed_tls: peer_relayed_tls,
                version: peer_version,
            } = first.payload
            else {
                return Err(DialError::Unexpected("expected wg-init".into()));
            };
            let agreed = super::input_lane_agreed(options, &lanes);
            let video_wanted = options.video_lane && super::video_lane_listed(&lanes);
            let webrtc_media_wanted =
                video_wanted && options.webrtc_media && super::webrtc_media_listed(&lanes);
            let peer_key = parse_key(&public_key)?;
            let peer_ip: Ipv4Addr = overlay_ip
                .parse()
                .map_err(|_| DialError::Unexpected("wg-init overlayIP is not IPv4".into()))?;
            let own_ip = if peer_ip == ANSWER_OVERLAY { DIALER_OVERLAY } else { ANSWER_OVERLAY };
            let socket = bind_udp().map_err(transport_error)?;
            let gathered = gather_endpoints(&socket, options).await;
            // A Mac whose network answers no STUN (it drops UDP) takes its
            // own TURN allocation, over TLS when UDP to the server fails too.
            let wants_turn = no_plain_udp(options) || gathered.udp_looks_blocked();
            let turn = if wants_turn { TurnCarrier::allocate(options).await } else { None };
            if no_plain_udp(options) && turn.is_none() {
                return Err(DialError::Transport("no TURN allocation, and plain UDP is off".into()));
            }
            let turn_missed = missed_turn(wants_turn, turn.as_ref(), options);
            let Gathered { mut endpoints, stun, .. } = gathered;
            let (own_relayed, own_relayed_tls) = relayed_of(turn.as_ref());
            endpoints.extend(own_relayed.iter().cloned());
            let (private_key, own_public) = keypair();
            let spec = TunnelSpec {
                session_id: &first.session_id,
                peer_device: &first.from,
                socket,
                private_key,
                peer_key,
                own_ip,
                peer_ip,
                peer_endpoints: &peer_endpoints,
                peer_relayed: &peer_relayed,
                peer_relayed_tls: &peer_relayed_tls,
                peer_version,
                own_endpoints: endpoints.clone(),
                keeps_turn: wants_turn,
                turn,
                dialer: false,
                stun,
            };
            let tunnel = start_tunnel(signaling, spec, options)?;
            tunnel.session.follow(events.session);
            let guard = Guard { session: Arc::clone(&tunnel.session) };
            let net = tunnel.session.net()?;
            tunnel.session.start_control(&net).await;
            if turn_missed {
                tunnel.session.retry_missing_turn();
            }
            let mut listener = net.listen(LINK_PORT).await.map_err(transport_error)?;
            // The media lane: listed back only once its port is bound, so a
            // phone never expects a lane this side cannot serve.
            let media = if video_wanted {
                let impairment = crate::media::wireguard::Impairment {
                    drop_permille: options.video_drop_permille,
                    cap_bps: options.video_cap_bps,
                    blackout: options.video_blackout,
                };
                match crate::media::wireguard::WgCarrier::open(
                    &net,
                    IpAddr::V4(peer_ip),
                    crate::media::wireguard::Direction::Send,
                    crate::media::wireguard::StreamSpec::h264_video(),
                    tunnel.session.path_changes(),
                    impairment,
                )
                .await
                {
                    Ok(carrier) => Some(carrier),
                    Err(error) => {
                        tracing::info!(%error, "no media lane on this tunnel; video stays on the channel");
                        None
                    }
                }
            } else {
                None
            };
            drop(net);
            signaling
                .send_signal(
                    &first.from,
                    &first.session_id,
                    SignalPayload::WgResp {
                        public_key: b64(&own_public),
                        endpoints,
                        overlay_ip: own_ip.to_string(),
                        lanes: super::offered_lanes(options, media.is_some(), webrtc_media_wanted),
                        relayed: own_relayed,
                        relayed_tls: own_relayed_tls,
                        version: WG_VERSION,
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let stream =
                listener.accept().await.ok_or_else(|| DialError::Transport("tunnel closed".into()))?;
            // The phone's second connection is the input lane.
            let lane = agreed.then(|| {
                let (tx, rx) = oneshot::channel();
                tokio::spawn(async move {
                    if let Ok(Some(stream)) = tokio::time::timeout(LANE_TIMEOUT, listener.accept()).await {
                        let _ = tx.send(Box::new(stream) as Box<dyn super::LinkStream>);
                    } else {
                        tracing::info!("input lane was not opened in time");
                    }
                });
                rx
            });
            let webrtc_media = webrtc_media_wanted && media.is_some();
            Ok(Dialed {
                stream: Box::new(stream),
                path: tunnel.path,
                guard: Box::new(guard),
                lane,
                webrtc_media,
                media: media.map(|carrier| {
                    options.timeline.mark("video_lane");
                    super::PendingMedia::Send(carrier)
                }),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Mac reaches a relay-only phone by plain UDP to the phone's TURN
    /// relayed address: that path is TURN (or TURN over TLS when the phone's
    /// allocation rides TLS), not direct.
    #[test]
    fn udp_to_the_peers_relayed_address_is_a_turn_path() {
        let relayed: SocketAddr = "203.0.113.7:50000".parse().unwrap();
        let relayed_tls: SocketAddr = "203.0.113.8:50001".parse().unwrap();
        let lan: SocketAddr = "192.168.1.20:41000".parse().unwrap();
        let labels = Labels {
            peer_relayed: [relayed, relayed_tls].into_iter().collect(),
            peer_relayed_tls: [relayed_tls].into_iter().collect(),
        };
        let udp = |addr| Some(Route { carrier: Carrier::Udp, addr });
        let turn = Some(Route { carrier: Carrier::Turn, addr: lan });
        assert_eq!(path_of(udp(relayed), &labels, None), LinkPath::Turn);
        assert_eq!(path_of(udp(relayed_tls), &labels, None), LinkPath::TurnTls);
        assert_eq!(path_of(udp(lan), &labels, None), LinkPath::Direct);
        assert_eq!(path_of(turn, &labels, Some(TurnTransport::Udp)), LinkPath::Turn);
        assert_eq!(path_of(turn, &labels, Some(TurnTransport::Tls)), LinkPath::TurnTls);
        assert_eq!(path_of(turn, &labels, Some(TurnTransport::Tcp)), LinkPath::TurnTls);
        assert_eq!(path_of(None, &labels, None), LinkPath::NoPath);
        // An older phone lists no relayed addresses: the label stays as before.
        assert_eq!(path_of(udp(relayed), &Labels::default(), None), LinkPath::Direct);
    }

    /// What the tunnel's pacer knows decides the class, not the size: a
    /// full-size segment of an interactive connection (terminal output) is
    /// input, media is media, and handshakes and keepalives stay control.
    #[test]
    fn send_classes_follow_the_pacer() {
        use cmux_wg::Priority;
        let data = |len: usize| {
            let mut datagram = vec![0u8; len];
            datagram[0] = 4;
            datagram
        };
        assert_eq!(send_class_of(&data(1312), Priority::Interactive), SendClass::Input);
        assert_eq!(send_class_of(&data(1312), Priority::Media), SendClass::Media);
        assert_eq!(send_class_of(&data(1312), Priority::Bulk), SendClass::Bulk);
        assert_eq!(send_class_of(&data(96), Priority::Bulk), SendClass::Bulk);
        assert_eq!(send_class_of(&data(32), Priority::Media), SendClass::Control, "keepalive");
        let mut initiation = vec![0u8; 148];
        initiation[0] = 1;
        assert_eq!(send_class_of(&initiation, Priority::Bulk), SendClass::Control);
    }

    /// The phone roams from one TURN allocation to another and announces its
    /// new relayed address. The Mac's route to the old one is dead, not a
    /// direct route: the phone's first datagram from the new relay takes the
    /// route at once, not after the 1 s guard that keeps relayed copies off a
    /// direct route that still delivers. (Holding the dead route stalled the
    /// Mac's output about 1 s on such a roam: the CI flake of
    /// `wireguard_roam_with_udp_blocked_takes_a_fresh_turn_tls_allocation`.)
    #[tokio::test]
    async fn a_route_to_the_peers_retired_relayed_address_gives_way_to_its_new_one() {
        let old: SocketAddr = "203.0.113.7:50000".parse().unwrap();
        let new: SocketAddr = "203.0.113.9:50002".parse().unwrap();
        let lan = "192.168.1.20:41000".to_owned();
        let (reach_out, _reaches) = mpsc::unbounded_channel();
        let (_control, control) = mpsc::unbounded_channel();
        let mut underlay = HybridUnderlay::new(
            UnderlaySpec {
                socket: UdpSocket::bind("127.0.0.1:0").await.unwrap(),
                peer_endpoints: &[old.to_string(), lan.clone()],
                peer_relayed: &[old.to_string()],
                peer_relayed_tls: &[old.to_string()],
                peer_version: WG_VERSION,
                turn: None,
                reach_out,
                path: watch::channel(LinkPath::NoPath).0,
                control,
            },
            &DialOptions::default(),
        );
        let udp_from = |addr| Origin { path: UDP_PATH, addr: Some(addr) };
        underlay.authenticated(udp_from(old));
        assert_eq!(underlay.direct, Some(Route { carrier: Carrier::Udp, addr: old }));
        underlay.apply(Control::PeerEndpoints {
            endpoints: vec![new.to_string(), lan],
            relayed: vec![new.to_string()],
            relayed_tls: vec![new.to_string()],
        });
        underlay.authenticated(udp_from(new));
        assert_eq!(underlay.direct, Some(Route { carrier: Carrier::Udp, addr: new }));
    }

    /// A Mac on Ethernet and Wi-Fi with Tailscale (the user's laptop: en7
    /// 172.20.21.166 primary, en0 10.88.184.154, utun 100.89.49.105) offered
    /// only its primary address, so a phone on the Wi-Fi or on Tailscale had
    /// no direct route, while WebRTC's host candidates cover every interface.
    /// Every usable IPv4 address is offered, the primary one first.
    #[test]
    fn host_endpoints_cover_every_interface_primary_first() {
        let ip = |text: &str| text.parse::<IpAddr>().unwrap();
        let interfaces = [
            ip("127.0.0.1"),
            ip("10.88.184.154"),
            ip("172.20.21.166"),
            ip("169.254.12.3"),
            ip("100.89.49.105"),
            ip("fe80::1"),
            ip("2001:db8::7"),
            ip("10.88.184.154"),
        ];
        let options = DialOptions::default();
        assert_eq!(
            host_ips(Some(ip("172.20.21.166")), &interfaces, &options),
            vec![ip("172.20.21.166"), ip("10.88.184.154"), ip("100.89.49.105")],
        );
        // Tailscale addresses stay out when CGNAT is excluded; no primary
        // (no default route) still offers the others.
        let no_cgnat = DialOptions { exclude_cgnat: true, ..DialOptions::default() };
        assert_eq!(host_ips(None, &interfaces, &no_cgnat), vec![ip("10.88.184.154"), ip("172.20.21.166")]);
    }

    /// The answering Mac's first handshake initiation goes out when its tunnel
    /// starts, before the phone has a TURN permission for the Mac (the phone
    /// has not seen `wg-resp` yet), so the phone's TURN server drops it. Behind
    /// a NAT whose mapping depends on the destination (the office NAT: one
    /// port toward the STUN server, another toward the relay), the phone's
    /// own initiation goes to the Mac's announced reflexive address and is
    /// dropped too. Nothing then reaches either side until boringtun's next
    /// initiation 5 s later: every TURN link came up in 5.1 to 6.1 s, right
    /// after the Mac logged `HANDSHAKE(REKEY_TIMEOUT)`. An unanswered
    /// initiation is sent again within the first seconds, until the peer
    /// answers.
    #[tokio::test(start_paused = true)]
    async fn an_unanswered_handshake_initiation_is_repeated_until_the_peer_answers() {
        // A plain socket: its reads see what loopback delivered at once
        // (a tokio socket's `try_recv` waits for the reactor to see it).
        let peer = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        peer.set_nonblocking(true).unwrap();
        let relayed = peer.local_addr().unwrap();
        let (reach_out, _reaches) = mpsc::unbounded_channel();
        let (_control, control) = mpsc::unbounded_channel();
        let mut underlay = HybridUnderlay::new(
            UnderlaySpec {
                socket: UdpSocket::bind("127.0.0.1:0").await.unwrap(),
                peer_endpoints: &[relayed.to_string()],
                peer_relayed: &[relayed.to_string()],
                peer_relayed_tls: &[],
                peer_version: WG_VERSION,
                turn: None,
                reach_out,
                path: watch::channel(LinkPath::NoPath).0,
                control,
            },
            &DialOptions::default(),
        );
        let mut initiation = vec![0u8; cmux_transport::classify::WG_INITIATION_LEN];
        initiation[0] = 1;
        let copies = |peer: &std::net::UdpSocket| {
            let mut buffer = [0u8; 256];
            std::iter::from_fn(|| peer.recv(&mut buffer).ok()).count()
        };
        underlay.send(&initiation);
        // Short of boringtun's own retry (REKEY_TIMEOUT, 5 s).
        drive(&mut underlay, Duration::from_millis(4500)).await;
        assert!(copies(&peer) >= 3, "the initiation went out once and was never repeated");
        // Answered: no more copies.
        underlay.send(&initiation);
        underlay.authenticated(Origin { path: UDP_PATH, addr: Some(relayed) });
        let _ = copies(&peer);
        drive(&mut underlay, Duration::from_millis(4500)).await;
        assert_eq!(copies(&peer), 0, "an answered initiation was repeated");
    }

    /// Poll the underlay's receive side (which runs its timers) for `wait`.
    async fn drive(underlay: &mut HybridUnderlay, wait: Duration) {
        let mut buffer = vec![0u8; 2048];
        let receive = std::future::poll_fn(|cx| underlay.poll_recv(cx, &mut buffer));
        let _ = tokio::time::timeout(wait, receive).await;
    }

    /// The phone roams to a new TURN allocation, and the Mac replays only
    /// the newest of what it sent recently that fits [`REPLAY_BYTES`],
    /// oldest first. What went into the dead route is the newest, and a
    /// whole replay overflowed the TURN server's relay socket (8 to 18 of
    /// its datagrams dropped in every round; Linux caps buffers at
    /// `rmem_max`, about 208 KB), which drops what arrives last: the
    /// datagram TCP inside the tunnel was missing, so it waited out its 1 s
    /// retransmission (the `stalled 1.0s` flake of
    /// `wireguard_roam_with_udp_blocked_takes_a_fresh_turn_tls_allocation`).
    /// Newest first instead would lose the newest in the TURN carrier's
    /// queue, which drops from the front.
    #[tokio::test]
    async fn a_roam_replays_the_newest_datagrams_that_fit_oldest_first() {
        let old_relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let new_relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (old, new) = (old_relay.local_addr().unwrap(), new_relay.local_addr().unwrap());
        let (reach_out, _reaches) = mpsc::unbounded_channel();
        let (_control, control) = mpsc::unbounded_channel();
        let mut underlay = HybridUnderlay::new(
            UnderlaySpec {
                socket: UdpSocket::bind("127.0.0.1:0").await.unwrap(),
                peer_endpoints: &[old.to_string()],
                peer_relayed: &[old.to_string()],
                peer_relayed_tls: &[old.to_string()],
                peer_version: WG_VERSION,
                turn: None,
                reach_out,
                path: watch::channel(LinkPath::NoPath).0,
                control,
            },
            &DialOptions::default(),
        );
        // A socket the runtime has not seen writable yet refuses `try_send_to`.
        underlay.socket.writable().await.unwrap();
        let udp_from = |addr| Origin { path: UDP_PATH, addr: Some(addr) };
        underlay.authenticated(udp_from(old));
        // Recent WireGuard data, each datagram distinct (its fifth byte),
        // more than a replay sends.
        const SIZE: usize = 1200;
        const SENT: u8 = 100;
        for n in 0..SENT {
            let mut datagram = vec![n; SIZE];
            datagram[..4].copy_from_slice(&[4, 0, 0, 0]);
            underlay.send(&datagram);
        }
        // The roam: the phone's network changed, its first datagram comes
        // from the new relay, then it announces that relay.
        underlay.apply(Control::PeerEndpoints {
            endpoints: Vec::new(),
            relayed: Vec::new(),
            relayed_tls: Vec::new(),
        });
        underlay.authenticated(udp_from(new));
        assert_eq!(underlay.direct, Some(Route { carrier: Carrier::Udp, addr: new }));
        underlay.apply(Control::PeerEndpoints {
            endpoints: vec![new.to_string()],
            relayed: vec![new.to_string()],
            relayed_tls: vec![new.to_string()],
        });
        let mut order = Vec::new();
        let mut buffer = [0u8; 2048];
        while let Ok(Ok((len, _))) =
            tokio::time::timeout(Duration::from_millis(200), new_relay.recv_from(&mut buffer)).await
        {
            if len == SIZE {
                order.push(buffer[4]);
            }
        }
        // The first replay on the new route (the route change's).
        let Some(&first) = order.first() else { panic!("nothing reached the new route") };
        let replay: Vec<u8> =
            order.iter().copied().take_while(|&n| n != SENT - 1).chain([SENT - 1]).collect();
        assert_eq!(replay, (first..SENT).collect::<Vec<_>>(), "the newest, oldest first: {order:?}");
        assert!(replay.len() * SIZE <= REPLAY_BYTES, "{} bytes replayed at once", replay.len() * SIZE);
        assert!(replay.len() * SIZE + SIZE > REPLAY_BYTES, "as many as fit: {replay:?}");
    }

    /// The roam's new TURN allocation can get the old one's relayed address
    /// (the server handed the port out again). A `reach` naming it then
    /// confirms the route: it is not one sent before the change. Ignored,
    /// the phone stayed unconfirmed for the rest of the roam (the flake's
    /// `no roam_turn`, about 1 round in 100 with the test server's 100 relay
    /// ports).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_new_allocation_on_the_old_relayed_address_is_confirmed() {
        let turn = crate::testing::TestTurn::start().await;
        let options = DialOptions {
            ice_servers: vec![turn.ice.clone()],
            turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
            include_loopback: true,
            ..DialOptions::default()
        };
        let first = TurnCarrier::allocate(&options).await.expect("a TURN allocation");
        let relayed = first.relayed;
        let mut second = TurnCarrier::allocate(&options).await.expect("a second TURN allocation");
        second.relayed = relayed;
        let mac: SocketAddr = "127.0.0.1:9".parse().unwrap();
        let (reach_out, _reaches) = mpsc::unbounded_channel();
        let (_control, control) = mpsc::unbounded_channel();
        let mut underlay = HybridUnderlay::new(
            UnderlaySpec {
                socket: UdpSocket::bind("127.0.0.1:0").await.unwrap(),
                peer_endpoints: &[mac.to_string()],
                peer_relayed: &[],
                peer_relayed_tls: &[],
                peer_version: WG_VERSION,
                turn: Some(first),
                reach_out,
                path: watch::channel(LinkPath::NoPath).0,
                control,
            },
            &options,
        );
        underlay.authenticated(Origin { path: TURN_PATH, addr: Some(mac) });
        assert_eq!(underlay.direct, Some(Route { carrier: Carrier::Turn, addr: mac }));
        underlay.apply(Control::Turn(second));
        assert!(!underlay.confirmed);
        underlay.apply(Control::Reached { from: Some(relayed), via_turn: false });
        assert!(underlay.confirmed, "a reach naming the new allocation confirms the route");
    }

    /// A local STUN server that answers every binding request with the
    /// sender's address.
    async fn answering_stun() -> SocketAddr {
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = server.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buffer = [0u8; 1500];
            while let Ok((len, from)) = server.recv_from(&mut buffer).await {
                if len < 20 {
                    continue;
                }
                let mut transaction = [0u8; 12];
                transaction.copy_from_slice(&buffer[8..20]);
                let reply = cmux_transport::stun::binding_success(transaction, from);
                let _ = server.send_to(&reply, from).await;
            }
        });
        addr
    }

    /// Cloudflare lists STUN on 3478 and on 53, and many cellular networks
    /// answer port 53 themselves (their DNS) or drop it. One silent server
    /// must not hold every dial and every roam for the whole STUN wait: once
    /// one answered, the others get a short grace.
    #[tokio::test]
    async fn a_silent_stun_server_does_not_hold_the_gather() {
        let answering = answering_stun().await;
        // Nothing listens there: no answer ever comes.
        let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let silent_addr = silent.local_addr().unwrap();
        let options = DialOptions {
            include_loopback: true,
            ice_servers: vec![crate::api::IceServer {
                urls: vec![format!("stun:{answering}"), format!("stun:{silent_addr}")],
                username: None,
                credential: None,
            }],
            ..DialOptions::default()
        };
        let socket = bind_udp().unwrap();
        let started = Instant::now();
        let gathered = gather_endpoints(&socket, &options).await;
        let took = started.elapsed();
        assert_eq!(gathered.answered, 1, "{gathered:?}");
        assert!(took < Duration::from_millis(600), "gathering waited {took:?} for a silent STUN server");
        drop(silent);
    }

    #[test]
    fn no_stun_answer_means_udp_looks_blocked() {
        let stun: SocketAddr = "198.51.100.1:3478".parse().unwrap();
        let blocked = Gathered { endpoints: vec!["192.168.1.2:4000".into()], stun: vec![stun], answered: 0 };
        assert!(blocked.udp_looks_blocked());
        assert!(!Gathered { answered: 1, ..blocked }.udp_looks_blocked());
        // No STUN server asked (tests, LAN only): no evidence either way.
        assert!(!Gathered { endpoints: Vec::new(), stun: Vec::new(), answered: 0 }.udp_looks_blocked());
    }
}
