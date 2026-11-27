//! Wi-Fi and cell together (ultra-connectivity P3, RFD 0164 B6).
//!
//! The platform tells the link which interfaces are up ([`set_interfaces`],
//! from iOS `NWPathMonitor`, one entry per interface); the policy is here.
//! When the primary interface is not cellular and a cellular interface is
//! up too, every live session that the peer can take it on
//! ([`MULTIPATH_VERSION`]) gets a second UDP socket bound to the cellular
//! interface. Its routes are probed like the primary socket's, but kept
//! out of the session's path selector: they never carry bulk while a path
//! on the primary interface lives. What they do carry:
//!
//! - every [`crate::class_queue::SendClass::Input`] datagram (keystrokes,
//!   small echo, TCP ACKs, class 0 and 1 datagrams) a second time, so a
//!   Wi-Fi that stalls or dies loses no keystroke and no echo;
//! - everything, while no primary path is alive (the selector holds none or
//!   suspects its route): the session rides cell from the first unanswered
//!   probe, not after a roam;
//! - the session itself once Wi-Fi is gone: [`set_interfaces`] without the
//!   primary promotes the warm socket (its NAT mapping is open and the peer
//!   already probes it), so the move costs no handshake and no new mapping.
//!
//! The peer learns which of the phone's addresses are cellular from the
//! roam announcement's `metered` list and keeps them out of its own
//! selector the same way: it duplicates its echo onto them, and moves bulk
//! there only when nothing else is alive.
//!
//! Off when the person turned it off ([`set_cellular_assist`]), in Low Data
//! Mode (a constrained interface), and while the app is backgrounded.

use std::collections::{HashSet, VecDeque};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::ops::Deref;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::{DatagramClass, PathId, classify};
use cmux_wg::{Origin, Received};
use serde::{Deserialize, Serialize};
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::time::Instant;

use super::{Carrier, HybridUnderlay, Route, UDP_PATH, no_plain_udp};
use crate::class_queue::{INPUT_MAX, SendClass};

/// The `wg-offer` / `wg-answer` protocol version at which a side takes a
/// second socket's datagrams and the `metered` announcement list.
pub const MULTIPATH_VERSION: u32 = 3;

/// What an interface is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InterfaceKind {
    Wifi,
    Cellular,
    Wired,
    Other,
}

/// One network interface that is up, as the platform sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetInterface {
    /// The BSD name (`en0`, `pdp_ip0`; Linux `wlan0`, `wwan0`).
    pub name: String,
    pub kind: InterfaceKind,
    /// The OS marks it expensive (cellular, a personal hotspot).
    pub expensive: bool,
    /// Low Data Mode is on for it.
    pub constrained: bool,
    /// The OS's preferred interface (the default route).
    pub primary: bool,
}

/// The interfaces up now, as the platform last said.
static INTERFACES: Mutex<Vec<NetInterface>> = Mutex::new(Vec::new());
/// The person allows cell beside Wi-Fi (on unless they turn it off).
static CELLULAR_ASSIST: AtomicBool = AtomicBool::new(true);

/// The platform's interfaces changed. Every live session gets or drops its
/// second socket at once, and one whose primary interface went away moves
/// onto its warm second socket.
pub fn set_interfaces(interfaces: Vec<NetInterface>) {
    // One report of the path: the primary's kind is also the cellular flag
    // Ultra's repair cap reads ([`super::set_cellular_path`]). An empty list
    // says nothing about the path and leaves the flag as it was.
    if let Some(primary) = interfaces.iter().find(|interface| interface.primary) {
        super::set_cellular_path(primary.kind == InterfaceKind::Cellular);
    }
    *INTERFACES.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = interfaces;
    super::apply_multipath_to_live_sessions();
}

/// The interfaces [`set_interfaces`] stored last.
pub fn interfaces() -> Vec<NetInterface> {
    INTERFACES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// The person's setting: cell carries a second copy of keystrokes and echo
/// while Wi-Fi is up.
pub fn set_cellular_assist(allowed: bool) {
    CELLULAR_ASSIST.store(allowed, Ordering::Relaxed);
    super::apply_multipath_to_live_sessions();
}

pub fn cellular_assist() -> bool {
    CELLULAR_ASSIST.load(Ordering::Relaxed)
}

/// The interface a second socket should be bound to, if any: a cellular
/// interface beside a primary that is not cellular, with nothing in Low
/// Data Mode, the person's consent and the app in the foreground.
pub fn secondary_interface(
    interfaces: &[NetInterface],
    allowed: bool,
    backgrounded: bool,
) -> Option<NetInterface> {
    if !allowed || backgrounded || interfaces.iter().any(|interface| interface.constrained) {
        return None;
    }
    let primary = interfaces.iter().find(|interface| interface.primary)?;
    if primary.kind == InterfaceKind::Cellular {
        return None;
    }
    interfaces
        .iter()
        .find(|interface| interface.kind == InterfaceKind::Cellular && !interface.primary)
        .cloned()
}

/// Datagrams from the second socket (beside `UDP_PATH`, `TURN_PATH` and
/// `RELAY_PATH`, which is 3).
pub(super) const SECONDARY_PATH: PathId = PathId(4);

/// A peer address heard within this long is where copies go.
const HEARD_RECENT: Duration = Duration::from_secs(14);
/// A roam this soon after a promotion keeps the promoted socket: the OS
/// reports the network change after the promotion already moved the
/// session, and a fresh socket would only throw the warm mapping away.
const PROMOTED_KEEP: Duration = Duration::from_secs(5);
/// Peer addresses a copy goes to before one answered on the second socket.
const MAX_SPRAY: usize = 6;
/// After the second socket's address went to the peer (as metered), copies
/// wait this long before they go to an address not heard on it: a peer
/// that sees them first takes the address for an ordinary path.
const ANNOUNCE_GRACE: Duration = Duration::from_millis(300);
/// Receive errors in a row on the second socket before it waits.
const MAX_ERRORS: usize = 8;
/// The second socket's first STUN retry; each later one waits twice as
/// long, up to [`STUN_RETRY_MAX`]. One request lost on a lossy carrier link
/// (or in a carrier NAT's first-packet race) must not leave the peer without
/// the metered address: then no copy goes out before Wi-Fi dies.
const STUN_RETRY_FIRST: Duration = Duration::from_millis(200);
const STUN_RETRY_MAX: Duration = Duration::from_secs(2);
/// Small data datagrams that authenticated, kept so a copy that lost the
/// race (WireGuard's replay window drops it unread) can still be told from
/// a stranger's: at most this many, for at most [`AUTHENTIC_KEEP`].
const AUTHENTIC_MAX: usize = 128;
const AUTHENTIC_KEEP: Duration = Duration::from_secs(2);

/// A small WireGuard data datagram's identity: receiver index and counter
/// (bytes 4..16) and its Poly1305 tag (the last 16 bytes). The tag is a MAC
/// under the session key over that header and the ciphertext, so nobody
/// without the key makes a datagram with the key of one that authenticated
/// except by copying it whole.
type CopyKey = [u8; 28];

fn copy_key(datagram: &[u8]) -> Option<CopyKey> {
    if datagram.len() > INPUT_MAX || classify(datagram) != DatagramClass::WireGuardData {
        return None;
    }
    let mut key = [0u8; 28];
    key[..12].copy_from_slice(&datagram[4..16]);
    key[12..].copy_from_slice(&datagram[datagram.len() - 16..]);
    Some(key)
}

/// A tunnel UDP socket: IPv4, or dual-stack IPv6 (a second socket on an
/// IPv6-only cellular network, 464XLAT or NAT64). On a dual-stack one an
/// IPv4 target leaves as `::ffff:a.b.c.d` (Darwin refuses an IPv4 sockaddr
/// on an IPv6 socket) and an IPv4 source comes back as plain IPv4, so the
/// addresses it sees compare equal to the peer's and STUN servers'.
pub(super) struct TunnelSocket {
    socket: UdpSocket,
    v6: bool,
}

impl TunnelSocket {
    pub(super) fn new(socket: UdpSocket) -> Self {
        let v6 = socket.local_addr().is_ok_and(|addr| addr.is_ipv6());
        Self { socket, v6 }
    }

    fn wire(&self, target: SocketAddr) -> SocketAddr {
        match target {
            SocketAddr::V4(v4) if self.v6 => SocketAddr::from((v4.ip().to_ipv6_mapped(), v4.port())),
            _ => target,
        }
    }

    pub(super) fn try_send_to(&self, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        self.socket.try_send_to(datagram, self.wire(target))
    }

    pub(super) fn poll_recv_from(
        &self,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<SocketAddr>> {
        self.socket
            .poll_recv_from(cx, buffer)
            .map_ok(|source| if self.v6 { canonical(source) } else { source })
    }
}

impl Deref for TunnelSocket {
    type Target = UdpSocket;
    fn deref(&self) -> &UdpSocket {
        &self.socket
    }
}

/// `::ffff:a.b.c.d` as `a.b.c.d`.
fn canonical(addr: SocketAddr) -> SocketAddr {
    SocketAddr::new(addr.ip().to_canonical(), addr.port())
}

/// A socket bound to the second interface, as the session hands it over.
pub(super) struct SecondarySocket {
    /// Not yet registered with the runtime: the platform's call that binds
    /// it may come on any thread; the tunnel task takes it on its own.
    pub socket: std::net::UdpSocket,
    pub interface: String,
    /// Where to ask its reflexive address, and where the answer goes (the
    /// session announces it as metered).
    pub stun: Vec<SocketAddr>,
    pub reflexive: mpsc::UnboundedSender<Option<SocketAddr>>,
}

pub(super) struct Secondary {
    socket: TunnelSocket,
    interface: String,
    /// The peer address its datagrams last came from on this socket.
    peer: Option<SocketAddr>,
    last_heard: Option<Instant>,
    stun: Vec<([u8; 12], SocketAddr)>,
    reflexive: mpsc::UnboundedSender<Option<SocketAddr>>,
    /// When its reflexive address went to the session for the peer.
    announced: Option<Instant>,
    /// When the unanswered STUN requests go again, and the wait after that.
    stun_retry: (Instant, Duration),
}

impl Secondary {
    fn heard_peer(&self, now: Instant) -> Option<SocketAddr> {
        self.peer.filter(|_| self.last_heard.is_some_and(|at| now.duration_since(at) <= HEARD_RECENT))
    }

    fn stun_answer(&mut self, datagram: &[u8], source: SocketAddr) -> bool {
        let Some(index) = self.stun.iter().position(|(_, server)| *server == source) else { return false };
        let Ok(reflexive) = cmux_transport::stun::parse_binding_success(datagram, &self.stun[index].0) else {
            return false;
        };
        self.stun.swap_remove(index);
        tracing::debug!(%reflexive, interface = self.interface, "the second socket's address, announced as metered");
        let _ = self.reflexive.send(Some(reflexive));
        self.announced.get_or_insert_with(Instant::now);
        true
    }

    /// Send the unanswered STUN requests again when their wait is over.
    fn retry_stun(&mut self, now: Instant) {
        if self.stun.is_empty() || now < self.stun_retry.0 {
            return;
        }
        let gap = self.stun_retry.1;
        self.stun_retry = (now + gap, (gap * 2).min(STUN_RETRY_MAX));
        for (transaction, server) in &self.stun {
            let _ = self.socket.try_send_to(&cmux_transport::stun::binding_request(*transaction), *server);
        }
        tracing::debug!(
            interface = self.interface,
            pending = self.stun.len(),
            "the second socket asks STUN again"
        );
    }
}

/// An underlay's second-interface state, on either side.
#[derive(Default)]
pub(super) struct Assist {
    /// The phone: its socket on the cellular interface.
    secondary: Option<Secondary>,
    /// The Mac: the phone's addresses on its metered interface, as it
    /// announced them ([`HybridUnderlay::is_metered`]).
    peer_metered: HashSet<SocketAddr>,
    /// The Mac: the metered address the phone's authenticated datagrams
    /// last came from.
    metered_from: Option<(SocketAddr, Instant)>,
    /// The Mac: the small data datagram last handed to WireGuard, and where
    /// from; it joins [`Assist::authentic`] if WireGuard authenticates it.
    handed: Option<(Origin, CopyKey)>,
    /// The Mac: small data datagrams that authenticated lately (newest
    /// last). A byte-for-byte copy of one, arriving from a metered address,
    /// is the phone's losing copy: authenticated by the tag it shares.
    authentic: VecDeque<(CopyKey, Instant)>,
    /// When a promotion moved the session onto the warm socket.
    promoted: Option<Instant>,
    /// Copies sent on the second interface (telemetry and tests).
    pub(super) copies: u64,
    /// Datagrams the primary socket returned in a row: past
    /// [`PRIMARY_BURST`] the second socket is read first once, so a busy
    /// Wi-Fi socket never starves the cell one.
    pub(super) primary_streak: usize,
}

/// See [`Assist::primary_streak`].
pub(super) const PRIMARY_BURST: usize = 16;

impl HybridUnderlay {
    /// A path on the primary interface answers and the selector trusts it.
    fn primary_alive(&self) -> bool {
        self.paths.drives() && !self.paths.suspect()
    }

    /// Compared by IP (a carrier NAT may map another port toward us than
    /// toward the STUN server), unless the phone's current route shares
    /// that IP (both interfaces behind one NAT, or loopback): then only the
    /// exact address.
    pub(super) fn is_metered(&self, addr: SocketAddr) -> bool {
        let metered = &self.assist.peer_metered;
        if metered.contains(&addr) {
            return true;
        }
        let shared = self.direct.is_some_and(|route| route.addr.ip() == addr.ip());
        !shared && metered.iter().any(|metered| metered.ip() == addr.ip())
    }

    /// Take (`Some`) or drop the second socket.
    pub(super) fn attach_secondary(&mut self, socket: Option<SecondarySocket>) {
        if let Some(old) = self.assist.secondary.take() {
            tracing::debug!(interface = old.interface, "WireGuard drops its second socket");
        }
        let Some(SecondarySocket { socket, interface, stun, reflexive }) = socket else { return };
        let socket = match UdpSocket::from_std(socket) {
            Ok(socket) => TunnelSocket::new(socket),
            Err(error) => {
                tracing::debug!(%error, interface, "second socket not taken");
                return;
            }
        };
        tracing::debug!(
            interface,
            local = ?socket.local_addr().ok(),
            stun = stun.len(),
            "WireGuard takes a second socket"
        );
        // Every transaction is kept, sent or not: a socket the runtime just
        // took may refuse its first send, and a request that never left must
        // be asked again like one lost on the way.
        let mut transactions = Vec::new();
        let mut unsent = false;
        for server in stun {
            let mut transaction = [0u8; 12];
            getrandom::fill(&mut transaction).expect("operating system randomness");
            let request = cmux_transport::stun::binding_request(transaction);
            unsent |= socket.try_send_to(&request, server).is_err();
            transactions.push((transaction, server));
        }
        let first_retry = if unsent { Duration::ZERO } else { STUN_RETRY_FIRST };
        self.assist.secondary = Some(Secondary {
            socket,
            interface,
            peer: None,
            last_heard: None,
            stun: transactions,
            reflexive,
            announced: None,
            stun_retry: (Instant::now() + first_retry, STUN_RETRY_FIRST),
        });
        self.wake_receiver();
    }

    /// The peer named its metered addresses (none: it has no second
    /// interface now). They leave the selector's paths.
    pub(super) fn set_peer_metered(&mut self, addresses: &[String]) {
        self.assist.peer_metered =
            addresses.iter().filter_map(|text| text.parse::<SocketAddr>().ok()).collect();
        tracing::debug!(metered = ?self.assist.peer_metered, "the peer's metered addresses");
        let learned = std::mem::take(&mut self.learned);
        self.learned = learned.into_iter().filter(|addr| !self.is_metered(*addr)).collect();
        // A cellular route learned before the announcement arrived must not
        // keep carrying bulk: demote it, and the selector picks again.
        if self.direct.is_some_and(|route| {
            route.carrier == Carrier::Udp && self.assist.peer_metered.contains(&route.addr)
        }) {
            self.direct = None;
            self.pinned_until = None;
            self.demote("the route's address is metered");
        }
        if self.assist.metered_from.is_some_and(|(addr, _)| !self.is_metered(addr)) {
            self.assist.metered_from = None;
        }
        if self.assist.peer_metered.is_empty() {
            self.assist.handed = None;
            self.assist.authentic.clear();
        }
    }

    /// After `transmit`: a second copy of a keystroke, echo or ACK on the
    /// second interface, and of everything while no primary path is alive.
    pub(super) fn assist_send(&mut self, datagram: &[u8], class: SendClass) {
        if self.assist.secondary.is_none() && self.assist.metered_from.is_none() {
            return;
        }
        let now = Instant::now();
        if let Some(secondary) = &mut self.assist.secondary {
            secondary.retry_stun(now);
        }
        let alive = self.primary_alive();
        if alive && !matches!(class, SendClass::Input | SendClass::Control) {
            return;
        }
        if let Some(secondary) = &self.assist.secondary {
            let targets: Vec<SocketAddr> = match secondary.heard_peer(now) {
                Some(peer) => vec![peer],
                // While the primary lives the peer must know the address is
                // metered first; once it is dead, any way in will do.
                None if alive
                    && secondary.announced.is_none_or(|at| now.duration_since(at) < ANNOUNCE_GRACE) =>
                {
                    return;
                }
                None => {
                    // Nothing heard on it yet: the peer's addresses, public
                    // ones first (a carrier network reaches no LAN).
                    let mut relayed: Vec<SocketAddr> = self.labels.peer_relayed.iter().copied().collect();
                    relayed.sort();
                    let mut targets: Vec<SocketAddr> = Vec::new();
                    for addr in self.candidates.iter().chain(self.learned.iter()).chain(relayed.iter()) {
                        if !targets.contains(addr) {
                            targets.push(*addr);
                        }
                    }
                    targets.sort_by_key(|addr| !is_public(addr.ip()));
                    targets.truncate(MAX_SPRAY);
                    targets
                }
            };
            if self.options.block_udp || self.options.drop_outbound_udp {
                return;
            }
            for target in targets {
                if self.options.drop_udp_to.is_some_and(|drop| drop(&target)) {
                    continue;
                }
                if self.options.restrict_inbound_udp {
                    self.sent_to.insert(target);
                }
                if secondary.socket.try_send_to(datagram, target).is_ok() {
                    self.assist.copies += 1;
                }
            }
            return;
        }
        if let Some((addr, at)) = self.assist.metered_from
            && now.duration_since(at) <= HEARD_RECENT
            && self.direct.is_none_or(|route| route.addr != addr)
            && !no_plain_udp(&self.options)
            && self.send_udp(datagram, addr)
        {
            self.assist.copies += 1;
        }
    }

    /// The second socket's next datagram (`None`: nothing now).
    pub(super) fn poll_secondary(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Option<Received> {
        for _ in 0..MAX_ERRORS {
            let secondary = self.assist.secondary.as_mut()?;
            let mut read = ReadBuf::new(buffer);
            match secondary.socket.poll_recv_from(cx, &mut read) {
                Poll::Ready(Ok(source)) => {
                    let len = read.filled().len();
                    if secondary.stun_answer(&buffer[..len], source)
                        || self.options.block_udp
                        || (self.options.restrict_inbound_udp && !self.sent_to.contains(&source))
                    {
                        continue;
                    }
                    // A copy that lost the race to the primary interface
                    // never authenticates (WireGuard's replay window drops
                    // it), so a known peer address counts as heard here.
                    if self.candidates.contains(&source)
                        || self.learned.contains(&source)
                        || self.labels.peer_relayed.contains(&source)
                    {
                        secondary.peer = Some(source);
                        secondary.last_heard = Some(Instant::now());
                    }
                    let origin = Origin { path: SECONDARY_PATH, addr: Some(source) };
                    if self.impaired(&buffer[..len], origin) {
                        continue;
                    }
                    return Some(Received { len, origin });
                }
                Poll::Ready(Err(error)) => tracing::trace!(%error, "second socket receive error"),
                Poll::Pending => return None,
            }
        }
        // Ready every time, so no waker is registered: ask to be polled
        // again, or what is left on the socket waits for the primary's.
        cx.waker().wake_by_ref();
        None
    }

    /// On the primary socket, before authentication: a datagram from one
    /// of the phone's metered addresses moves where copies go only if it
    /// is a copy of one that authenticated (a copy that lost the race to
    /// Wi-Fi fails WireGuard's replay check unread). Anything else from a
    /// metered IP (another subscriber behind the carrier NAT, a spoofer)
    /// waits for WireGuard ([`Self::assist_heard`]).
    pub(super) fn note_arrival(&mut self, source: SocketAddr, datagram: &[u8]) {
        if self.assist.peer_metered.is_empty() || !self.is_metered(source) {
            return;
        }
        let Some(key) = copy_key(datagram) else { return };
        let now = Instant::now();
        if self
            .assist
            .authentic
            .iter()
            .any(|(seen, at)| *seen == key && now.duration_since(*at) <= AUTHENTIC_KEEP)
        {
            self.assist.metered_from = Some((source, now));
        }
    }

    /// The Mac, as a datagram goes to WireGuard: remember it, in case it
    /// authenticates.
    pub(super) fn note_handed(&mut self, datagram: &[u8], origin: Origin) {
        self.assist.handed = if self.assist.peer_metered.is_empty() {
            None
        } else {
            copy_key(datagram).map(|key| (origin, key))
        };
    }

    /// `true`: an authenticated datagram the route rules must not see (it
    /// came on the second interface, or from the phone's metered one while
    /// a primary path lives).
    pub(super) fn assist_heard(&mut self, origin: Origin, now: Instant) -> bool {
        if let Some((handed, key)) = self.assist.handed.take()
            && handed == origin
        {
            let authentic = &mut self.assist.authentic;
            while authentic.len() >= AUTHENTIC_MAX
                || authentic.front().is_some_and(|(_, at)| now.duration_since(*at) > AUTHENTIC_KEEP)
            {
                authentic.pop_front();
            }
            authentic.push_back((key, now));
        }
        let Some(addr) = origin.addr else { return false };
        if origin.path == SECONDARY_PATH {
            if let Some(secondary) = &mut self.assist.secondary {
                secondary.peer = Some(addr);
                secondary.last_heard = Some(now);
            }
            return true;
        }
        if origin.path == UDP_PATH && self.is_metered(addr) {
            self.assist.metered_from = Some((addr, now));
            return self.primary_alive();
        }
        false
    }

    /// A probe's answer for a probe that came on the second socket.
    pub(super) fn send_secondary(&mut self, datagram: &[u8]) -> bool {
        let Some(secondary) = &self.assist.secondary else { return false };
        if let Some(peer) = secondary.peer {
            let _ = secondary.socket.try_send_to(datagram, peer);
        }
        true
    }

    /// The second interface became the primary one (Wi-Fi is gone): the
    /// warm socket carries the session from now on, to the peer address
    /// that answered on it.
    pub(super) fn promote(&mut self) {
        let Some(secondary) = self.assist.secondary.take() else { return };
        let now = Instant::now();
        let heard = secondary.heard_peer(now);
        tracing::debug!(interface = secondary.interface, ?heard, "WireGuard moves onto its second socket");
        if let Some(route) = self.direct.take()
            && route.carrier == Carrier::Udp
            && !no_plain_udp(&self.options)
            && !self.candidates.contains(&route.addr)
        {
            self.candidates.push(route.addr);
        }
        self.socket = secondary.socket;
        self.blackhole = false;
        self.dark = false;
        self.learned.clear();
        self.refused.clear();
        self.sent_to.clear();
        self.paths.on_network_change();
        self.route_since = now;
        self.last_on_route = None;
        self.pinned_until = None;
        self.last_fit = None;
        self.last_marker = None;
        self.confirmed = false;
        self.direct = heard.map(|addr| Route { carrier: Carrier::Udp, addr });
        if let Some(addr) = heard {
            self.last_direct = Some(now);
            self.last_udp = Some(now);
            self.last_udp_from = Some(addr);
            if !self.candidates.contains(&addr) {
                self.learned.push(addr);
            }
        }
        self.spray_until = Some(now + super::ROAM_SPRAY);
        self.next_spray = None;
        self.assist.promoted = Some(now);
        let _ = secondary.reflexive.send(None);
        self.publish_path();
        self.replay_recent(true);
        self.wake_receiver();
    }

    /// A roam right after a promotion: the promoted socket is on the new
    /// network already. Ask its reflexive address again and keep the route.
    pub(super) fn rebind_after_promotion(&mut self) -> bool {
        let Some(at) = self.assist.promoted.take() else { return false };
        at.elapsed() <= PROMOTED_KEEP
    }
}

/// An address a cellular interface can reach (the peer's LAN addresses
/// cannot be, from a carrier network).
fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => !(v4.is_private() || v4.is_loopback() || v4.is_link_local() || is_cgnat(v4)),
        IpAddr::V6(v6) => !(v6.is_loopback() || v6.is_unicast_link_local() || v6.is_unique_local()),
    }
}

fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..128).contains(&b)
}

/// Bind a tunnel socket to `interface` (iOS `IP_BOUND_IF`/`IPV6_BOUND_IF`,
/// Linux `SO_BINDTODEVICE`), so what it sends leaves there whatever the
/// default route is. Dual-stack IPv6 where the system has it (an IPv6-only
/// cellular network reaches the peer's IPv6 candidates, and its IPv4 ones
/// through 464XLAT), else IPv4.
pub(super) fn bind_udp_on(interface: &str) -> io::Result<std::net::UdpSocket> {
    let index = interface_index(interface)?;
    bind_dual_stack(Some(index)).or_else(|error| {
        tracing::debug!(%error, interface, "no dual-stack second socket; IPv4 only");
        bind_v4(Some(index))
    })
}

fn tunnel_socket(domain: socket2::Domain) -> io::Result<socket2::Socket> {
    let socket = socket2::Socket::new(domain, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    let _ = socket.set_recv_buffer_size(super::UDP_BUFFER);
    let _ = socket.set_send_buffer_size(super::UDP_BUFFER);
    socket.set_nonblocking(true)?;
    Ok(socket)
}

fn bind_dual_stack(index: Option<std::num::NonZeroU32>) -> io::Result<std::net::UdpSocket> {
    let socket = tunnel_socket(socket2::Domain::IPV6)?;
    socket.set_only_v6(false)?;
    if index.is_some() {
        bind_device_v6(&socket, index)?;
    }
    socket.bind(&SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0)).into())?;
    Ok(socket.into())
}

fn bind_v4(index: Option<std::num::NonZeroU32>) -> io::Result<std::net::UdpSocket> {
    let socket = tunnel_socket(socket2::Domain::IPV4)?;
    if index.is_some() {
        bind_device_v4(&socket, index)?;
    }
    socket.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)).into())?;
    Ok(socket.into())
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
fn interface_index(interface: &str) -> io::Result<std::num::NonZeroU32> {
    let name = std::ffi::CString::new(interface).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: `name` is a valid NUL-terminated string for the call.
    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
    std::num::NonZeroU32::new(index).ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
fn bind_device_v4(socket: &socket2::Socket, index: Option<std::num::NonZeroU32>) -> io::Result<()> {
    socket.bind_device_by_index_v4(index)
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
fn bind_device_v6(socket: &socket2::Socket, index: Option<std::num::NonZeroU32>) -> io::Result<()> {
    socket.bind_device_by_index_v6(index)
}

#[cfg(not(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android")))]
fn interface_index(_interface: &str) -> io::Result<std::num::NonZeroU32> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

#[cfg(not(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android")))]
fn bind_device_v4(_socket: &socket2::Socket, _index: Option<std::num::NonZeroU32>) -> io::Result<()> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

#[cfg(not(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android")))]
fn bind_device_v6(_socket: &socket2::Socket, _index: Option<std::num::NonZeroU32>) -> io::Result<()> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

#[cfg(test)]
mod tests {
    use super::super::{Control, DialOptions, LinkPath, UnderlaySpec, WG_VERSION};
    use super::*;
    use cmux_wg::Underlay;
    use std::sync::Arc;
    use tokio::sync::watch;

    /// A WireGuard data datagram of `len` bytes (Input up to 400, then Bulk).
    fn data(len: usize, tag: u8) -> Vec<u8> {
        let mut datagram = vec![tag; len];
        datagram[..4].copy_from_slice(&[4, 0, 0, 0]);
        datagram
    }

    fn underlay(peer_endpoints: &[String], socket: UdpSocket, peer_version: u32) -> HybridUnderlay {
        underlay_with(peer_endpoints, socket, peer_version, &DialOptions::default())
    }

    fn underlay_with(
        peer_endpoints: &[String],
        socket: UdpSocket,
        peer_version: u32,
        options: &DialOptions,
    ) -> HybridUnderlay {
        let (reach_out, _reaches) = mpsc::unbounded_channel();
        let (_control, control) = mpsc::unbounded_channel();
        HybridUnderlay::new(
            UnderlaySpec {
                socket,
                peer_endpoints,
                peer_relayed: &[],
                peer_relayed_tls: &[],
                peer_version,
                turn: None,
                reach_out,
                path: watch::channel(LinkPath::NoPath).0,
                route_to: Arc::new(watch::channel(None).0),
                control,
                relay_shared: Default::default(),
            },
            options,
        )
    }

    /// The selector holds `peer` (a probe on it was answered).
    fn drive(underlay: &mut HybridUnderlay, peer: SocketAddr, now: Instant) {
        underlay.authenticated(Origin { path: UDP_PATH, addr: Some(peer) });
        for (path, probe) in underlay.poll_probes(now).pings {
            underlay.on_pong(path, probe, now + Duration::from_millis(1));
        }
        assert_eq!(underlay.paths.current(), Some(Route { carrier: Carrier::Udp, addr: peer }));
        assert!(underlay.primary_alive());
    }

    /// A socket standing in for the cellular one, attached to `underlay`.
    async fn attach(underlay: &mut HybridUnderlay) -> SocketAddr {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        let local = socket.local_addr().unwrap();
        let (reflexive, _answers) = mpsc::unbounded_channel();
        underlay.apply(Control::Secondary(Some(SecondarySocket {
            socket,
            interface: "pdp_ip0".into(),
            stun: Vec::new(),
            reflexive,
        })));
        underlay.assist.secondary.as_ref().unwrap().socket.writable().await.unwrap();
        local
    }

    /// Every datagram `peer` receives within `wait`, with where it came from.
    async fn drain(peer: &UdpSocket, wait: Duration) -> Vec<(Vec<u8>, SocketAddr)> {
        let mut got = Vec::new();
        let mut buffer = [0u8; 2048];
        while let Ok(Ok((len, from))) = tokio::time::timeout(wait, peer.recv_from(&mut buffer)).await {
            got.push((buffer[..len].to_vec(), from));
        }
        got
    }

    /// Wi-Fi works: a keystroke leaves on both interfaces, a stream only on
    /// Wi-Fi. Wi-Fi goes dark: everything rides cell from the first
    /// unanswered probe, and a promotion moves the session onto the warm
    /// socket, which a roam right after keeps.
    #[tokio::test]
    async fn keystrokes_ride_both_interfaces_and_the_session_moves_when_wifi_dies() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let primary = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let primary_addr = primary.local_addr().unwrap();
        let mut underlay = underlay(&[peer_addr.to_string()], primary, WG_VERSION);
        let start = Instant::now();
        drive(&mut underlay, peer_addr, start);
        underlay.socket.writable().await.unwrap();
        let cell = attach(&mut underlay).await;
        // The peer answered on cell once (a probe's answer, or a copy).
        assert!(
            underlay.assist_heard(Origin { path: SECONDARY_PATH, addr: Some(peer_addr) }, Instant::now())
        );
        assert_eq!(underlay.direct, Some(Route { carrier: Carrier::Udp, addr: peer_addr }));

        underlay.send(&data(120, 1));
        let got = drain(&peer, Duration::from_millis(200)).await;
        let mut from: Vec<SocketAddr> = got.iter().map(|(_, from)| *from).collect();
        from.sort();
        let mut both = vec![primary_addr, cell];
        both.sort();
        assert_eq!(from, both, "a keystroke goes on Wi-Fi and on cell");

        underlay.send(&data(1200, 2));
        let got = drain(&peer, Duration::from_millis(200)).await;
        assert_eq!(
            got.iter().map(|(_, from)| *from).collect::<Vec<_>>(),
            vec![primary_addr],
            "a stream stays on Wi-Fi"
        );

        // Wi-Fi dies: nothing it sends leaves.
        underlay.apply(Control::Dark(true));
        let route = Route { carrier: Carrier::Udp, addr: peer_addr };
        underlay.paths.sent(route, start);
        let mut at = start;
        while !underlay.paths.suspect() && at < start + Duration::from_secs(2) {
            at += Duration::from_millis(20);
            let _ = underlay.poll_probes(at);
        }
        assert!(underlay.paths.suspect());
        underlay.send(&data(1200, 3));
        let got = drain(&peer, Duration::from_millis(200)).await;
        assert!(
            got.iter().any(|(datagram, from)| *from == cell && datagram[4] == 3),
            "with Wi-Fi quiet, a stream rides cell: {got:?}"
        );

        // The phone's OS says cell is primary now: the warm socket carries it.
        underlay.apply(Control::Promote);
        assert_eq!(underlay.socket.local_addr().unwrap(), cell);
        assert!(underlay.assist.secondary.is_none());
        assert_eq!(underlay.direct, Some(route));
        underlay.socket.writable().await.unwrap();
        let _ = drain(&peer, Duration::from_millis(100)).await;
        underlay.send(&data(120, 4));
        let got = drain(&peer, Duration::from_millis(200)).await;
        assert!(got.iter().any(|(datagram, from)| *from == cell && datagram[4] == 4), "{got:?}");

        // The network change the OS reports after it keeps the warm socket.
        let (reflexive, _answers) = mpsc::unbounded_channel();
        let fresh = super::super::bind_udp().unwrap();
        underlay.apply(Control::Rebind {
            socket: fresh,
            stun: Vec::new(),
            reflexive,
            timeline: crate::timing::Timeline::new(),
            new_hop_port: tokio::sync::oneshot::channel().0,
        });
        assert_eq!(
            underlay.socket.local_addr().unwrap(),
            cell,
            "a roam right after a promotion keeps the warm socket"
        );
        assert_eq!(underlay.direct, Some(route));
    }

    /// A Wi-Fi to Wi-Fi roam (no promotion) takes the fresh socket as before
    /// and keeps the second one.
    #[tokio::test]
    async fn a_roam_without_promotion_takes_the_new_socket_and_keeps_cell() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let mut underlay =
            underlay(&[peer_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        drive(&mut underlay, peer_addr, Instant::now());
        attach(&mut underlay).await;
        let fresh = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let fresh_addr = fresh.local_addr().unwrap();
        let (reflexive, _answers) = mpsc::unbounded_channel();
        underlay.apply(Control::Rebind {
            socket: fresh,
            stun: Vec::new(),
            reflexive,
            timeline: crate::timing::Timeline::new(),
            new_hop_port: tokio::sync::oneshot::channel().0,
        });
        assert_eq!(underlay.socket.local_addr().unwrap(), fresh_addr);
        assert!(underlay.assist.secondary.is_some());
    }

    /// The first STUN request on cell is lost: the second socket asks again
    /// until it is answered, and then announces the address as metered.
    #[tokio::test]
    async fn a_lost_stun_request_is_asked_again_until_answered() {
        let stun = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let stun_addr = stun.local_addr().unwrap();
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let mut underlay =
            underlay(&[peer_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        drive(&mut underlay, peer_addr, Instant::now());
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        let (reflexive, mut answers) = mpsc::unbounded_channel();
        underlay.apply(Control::Secondary(Some(SecondarySocket {
            socket,
            interface: "pdp_ip0".into(),
            stun: vec![stun_addr],
            reflexive,
        })));
        // The first request (sent at once, or on the first send after a
        // refused one) arrives and is dropped: lost on the carrier link.
        underlay.assist.secondary.as_ref().unwrap().socket.writable().await.unwrap();
        underlay.assist_send(&data(64, 0), SendClass::Input);
        let mut buffer = [0u8; 1500];
        tokio::time::timeout(Duration::from_secs(1), stun.recv_from(&mut buffer)).await.unwrap().unwrap();
        // Before the retry is due, a keystroke sends no request.
        underlay.assist_send(&data(64, 1), SendClass::Input);
        assert!(tokio::time::timeout(Duration::from_millis(50), stun.recv_from(&mut buffer)).await.is_err());
        tokio::time::sleep(STUN_RETRY_FIRST).await;
        underlay.assist_send(&data(64, 2), SendClass::Bulk);
        let (len, from) =
            tokio::time::timeout(Duration::from_secs(1), stun.recv_from(&mut buffer)).await.unwrap().unwrap();
        let transaction: [u8; 12] = buffer[8..20].try_into().unwrap();
        assert_eq!(&buffer[..len], cmux_transport::stun::binding_request(transaction).as_slice());
        let reflexive_addr: SocketAddr = "198.18.0.43:40000".parse().unwrap();
        stun.send_to(&cmux_transport::stun::binding_success(transaction, reflexive_addr), from)
            .await
            .unwrap();
        let answered = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                std::future::poll_fn(|cx| {
                    let _ = underlay.poll_secondary(cx, &mut buffer);
                    Poll::Ready(())
                })
                .await;
                if let Ok(answer) = answers.try_recv() {
                    return answer;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(answered, Some(reflexive_addr));
        let secondary = underlay.assist.secondary.as_ref().unwrap();
        assert!(secondary.stun.is_empty() && secondary.announced.is_some());
    }

    /// Nothing heard on cell yet and its address not yet told to the peer:
    /// no copy goes (the peer would take it for an ordinary path).
    #[tokio::test]
    async fn no_copy_before_the_peer_knows_the_address_is_metered() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let primary = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let primary_addr = primary.local_addr().unwrap();
        let mut underlay = underlay(&[peer_addr.to_string()], primary, WG_VERSION);
        drive(&mut underlay, peer_addr, Instant::now());
        underlay.socket.writable().await.unwrap();
        attach(&mut underlay).await;
        underlay.send(&data(120, 1));
        let got = drain(&peer, Duration::from_millis(200)).await;
        assert_eq!(got.iter().map(|(_, from)| *from).collect::<Vec<_>>(), vec![primary_addr]);
        // Announced a while ago: copies go to the peer's addresses.
        underlay.assist.secondary.as_mut().unwrap().announced = Some(Instant::now() - ANNOUNCE_GRACE);
        underlay.send(&data(120, 2));
        assert_eq!(drain(&peer, Duration::from_millis(200)).await.len(), 2);
    }

    /// The Mac: the phone's cellular address never enters its selector or
    /// moves its route while Wi-Fi lives, and gets a copy of its echo.
    #[tokio::test]
    async fn the_mac_copies_echo_to_the_phones_metered_address_and_keeps_its_route() {
        let wifi = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wifi_addr = wifi.local_addr().unwrap();
        let cell = UdpSocket::bind("127.0.0.2:0").await.unwrap();
        let cell_addr = cell.local_addr().unwrap();
        let mut mac =
            underlay(&[wifi_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        drive(&mut mac, wifi_addr, Instant::now());
        mac.socket.writable().await.unwrap();
        mac.apply(Control::PeerMetered(vec![cell_addr.to_string()]));
        mac.authenticated(Origin { path: UDP_PATH, addr: Some(cell_addr) });
        assert_eq!(mac.direct, Some(Route { carrier: Carrier::Udp, addr: wifi_addr }));
        assert!(mac.learned.is_empty(), "a metered address is no path");
        mac.send(&data(120, 1));
        assert_eq!(drain(&wifi, Duration::from_millis(150)).await.len(), 1);
        assert_eq!(drain(&cell, Duration::from_millis(150)).await.len(), 1, "echo goes on cell too");
        mac.send(&data(1200, 2));
        assert_eq!(drain(&wifi, Duration::from_millis(150)).await.len(), 1);
        assert!(
            drain(&cell, Duration::from_millis(150)).await.is_empty(),
            "no stream on cell while Wi-Fi lives"
        );
    }

    /// Review F1: a cellular route the Mac took before the phone's
    /// `metered` announcement arrived stops being the route once it does.
    #[tokio::test]
    async fn a_route_that_turns_out_metered_is_demoted() {
        let wifi = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wifi_addr = wifi.local_addr().unwrap();
        let cell = UdpSocket::bind("127.0.0.2:0").await.unwrap();
        let cell_addr = cell.local_addr().unwrap();
        let mut mac =
            underlay(&[wifi_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        mac.direct = Some(Route { carrier: Carrier::Udp, addr: cell_addr });
        mac.apply(Control::PeerMetered(vec![wifi_addr.to_string()]));
        assert_eq!(mac.direct, Some(Route { carrier: Carrier::Udp, addr: cell_addr }), "not metered: kept");
        mac.apply(Control::PeerMetered(vec![cell_addr.to_string()]));
        assert_eq!(mac.direct, None, "a metered route is no longer the route");
    }

    /// Review F2: `restrict_inbound_udp` holds on the second socket too.
    #[tokio::test]
    async fn the_second_socket_drops_strangers_when_inbound_is_restricted() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let stranger = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let options = DialOptions { restrict_inbound_udp: true, ..DialOptions::default() };
        let mut underlay = underlay_with(
            &[peer_addr.to_string()],
            UdpSocket::bind("127.0.0.1:0").await.unwrap(),
            WG_VERSION,
            &options,
        );
        let cell = attach(&mut underlay).await;
        stranger.send_to(&data(120, 1), cell).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut buffer = [0u8; 2048];
        let got = std::future::poll_fn(|cx| Poll::Ready(underlay.poll_secondary(cx, &mut buffer))).await;
        assert!(got.is_none(), "a datagram from an address never sent to is dropped");
        underlay.sent_to.insert(peer_addr);
        peer.send_to(&data(120, 2), cell).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let got = std::future::poll_fn(|cx| Poll::Ready(underlay.poll_secondary(cx, &mut buffer))).await;
        assert_eq!(got.map(|received| received.origin.addr), Some(Some(peer_addr)));
    }

    /// Review F3: a busy primary socket does not starve the second one.
    #[tokio::test]
    async fn a_busy_primary_socket_does_not_starve_the_second() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let primary = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let primary_addr = primary.local_addr().unwrap();
        let mut underlay = underlay(&[peer_addr.to_string()], primary, WG_VERSION);
        let cell = attach(&mut underlay).await;
        for tag in 0..64u8 {
            peer.send_to(&data(120, tag), primary_addr).await.unwrap();
        }
        peer.send_to(&data(120, 0xEE), cell).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut buffer = [0u8; 2048];
        let mut position = None;
        for index in 0..(PRIMARY_BURST + 2) {
            let received = std::future::poll_fn(|cx| underlay.poll_recv(cx, &mut buffer)).await.unwrap();
            if received.origin.path == SECONDARY_PATH {
                position = Some(index);
                break;
            }
        }
        assert!(position.is_some(), "the cell datagram waited behind more than {PRIMARY_BURST} Wi-Fi ones");
    }

    /// Old against new, both ways: a side without a second interface sends
    /// what it always did (one copy), and a peer that never names metered
    /// addresses leaves the route rules as they were.
    #[tokio::test]
    async fn without_a_second_interface_nothing_changes() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let mut old = underlay(&[peer_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), 2);
        drive(&mut old, peer_addr, Instant::now());
        old.socket.writable().await.unwrap();
        old.send(&data(120, 1));
        assert_eq!(drain(&peer, Duration::from_millis(150)).await.len(), 1);
        assert_eq!(old.assist.copies, 0);
    }

    /// The next datagram the underlay hands to WireGuard, if one is there.
    async fn next(underlay: &mut HybridUnderlay) -> Option<Received> {
        let mut buffer = [0u8; 2048];
        tokio::time::timeout(
            Duration::from_millis(200),
            std::future::poll_fn(|cx| underlay.poll_recv(cx, &mut buffer)),
        )
        .await
        .ok()
        .map(|received| received.unwrap())
    }

    /// Review P2 (follow-up 1): a datagram from the phone's metered IP that
    /// never authenticated (another subscriber behind the carrier NAT, a
    /// spoofer) does not move the Mac's copies; a byte-for-byte copy of one
    /// that authenticated (the losing copy, which WireGuard's replay check
    /// drops unread) does, from any port.
    #[tokio::test]
    async fn only_an_authenticated_copy_moves_the_macs_copies() {
        let wifi = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wifi_addr = wifi.local_addr().unwrap();
        let cell = UdpSocket::bind("127.0.0.2:0").await.unwrap();
        let cell_addr = cell.local_addr().unwrap();
        let stranger = UdpSocket::bind("127.0.0.2:0").await.unwrap();
        let mut mac =
            underlay(&[wifi_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        let mac_addr = mac.socket.local_addr().unwrap();
        drive(&mut mac, wifi_addr, Instant::now());
        mac.apply(Control::PeerMetered(vec![cell_addr.to_string()]));

        // Wi-Fi's copy wins and authenticates.
        let keystroke = data(120, 7);
        wifi.send_to(&keystroke, mac_addr).await.unwrap();
        let received = next(&mut mac).await.unwrap();
        assert_eq!(received.origin.addr, Some(wifi_addr));
        mac.authenticated(received.origin);

        // Junk from the metered IP on another port: WireGuard drops it.
        let mut forged = data(120, 9);
        forged[4..16].copy_from_slice(&keystroke[4..16]);
        stranger.send_to(&forged, mac_addr).await.unwrap();
        stranger.send_to(&data(120, 8), mac_addr).await.unwrap();
        assert!(next(&mut mac).await.is_some());
        assert!(next(&mut mac).await.is_some());
        assert_eq!(mac.assist.metered_from, None, "an unauthenticated datagram moved the copies");

        // The losing copy of the authenticated keystroke, from the carrier
        // NAT's other port: copies go there.
        cell.send_to(&keystroke, mac_addr).await.unwrap();
        assert!(next(&mut mac).await.is_some());
        assert_eq!(mac.assist.metered_from.map(|(addr, _)| addr), Some(cell_addr));
    }

    /// Review P2 (follow-up 2): a second socket that returned only datagrams
    /// it skips asks to be polled again (no waker is registered on Ready).
    #[tokio::test]
    async fn a_second_socket_full_of_skipped_datagrams_asks_to_be_polled_again() {
        struct Count(std::sync::atomic::AtomicUsize);
        impl std::task::Wake for Count {
            fn wake(self: Arc<Self>) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let stranger = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let options = DialOptions { restrict_inbound_udp: true, ..DialOptions::default() };
        let mut underlay = underlay_with(
            &[peer.local_addr().unwrap().to_string()],
            UdpSocket::bind("127.0.0.1:0").await.unwrap(),
            WG_VERSION,
            &options,
        );
        let cell = attach(&mut underlay).await;
        for tag in 0..(MAX_ERRORS + 2) as u8 {
            stranger.send_to(&data(120, tag), cell).await.unwrap();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        let count = Arc::new(Count(std::sync::atomic::AtomicUsize::new(0)));
        let waker = std::task::Waker::from(count.clone());
        let mut cx = Context::from_waker(&waker);
        let mut buffer = [0u8; 2048];
        assert!(underlay.poll_secondary(&mut cx, &mut buffer).is_none());
        assert_eq!(count.0.load(Ordering::SeqCst), 1, "datagrams are left on the socket with no wake");
    }

    /// Review P3 (follow-up 4): a datagram on the second socket costs no
    /// allocation.
    #[tokio::test]
    async fn the_second_socket_receives_without_allocating() {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();
        let mut underlay =
            underlay(&[peer_addr.to_string()], UdpSocket::bind("127.0.0.1:0").await.unwrap(), WG_VERSION);
        let cell = attach(&mut underlay).await;
        peer.send_to(&data(120, 1), cell).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut buffer = [0u8; 2048];
        let waker = std::task::Waker::noop();
        let mut cx = Context::from_waker(waker);
        let (received, allocations) = counting::allocations(|| underlay.poll_secondary(&mut cx, &mut buffer));
        assert_eq!(received.map(|received| received.origin.addr), Some(Some(peer_addr)));
        assert_eq!(allocations, 0);
    }

    /// Review P2 (follow-up 3): the second socket is dual-stack. It reaches
    /// an IPv4 peer and an IPv6 one, and an IPv4 peer's datagrams come back
    /// from its plain IPv4 address (not `::ffff:`), so they match the
    /// peer's candidates.
    #[tokio::test]
    async fn the_second_socket_is_dual_stack() {
        let socket = bind_dual_stack(None).unwrap();
        assert!(socket.local_addr().unwrap().is_ipv6());
        let socket = TunnelSocket::new(UdpSocket::from_std(socket).unwrap());
        let port = socket.local_addr().unwrap().port();
        let v4 = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let v4_addr = v4.local_addr().unwrap();
        socket.writable().await.unwrap();
        socket.try_send_to(b"to v4", v4_addr).unwrap();
        let mut buffer = [0u8; 64];
        let (len, from) =
            tokio::time::timeout(Duration::from_secs(1), v4.recv_from(&mut buffer)).await.unwrap().unwrap();
        assert_eq!((&buffer[..len], from.port()), (&b"to v4"[..], port));
        v4.send_to(b"back", SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await.unwrap();
        let source = tokio::time::timeout(
            Duration::from_secs(1),
            std::future::poll_fn(|cx| socket.poll_recv_from(cx, &mut ReadBuf::new(&mut buffer))),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(source, v4_addr, "an IPv4 source compares as IPv4");
        if let Ok(v6) = UdpSocket::bind("[::1]:0").await {
            let v6_addr = v6.local_addr().unwrap();
            socket.try_send_to(b"to v6", v6_addr).unwrap();
            let (len, _) = tokio::time::timeout(Duration::from_secs(1), v6.recv_from(&mut buffer))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&buffer[..len], b"to v6");
        }
        // Bound to an interface: dual-stack where the system allows it.
        if let Ok(bound) = bind_udp_on("lo") {
            assert!(bound.local_addr().unwrap().is_ipv6(), "the bound socket fell back to IPv4");
        }
    }

    fn up(name: &str, kind: InterfaceKind, primary: bool) -> NetInterface {
        NetInterface {
            name: name.into(),
            kind,
            expensive: kind == InterfaceKind::Cellular,
            constrained: false,
            primary,
        }
    }

    #[test]
    fn cell_beside_wifi_is_the_second_interface() {
        let both = [up("en0", InterfaceKind::Wifi, true), up("pdp_ip0", InterfaceKind::Cellular, false)];
        assert_eq!(secondary_interface(&both, true, false).map(|i| i.name), Some("pdp_ip0".into()));
    }

    #[test]
    fn no_second_interface_when_off_backgrounded_constrained_or_on_cell() {
        let both = [up("en0", InterfaceKind::Wifi, true), up("pdp_ip0", InterfaceKind::Cellular, false)];
        assert_eq!(secondary_interface(&both, false, false), None);
        assert_eq!(secondary_interface(&both, true, true), None);
        let mut low_data = both;
        low_data[0].constrained = true;
        assert_eq!(secondary_interface(&low_data, true, false), None);
        let cell_only = [up("pdp_ip0", InterfaceKind::Cellular, true)];
        assert_eq!(secondary_interface(&cell_only, true, false), None);
        let wifi_only = [up("en0", InterfaceKind::Wifi, true)];
        assert_eq!(secondary_interface(&wifi_only, true, false), None);
    }
}

/// Allocations made on this thread inside [`counting::allocations`] (the
/// test binary's allocator; every other allocation passes straight on).
#[cfg(test)]
mod counting {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    struct Counting;

    thread_local! {
        static ON: Cell<bool> = const { Cell::new(false) };
        static COUNT: Cell<usize> = const { Cell::new(0) };
    }

    // SAFETY: every call goes to `System` unchanged; the count is a
    // const-initialized thread local, which never allocates.
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if ON.with(Cell::get) {
                COUNT.with(|count| count.set(count.get() + 1));
            }
            // SAFETY: the caller's contract, passed on.
            unsafe { System.alloc(layout) }
        }
        unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
            // SAFETY: the caller's contract, passed on.
            unsafe { System.dealloc(pointer, layout) }
        }
        unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
            if ON.with(Cell::get) {
                COUNT.with(|count| count.set(count.get() + 1));
            }
            // SAFETY: the caller's contract, passed on.
            unsafe { System.realloc(pointer, layout, size) }
        }
    }

    #[global_allocator]
    static ALLOCATOR: Counting = Counting;

    pub(super) fn allocations<T>(run: impl FnOnce() -> T) -> (T, usize) {
        COUNT.with(|count| count.set(0));
        ON.with(|on| on.set(true));
        let value = run();
        ON.with(|on| on.set(false));
        (value, COUNT.with(Cell::get))
    }
}
