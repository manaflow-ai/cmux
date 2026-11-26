//! Roaming: a WireGuard session that outlives network changes
//! (PROTOCOL.md "WireGuard roaming").
//!
//! When a side's network changes (Wi-Fi to cellular, another Wi-Fi, a new
//! address, back from airplane mode) [`network_changed`] moves every live
//! session onto a fresh UDP socket and at once sends an authenticated
//! datagram from it (a keepalive on a fresh session, else a handshake
//! initiation), so the peer roams to the new address (WireGuard's own
//! endpoint roaming). While the route settles every datagram also goes
//! through TURN and to all of the peer's candidates. In the background the
//! side learns its new reflexive address (STUN on the new socket), the
//! phone (and a Mac that needed TURN) takes a fresh TURN allocation on the
//! transport the new network allows (the old one belongs to the old
//! network), and the new endpoints go to the peer inside the tunnel
//! as overlay UDP datagrams on port [`ROAM_PORT`], resent until
//! acknowledged. The peer then sprays its own datagrams at them, which opens
//! its side of a NAT that filters by address. Keys, the session and every
//! TCP stream stay: nothing is dialed again.
//!
//! A network change usually kills the signaling WebSocket too; [`rehome`]
//! moves the sessions of a device onto its new socket, so `bye` travels
//! again.
//!
//! The same port carries `reach` ("your datagrams reach me", which confirms
//! a route), and a TURN allocation whose TCP or TLS stream dies is replaced
//! the same way a roam replaces it.
//!
//! The session's relay watch ([`RelayShared`], [`run_relay_watch`]) joins
//! cmux's WebSocket relay when nothing else reaches the peer: at once when
//! a side has no other path, a moment after the tunnel starts or the
//! network changes when nothing authenticated by then, when the phone's
//! link falls silent, or when the peer asks (`wg-relay`). The underlay
//! leaves it once another route carries both directions again.

use std::sync::Weak;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_wg::{Priority, WgDatagramSocket};
use serde::{Deserialize, Serialize};
use tokio::task::JoinHandle;

use super::*;
use crate::dial::portmap;
use crate::dial::turn::LateTurn;

/// Overlay UDP port of the roaming messages, next to the link's 7420.
pub const ROAM_PORT: u16 = 7421;
/// Waits before each resend of an endpoint announcement that the peer has
/// not acknowledged.
const ANNOUNCE_RESENDS: [Duration; 5] = [
    Duration::from_millis(150),
    Duration::from_millis(400),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];
/// The most endpoints one announcement may carry.
const MAX_ENDPOINTS: usize = 16;

/// Metered addresses one message carries.
const MAX_METERED: usize = 4;

/// How often this side's metered addresses go again.
const METERED_RESEND: Duration = Duration::from_secs(5);

/// Times an empty `metered` list goes again after the first.
const METERED_CLEARED_RESENDS: usize = 2;

/// Changes the roaming side makes to its [`HybridUnderlay`].
pub(super) enum Control {
    /// This side's network changed: carry the session on `socket`, ask
    /// `stun` for the socket's reflexive address and send what they answer
    /// to `reflexive`. The old TURN allocation is released.
    Rebind {
        socket: UdpSocket,
        stun: Vec<SocketAddr>,
        reflexive: mpsc::UnboundedSender<SocketAddr>,
        timeline: Timeline,
    },
    /// Ask `stun` for the current socket's reflexive address and send what
    /// they answer to `reflexive` (an answer that went out with its host
    /// endpoints only, [`Session::gather_after_answer`]).
    Gather { stun: Vec<SocketAddr>, reflexive: mpsc::UnboundedSender<SocketAddr> },
    /// A TURN allocation on the new network (or replacing a dead one).
    Turn(TurnCarrier),
    /// The peer announced new endpoints.
    PeerEndpoints {
        endpoints: Vec<String>,
        /// Which of them are the peer's TURN relayed addresses.
        relayed: Vec<String>,
        /// Which of `relayed` ride TCP or TLS to their server.
        relayed_tls: Vec<String>,
    },
    /// The peer receives what this side sends (its `reach` message): from
    /// this address of ours, on its TURN allocation when `via_turn`.
    Reached { from: Option<SocketAddr>, via_turn: bool },
    /// Debug and tests: the socket's network is gone.
    Blackhole,
    /// Debug and tests: the network goes dark (`true`: nothing this side
    /// sends leaves and nothing arrives, on its socket or its TURN
    /// allocation) or comes back on the same socket and addresses
    /// (`false`), with no roam: an elevator, a tunnel, a dead cell. A
    /// second socket ([`Control::Secondary`]) is on another interface and
    /// stays up: Wi-Fi dies, cell lives.
    Dark(bool),
    /// Debug and tests: the TURN allocation's stream to its server dies.
    KillTurn,
    /// Take a socket on the second interface (cell beside Wi-Fi), or drop it.
    Secondary(Option<super::multipath::SecondarySocket>),
    /// The second interface became the primary one: carry the session on
    /// its warm socket.
    Promote,
    /// The peer's addresses on its metered interface (its `metered` roam
    /// message; none: it has no second interface now).
    PeerMetered(Vec<String>),
    /// A joined relay socket: one more carrier, beside UDP and TURN.
    Relay(super::RelayCarrier),
    /// Debug and tests: the relay socket dies, as a proxy that resets it.
    KillRelay,
}

/// This session's relay, when both sides offered it.
#[derive(Debug, Clone)]
pub(super) struct RelayPlan {
    pub endpoint: super::super::relay::RelayEndpoint,
    /// Join at once: one side said it has no other path.
    pub now: bool,
    /// This device's relay ticket for the session, as the service stamped it
    /// on a signal to this device (`relayTicket`); `None` from a service that
    /// stamps none, whose join is then refused.
    pub ticket: Option<String>,
    /// A join this side started before the peer's answer, on the ticket the
    /// service sent at once (`wg-ticket`, PROTOCOL.md "Early relay ticket");
    /// the first join takes it instead of starting its own.
    pub early: Option<EarlyJoin>,
}

/// A relay join already under way, taken once.
pub(super) type EarlyJoin = Arc<
    Mutex<
        Option<
            tokio::task::JoinHandle<
                Result<super::super::relay::RelayCarrier, super::super::relay::RelayFailure>,
            >,
        >,
    >,
>;

/// The early join's carrier when one was started, else a join now.
async fn join_or_take(
    plan: &RelayPlan,
    session_id: &str,
    peer: &str,
) -> Result<super::super::relay::RelayCarrier, super::super::relay::RelayFailure> {
    let early = plan.early.as_ref().and_then(|slot| lock(slot).take());
    if let Some(handle) = early {
        match handle.await {
            Ok(joined) => return joined,
            Err(e) => {
                tracing::debug!(session = session_id, error = %e, "the early relay join ended; joining again");
            }
        }
    }
    super::super::relay::RelayRung {
        endpoint: &plan.endpoint,
        session_id,
        peer_device: peer,
        ticket: plan.ticket.as_deref(),
    }
    .join()
    .await
}

/// How long after the tunnel starts, or this side's network changes, a
/// side that heard nothing authenticated joins the relay (TURN over TLS
/// takes two round trips over a stream that is already open by then). A
/// TURN allocation this side takes after that (a trickled answer's, a
/// roam's) is not open by then: it may take 250 ms of STUN silence and then
/// up to 3 s on UDP alone (`NO_STREAM_UDP_WAIT`) or 4 s over TLS. The relay
/// waits for it, and gives one that works this long again
/// ([`RelayShared::gathering_turn`]).
pub(super) const RELAY_AFTER: Duration = Duration::from_secs(3);
/// The phone's link heard nothing authenticated this long while in the
/// foreground: its route died (a network that just started blocking UDP),
/// so it joins the relay and asks the Mac to. Longer than the 10 s
/// keepalive beat and the route rules' 14 s silence.
pub(super) const RELAY_SILENT: Duration = Duration::from_secs(16);
/// A join that failed is tried again after each of these (then the last,
/// while the session still needs it); a refusal no retry changes (`403`,
/// `404`, `503 relay_off`) is not.
const RELAY_RETRIES: [Duration; 4] =
    [Duration::from_secs(1), Duration::from_secs(3), Duration::from_secs(10), Duration::from_secs(30)];
/// A dial that still has other ways (TURN, UDP) to try is given up only this
/// long after its tunnel started, however fast the relay refused: a slow
/// handshake on a lossy network may still get through.
const RELAY_GIVE_UP_AFTER: Duration = Duration::from_secs(8);
/// A session that needs the relay again this soon after leaving it keeps
/// it from then on (one direction works only through it).
const RELAY_STICKY_WITHIN: Duration = Duration::from_secs(300);

/// A held relay whose peer has been away this long, while this side has
/// nothing better (its route is the relay, or it hears nothing), asks the
/// peer back (`wg-relay`): the peer left on its own confirmed route while
/// this side still needs the relay to reach it. Then at most this often.
const RELAY_ASK_BACK: Duration = Duration::from_secs(5);

/// What the session's relay watch and its underlay share.
#[derive(Debug)]
pub(super) struct RelayShared {
    held: AtomicBool,
    sticky: AtomicBool,
    /// The underlay's route is the relay (or it has none).
    on_relay: AtomicBool,
    /// The underlay has a confirmed route other than the relay: the peer
    /// said our datagrams reach it there, and its own arrive (both ways).
    confirmed_elsewhere: AtomicBool,
    /// The held carrier's view of the peer's socket.
    peer_online: Mutex<Option<watch::Receiver<bool>>>,
    /// The newest joined carrier's text side for relay-held sends (RFD 0142
    /// R8): a new join replaces it, so a hold route follows the redials.
    hold_port: watch::Sender<Option<super::super::relay::HoldPort>>,
    state: Mutex<RelayClock>,
    asked: tokio::sync::Notify,
}

#[derive(Debug)]
struct RelayClock {
    /// When the relay socket died while the session needed it: join again
    /// at once, unless something from the peer authenticated since (another
    /// path works, so the session does not need the relay after all).
    lost: Option<Instant>,
    /// When the tunnel started or this side last roamed.
    since: Instant,
    /// When something last authenticated.
    heard: Option<Instant>,
    /// When this side last let the relay go on its own (another route
    /// carried the session): a join soon after makes the relay stick. A
    /// socket that died is not a leave.
    left: Option<Instant>,
    /// The peer asked (`wg-relay`) and this side has not joined since.
    asked: bool,
    /// TURN allocations this side has under way ([`TurnGather`]).
    gathering: u32,
    /// When this side's last [`TurnGather`] took an allocation.
    allocated: Option<Instant>,
}

impl RelayClock {
    /// A TURN allocation of this side is under way, or came up less than
    /// [`RELAY_AFTER`] ago: it gets its chance to carry the session before
    /// the relay does.
    fn turn_window(&self, now: Instant) -> bool {
        self.gathering > 0 || self.allocated.is_some_and(|at| now.duration_since(at) < RELAY_AFTER)
    }
}

/// A TURN allocation this side takes while the session runs (a trickled
/// answer's, a roam's), from start until it is installed or came to
/// nothing; the relay waits for it ([`RelayClock::turn_window`]). A retry
/// after a missed allocation holds none: the allocation had its window.
pub(super) struct TurnGather {
    shared: Arc<RelayShared>,
    allocated: bool,
}

impl TurnGather {
    /// The allocation came up and carries this side's relayed address.
    pub(super) fn allocated(&mut self) {
        self.allocated = true;
    }
}

impl Drop for TurnGather {
    fn drop(&mut self) {
        let mut clock = lock(&self.shared.state);
        clock.gathering = clock.gathering.saturating_sub(1);
        if self.allocated {
            clock.allocated = Some(Instant::now());
        }
        drop(clock);
        // The watch looks again now: an ask it held may be due.
        self.shared.asked.notify_one();
    }
}

impl Default for RelayShared {
    fn default() -> Self {
        Self {
            held: AtomicBool::new(false),
            sticky: AtomicBool::new(false),
            on_relay: AtomicBool::new(true),
            confirmed_elsewhere: AtomicBool::new(false),
            peer_online: Mutex::new(None),
            hold_port: watch::Sender::new(None),
            state: Mutex::new(RelayClock {
                lost: None,
                since: Instant::now(),
                heard: None,
                left: None,
                asked: false,
                gathering: 0,
                allocated: None,
            }),
            asked: tokio::sync::Notify::new(),
        }
    }
}

impl RelayShared {
    pub(super) fn set_held(&self, held: bool) {
        self.held.store(held, Ordering::Relaxed);
        if held {
            let mut clock = lock(&self.state);
            clock.lost = None;
            // An ask that crossed this side's own join is answered by it.
            clock.asked = false;
        }
    }

    /// This side let the relay go because another route carries the session.
    /// Only this arms [`Self::sticky`] for a join soon after (a reset or a
    /// refused grant never does: review of #53163).
    pub(super) fn left(&self) {
        self.set_held(false);
        lock(&self.state).left = Some(Instant::now());
    }

    /// The relay socket died while the session rode it (or had no other
    /// confirmed route): the watch joins again at once, unless the peer is
    /// heard on another path first.
    pub(super) fn lost(&self) {
        self.set_held(false);
        lock(&self.state).lost = Some(Instant::now());
    }

    /// A join the session turned out not to need (the peer answered on
    /// another path while it ran) settles a lost socket too.
    fn not_lost(&self) {
        lock(&self.state).lost = None;
    }

    pub(super) fn held(&self) -> bool {
        self.held.load(Ordering::Relaxed)
    }

    pub(super) fn sticky(&self) -> bool {
        self.sticky.load(Ordering::Relaxed)
    }

    pub(super) fn set_on_relay(&self, on_relay: bool) {
        self.on_relay.store(on_relay, Ordering::Relaxed);
    }

    pub(super) fn set_confirmed_elsewhere(&self, confirmed: bool) {
        self.confirmed_elsewhere.store(confirmed, Ordering::Relaxed);
    }

    fn confirmed_elsewhere(&self) -> bool {
        self.confirmed_elsewhere.load(Ordering::Relaxed)
    }

    /// Whether this side needs its peer on the relay and the peer's socket
    /// is gone: it holds a relay socket the relay says the peer left, and
    /// its route is the relay or nothing came from the peer lately.
    fn peer_needed_back(&self) -> bool {
        if !self.held() || lock(&self.peer_online).as_ref().is_none_or(|online| *online.borrow()) {
            return false;
        }
        let quiet = lock(&self.state).heard.is_none_or(|heard| heard.elapsed() >= RELAY_ASK_BACK);
        self.on_relay.load(Ordering::Relaxed) || quiet
    }

    pub(super) fn heard(&self, at: Instant) {
        lock(&self.state).heard = Some(at);
    }

    fn roamed(&self) {
        let mut clock = lock(&self.state);
        clock.since = Instant::now();
        clock.heard = None;
    }

    /// This side starts a TURN allocation the relay waits for.
    pub(super) fn gathering_turn(self: &Arc<Self>) -> TurnGather {
        lock(&self.state).gathering += 1;
        TurnGather { shared: Arc::clone(self), allocated: false }
    }

    /// The peer asked this side to join (`wg-relay`). Ignored while this
    /// side holds a relay socket: both sides joining at once each ask the
    /// other, and a stale ask must not pull a side back onto the relay after
    /// it left (and make it stick there).
    fn ask(&self) {
        if self.held() {
            return;
        }
        lock(&self.state).asked = true;
        self.asked.notify_one();
    }

    /// Something authenticated after `at`.
    fn heard_after(&self, at: Instant) -> bool {
        lock(&self.state).heard.is_some_and(|heard| heard > at)
    }

    /// How long until the watch looks again: often while a dial or a roam
    /// settles, then about once a second.
    fn poll_gap(&self) -> Duration {
        let clock = lock(&self.state);
        let since = clock.allocated.map_or(clock.since, |at| at.max(clock.since));
        if since.elapsed() < RELAY_AFTER * 2 { Duration::from_millis(250) } else { Duration::from_secs(1) }
    }

    /// Why this side joins now, if it should: `None` while a relay socket is
    /// held or something reaches the peer.
    fn due(&self, dialer: bool) -> Option<&'static str> {
        if self.held() {
            return None;
        }
        let now = Instant::now();
        let mut clock = lock(&self.state);
        if let Some(lost) = clock.lost {
            // Heard since the socket died: another path carries the session.
            if clock.heard.is_some_and(|heard| heard > lost) {
                clock.lost = None;
            } else {
                return Some("the relay socket closed");
            }
        }
        if clock.turn_window(now) {
            // This side's TURN allocation goes first; the peer's ask waits
            // for it too (it may answer that ask on TURN).
            return None;
        }
        if clock.asked {
            // Both directions already work elsewhere: the ask is stale (it
            // crossed this side's own join, or a socket reset).
            if self.confirmed_elsewhere() {
                clock.asked = false;
            } else {
                return Some("the peer joined the relay");
            }
        }
        match clock.heard {
            None if now.duration_since(clock.since) >= RELAY_AFTER => Some("nothing reached the peer"),
            Some(heard)
                if dialer
                    && !super::paths::app_backgrounded()
                    && heard >= clock.since
                    && now.duration_since(heard) >= RELAY_SILENT =>
            {
                Some("the link fell silent")
            }
            _ => None,
        }
    }
}

/// The peer's mapped endpoints as an announcement names them: only those it
/// also lists as endpoints, and its protocol only when this build knows the
/// word.
fn peer_mapped_of(endpoints: &[String], mapped: &[String], mapped_by: Option<&str>) -> portmap::PeerMapped {
    let addresses: Vec<SocketAddr> = mapped
        .iter()
        .filter(|text| endpoints.contains(text))
        .take(MAX_MAPPED)
        .filter_map(|text| text.parse().ok())
        .collect();
    let protocol = if addresses.is_empty() { None } else { mapped_by.and_then(portmap::protocol_word) };
    portmap::PeerMapped { addresses, protocol }
}

/// Relayed addresses one announcement carries (a phone has one TURN
/// allocation), so the message stays within one tunnel datagram.
const MAX_RELAYED: usize = 2;

/// Mapped addresses one announcement carries (one per session socket).
const MAX_MAPPED: usize = 2;

/// This side's endpoints to announce, which of them are its TURN relayed
/// addresses, which of those ride TCP or TLS, and which endpoint its router
/// mapped (and by which protocol).
struct Announcement {
    endpoints: Vec<String>,
    relayed: Vec<String>,
    relayed_tls: Vec<String>,
    mapped: Vec<String>,
    mapped_by: Option<String>,
}

/// Waits before each new try to replace a dead TURN allocation.
const TURN_RETRIES: [Duration; 5] = [
    Duration::ZERO,
    Duration::from_secs(1),
    Duration::from_secs(3),
    Duration::from_secs(10),
    Duration::from_secs(30),
];

/// How long a dialing tunnel waits for its peer's first authenticated
/// datagram (WireGuard's handshake) before it takes TURN over TLS: the
/// handshake repeats at 0.25, 0.75 and 1.75 s, so a path that works answers
/// well within it. A network whose firewall drops WireGuard (PROTOCOL.md
/// "Corporate networks") answers STUN and grants TURN over UDP, and nothing
/// on either carries the tunnel.
pub(super) const SILENT_TUNNEL_DIALER: Duration = Duration::from_secs(3);
/// The same for the answering Mac, longer: the phone's own TURN over TLS
/// usually fixes it first, and then the Mac needs none.
pub(super) const SILENT_TUNNEL_ANSWER: Duration = Duration::from_secs(6);

/// What [`Session::escalate`] did.
enum Escalated {
    /// A TURN allocation over TCP or TLS came up and the peer was told.
    Allocated,
    /// Already on TURN over TCP or TLS.
    NotNeeded,
    /// None came up in time (a retry keeps asking, outside the relay's wait).
    Failed,
    /// A roam holds the session.
    Roaming,
}

/// The roaming messages (JSON in one overlay UDP datagram).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
enum RoamMessage {
    /// This side's endpoints now; `gen` grows with every announcement.
    Endpoints {
        generation: u64,
        endpoints: Vec<String>,
        /// Which of `endpoints` are this side's TURN relayed addresses (the
        /// phone's new allocation), so the Mac keeps labeling a UDP route to
        /// one as TURN after a roam; absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
        /// Which of `relayed` ride TCP or TLS to their server.
        #[serde(rename = "relayedTls", default, skip_serializing_if = "Vec::is_empty")]
        relayed_tls: Vec<String>,
        /// Which of `endpoints` this side's router mapped for it
        /// ([`super::super::portmap`]); absent from older peers, which offer
        /// none, and ignored by them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        mapped: Vec<String>,
        /// Which protocol mapped them (`pcp`, `nat-pmp` or `upnp`).
        #[serde(rename = "mappedBy", default, skip_serializing_if = "Option::is_none")]
        mapped_by: Option<String>,
    },
    Ack {
        generation: u64,
    },
    /// This side's addresses on its metered interface (cell beside Wi-Fi,
    /// protocol version 3; an older peer logs it as unreadable and goes on):
    /// the peer keeps them out of its path selector and sends a copy of its
    /// keystrokes and echo there. Empty: no second interface now.
    Metered {
        #[serde(default)]
        addresses: Vec<String>,
    },
    /// "Your datagrams reach me" (protocol version 2; an older peer logs it
    /// as unreadable and goes on): they arrived from `from` (the sender's
    /// address as seen here), on this side's plain UDP socket or its TURN
    /// allocation (`via`: `udp` or `turn`).
    Reach {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        via: Option<String>,
    },
}

pub(super) struct SessionParts {
    pub session_id: String,
    pub peer: String,
    pub dialer: bool,
    pub peer_ip: Ipv4Addr,
    pub signaling: Arc<Mutex<SignalingClient>>,
    pub net: Arc<Mutex<Option<Arc<WgNet>>>>,
    pub control: mpsc::UnboundedSender<Control>,
    /// The underlay's requests to send the peer `reach`.
    pub reach: mpsc::UnboundedReceiver<(SocketAddr, Carrier)>,
    pub options: DialOptions,
    pub stun: Vec<SocketAddr>,
    pub endpoints: Vec<String>,
    /// This side's TURN relayed addresses among `endpoints`, and those over
    /// TCP or TLS.
    pub relayed: (Vec<String>, Vec<String>),
    pub keeps_turn: bool,
    /// Fires when the current TURN allocation's stream dies.
    pub turn_dead: Option<watch::Receiver<bool>>,
    /// The underlay's current plain-UDP destination.
    pub route_to: Arc<watch::Sender<Option<SocketAddr>>>,
    /// The peer's protocol version (`version` in its `wg-*`).
    pub peer_version: u32,
    /// cmux's relay for this session, when both sides offered it.
    pub relay: Option<RelayPlan>,
    pub relay_shared: Arc<RelayShared>,
}

/// One live tunnel, as roaming sees it.
pub(super) struct Session {
    session_id: String,
    peer: String,
    dialer: bool,
    peer_ip: Ipv4Addr,
    signaling: Arc<Mutex<SignalingClient>>,
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    control: mpsc::UnboundedSender<Control>,
    reach: Mutex<Option<mpsc::UnboundedReceiver<(SocketAddr, Carrier)>>>,
    options: DialOptions,
    stun: Mutex<Vec<SocketAddr>>,
    /// This side's endpoints as last offered to the peer.
    endpoints: Mutex<Vec<String>>,
    /// Which of them are this side's TURN relayed addresses (all, over a
    /// stream).
    relayed: Mutex<(Vec<String>, Vec<String>)>,
    /// Takes a new TURN allocation after a roam or a dead stream (the phone;
    /// a Mac once its network blocked UDP).
    keeps_turn: AtomicBool,
    /// This network carries no WireGuard over UDP ([`Session::escalate_when_silent`]):
    /// a new allocation takes TCP or TLS, never UDP, until the next roam.
    stream_only: AtomicBool,
    turn_monitor: Mutex<Option<JoinHandle<()>>>,
    /// Announcements the peer sent through signaling, for the control task.
    inject: mpsc::UnboundedSender<RoamMessage>,
    injected: Mutex<Option<mpsc::UnboundedReceiver<RoamMessage>>>,
    /// Asks the control task to send its latest announcement through
    /// signaling again: `false` for a new signaling socket, `true` to nudge
    /// a peer whose route went quiet ([`Self::nudge_peer`]).
    resignal: mpsc::UnboundedSender<bool>,
    resignals: Mutex<Option<mpsc::UnboundedReceiver<bool>>>,
    follow: Mutex<Option<JoinHandle<()>>>,
    announce: Mutex<Option<mpsc::UnboundedSender<Announcement>>>,
    control_task: Mutex<Option<JoinHandle<()>>>,
    roaming: tokio::sync::Mutex<()>,
    last_roam: Mutex<Option<Timeline>>,
    /// Counts network changes on either side (the media lane asks for a
    /// keyframe after each).
    path_epoch: Arc<watch::Sender<u64>>,
    /// Counts this side's roams (a TURN replacement started before one is
    /// stale).
    roams: std::sync::atomic::AtomicU64,
    closed: AtomicBool,
    route_to: Arc<watch::Sender<Option<SocketAddr>>>,
    /// The peer takes a second socket's datagrams and the `metered` message
    /// (protocol version [`super::multipath::MULTIPATH_VERSION`]).
    multipath: bool,
    /// The interface the underlay's second socket is bound to.
    secondary: Mutex<Option<String>>,
    /// The second socket's reflexive address (`None`: gone), for the control
    /// task to announce as metered.
    metered: Mutex<Option<mpsc::UnboundedSender<Option<SocketAddr>>>>,
    metered_rx: Mutex<Option<mpsc::UnboundedReceiver<Option<SocketAddr>>>>,
    /// This side's router mapping of the current socket's port (a Mac with
    /// a mapper, [`portmap::install`]); replaced on a roam, dropped (and so
    /// deleted at the router) with the session.
    mapping: Mutex<Option<JoinHandle<()>>>,
    /// The mapped endpoint now offered, and the protocol that mapped it.
    own_mapped: Mutex<Option<(String, &'static str)>>,
    /// The mapped endpoint was among the endpoints already (STUN found the
    /// same address), so it stays when the mapping goes.
    mapped_was_offered: Mutex<bool>,
    /// The peer's endpoints it labeled mapped (the phone's `link_stat`).
    peer_mapped: Arc<Mutex<portmap::PeerMapped>>,
    relay: Option<RelayPlan>,
    relay_shared: Arc<RelayShared>,
    relay_watch: Mutex<Option<JoinHandle<()>>>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn registry() -> &'static Mutex<Vec<Weak<Session>>> {
    static SESSIONS: Mutex<Vec<Weak<Session>>> = Mutex::new(Vec::new());
    &SESSIONS
}

/// Every live session of this process.
/// Give every live session the second socket [`super::multipath`] wants
/// now, or take it away (WIP: the underlay side lands next).
/// Bring every live session's second socket in line with the interfaces,
/// the person's setting and the app's state ([`super::multipath`]).
pub(super) fn apply_multipath_to_live_sessions() {
    let interfaces = super::multipath::interfaces();
    let wanted = super::multipath::secondary_interface(
        &interfaces,
        super::multipath::cellular_assist(),
        super::app_backgrounded(),
    );
    let primary =
        interfaces.iter().find(|interface| interface.primary).map(|interface| interface.name.as_str());
    for session in live() {
        session.apply_multipath(wanted.as_ref(), primary);
    }
}

fn live() -> Vec<Arc<Session>> {
    let mut sessions = lock(registry());
    sessions.retain(|weak| weak.strong_count() > 0);
    sessions.iter().filter_map(Weak::upgrade).filter(|s| !s.closed.load(Ordering::Relaxed)).collect()
}

fn find(session_id: &str, dialer: bool) -> Option<Arc<Session>> {
    live().into_iter().find(|s| s.session_id == session_id && s.dialer == dialer)
}

impl Session {
    pub(super) fn register(parts: SessionParts) -> Arc<Self> {
        let turn_dead = parts.turn_dead;
        let (inject, injected) = mpsc::unbounded_channel();
        let (resignal, resignals) = mpsc::unbounded_channel();
        let (metered, metered_rx) = mpsc::unbounded_channel();
        let session = Arc::new(Self {
            session_id: parts.session_id,
            peer: parts.peer,
            dialer: parts.dialer,
            peer_ip: parts.peer_ip,
            signaling: parts.signaling,
            net: parts.net,
            control: parts.control,
            reach: Mutex::new(Some(parts.reach)),
            options: parts.options,
            stun: Mutex::new(parts.stun),
            endpoints: Mutex::new(parts.endpoints),
            relayed: Mutex::new(parts.relayed),
            keeps_turn: AtomicBool::new(parts.keeps_turn),
            stream_only: AtomicBool::new(false),
            turn_monitor: Mutex::new(None),
            inject,
            injected: Mutex::new(Some(injected)),
            resignal,
            resignals: Mutex::new(Some(resignals)),
            follow: Mutex::new(None),
            announce: Mutex::new(None),
            control_task: Mutex::new(None),
            roaming: tokio::sync::Mutex::new(()),
            last_roam: Mutex::new(None),
            path_epoch: Arc::new(watch::channel(0).0),
            roams: std::sync::atomic::AtomicU64::new(0),
            closed: AtomicBool::new(false),
            route_to: parts.route_to,
            multipath: parts.peer_version >= super::multipath::MULTIPATH_VERSION,
            secondary: Mutex::new(None),
            metered: Mutex::new(Some(metered)),
            metered_rx: Mutex::new(Some(metered_rx)),
            mapping: Mutex::new(None),
            own_mapped: Mutex::new(None),
            mapped_was_offered: Mutex::new(false),
            peer_mapped: Arc::new(Mutex::new(portmap::PeerMapped::default())),
            relay: parts.relay,
            relay_shared: parts.relay_shared,
            relay_watch: Mutex::new(None),
        });
        lock(registry()).push(Arc::downgrade(&session));
        if session.relay.is_some() {
            let task = tokio::spawn(run_relay_watch(Arc::downgrade(&session)));
            *lock(&session.relay_watch) = Some(task);
        }
        if let Some(dead) = turn_dead {
            session.monitor_turn(dead);
        }
        let interfaces = super::multipath::interfaces();
        let wanted = super::multipath::secondary_interface(
            &interfaces,
            super::multipath::cellular_assist(),
            super::app_backgrounded(),
        );
        session.apply_multipath(wanted.as_ref(), None);
        session
    }

    /// Give the underlay a socket on `wanted` (none: drop it), or move the
    /// session onto it once its interface is the `primary` one.
    fn apply_multipath(&self, wanted: Option<&super::multipath::NetInterface>, primary: Option<&str>) {
        // The dialing side (the phone) takes the second socket; the answering
        // side copies to the phone's metered address instead.
        if !self.multipath || !self.dialer || self.closed.load(Ordering::Relaxed) {
            return;
        }
        let mut current = lock(&self.secondary);
        if current.is_some() && current.as_deref() == primary {
            tracing::debug!(interface = ?current, "the second interface is the primary one now");
            *current = None;
            let _ = self.control.send(Control::Promote);
            return;
        }
        let wanted_name = wanted.map(|interface| interface.name.as_str());
        if current.as_deref() == wanted_name {
            return;
        }
        let metered = lock(&self.metered).clone().unwrap_or_else(|| mpsc::unbounded_channel().0);
        let Some(interface) = wanted else {
            *current = None;
            let _ = self.control.send(Control::Secondary(None));
            let _ = metered.send(None);
            return;
        };
        match super::multipath::bind_udp_on(&interface.name) {
            Ok(socket) => {
                *current = Some(interface.name.clone());
                let _ = self.control.send(Control::Secondary(Some(super::multipath::SecondarySocket {
                    socket,
                    interface: interface.name.clone(),
                    stun: lock(&self.stun).clone(),
                    reflexive: metered,
                })));
            }
            Err(error) => {
                tracing::debug!(%error, interface = interface.name, "no socket on the second interface");
            }
        }
    }

    /// When the current TURN allocation's stream to its server dies, take a
    /// new allocation (retrying with backoff while the session lives).
    fn monitor_turn(self: &Arc<Self>, mut dead: watch::Receiver<bool>) {
        self.retry_turn("TURN stream lost; taking a new allocation", async move {
            dead.wait_for(|dead| *dead).await.is_ok()
        });
    }

    /// The dial asked for a TURN allocation and its server did not answer in
    /// time: take one now, with the same backoff. Until then the peer may have
    /// no route to this side at all (its plain UDP lost), and the tunnel's
    /// handshake retries would only run out the dial's timeout.
    pub(super) fn retry_missing_turn(self: &Arc<Self>) {
        self.retry_turn("no TURN allocation at dial; taking one", async { true });
    }

    /// Once `start` says so, take a new TURN allocation, retrying with backoff
    /// while the session lives.
    fn retry_turn(
        self: &Arc<Self>,
        why: &'static str,
        start: impl std::future::Future<Output = bool> + Send + 'static,
    ) {
        self.retry_turn_after(why, start, LateTurn::default());
    }

    /// [`Self::retry_turn`], also taking a grant from `late` (allocations
    /// that ran past their bound) as soon as one lands: a grant the server
    /// made seconds ago is not thrown away for a new allocation's round trips.
    fn retry_turn_after(
        self: &Arc<Self>,
        why: &'static str,
        start: impl std::future::Future<Output = bool> + Send + 'static,
        late: LateTurn,
    ) {
        let weak = Arc::downgrade(self);
        let since = self.roams.load(Ordering::Relaxed);
        let task = tokio::spawn(async move {
            if !start.await {
                return;
            }
            for wait in TURN_RETRIES {
                let landed = tokio::select! {
                    () = tokio::time::sleep(wait) => None,
                    Some(turn) = late.landed() => Some(turn),
                };
                let Some(session) = weak.upgrade() else { return };
                if session.closed.load(Ordering::Relaxed) {
                    return;
                }
                if let Some(turn) = landed {
                    tracing::info!(session = session.session_id, "a late TURN grant landed; taking it");
                    session.take_turn(since, turn).await;
                    return;
                }
                tracing::info!(session = session.session_id, "{why}");
                if session.replace_turn(since, &late).await {
                    return;
                }
            }
            if let Some(turn) = late.landed().await {
                let Some(session) = weak.upgrade() else { return };
                if !session.closed.load(Ordering::Relaxed) {
                    session.take_turn(since, turn).await;
                    return;
                }
            }
            tracing::info!("no new TURN allocation; the session goes on without TURN");
        });
        stop_monitor(lock(&self.turn_monitor).replace(task));
    }

    /// The options a new allocation is made with: over TCP or TLS only once
    /// this network showed it carries no WireGuard over UDP.
    fn allocation_options(&self) -> std::borrow::Cow<'_, DialOptions> {
        if self.stream_only.load(Ordering::Relaxed) {
            // `block_udp` here only skips TURN over UDP: these options reach
            // the allocation, not the tunnel's own sends.
            std::borrow::Cow::Owned(DialOptions { block_udp: true, ..self.options.clone() })
        } else {
            std::borrow::Cow::Borrowed(&self.options)
        }
    }

    /// Watch `path` for a tunnel that hears nothing from its peer for `after`
    /// while it has no route (from its start, or after a roam): UDP answers
    /// (STUN, TURN's own requests) yet nothing carries WireGuard over it, as
    /// behind a firewall that drops WireGuard. Take TURN over TLS then and
    /// tell the peer (through signaling too, which still works), and keep to
    /// TCP or TLS on this network. A side already on TURN over TLS, or with
    /// no TCP or TLS server to ask, does nothing.
    pub(super) fn escalate_when_silent(
        self: &Arc<Self>,
        mut path: watch::Receiver<LinkPath>,
        after: Duration,
    ) {
        if super::super::turn::turn_servers(&self.options.ice_servers).1.is_none() {
            return;
        }
        let weak = Arc::downgrade(self);
        let relay_shared = Arc::clone(&self.relay_shared);
        tokio::spawn(async move {
            loop {
                if path.wait_for(|path| *path == LinkPath::NoPath).await.is_err() {
                    return;
                }
                // The relay (#53163) waits while this side may still take TURN
                // over TLS: from now until a route comes, or the TLS allocation
                // below came up and had RELAY_AFTER to carry a handshake
                // (RelayClock::turn_window). TURN over TLS first, the relay only
                // when that fails too.
                let mut gather = relay_shared.gathering_turn();
                let route = tokio::time::timeout(after, path.wait_for(|path| *path != LinkPath::NoPath))
                    .await
                    .map(|changed| changed.is_ok());
                match route {
                    Ok(true) => continue,
                    Ok(false) => return,
                    Err(_) => {}
                }
                let Some(session) = weak.upgrade() else { return };
                if session.closed.load(Ordering::Relaxed) {
                    return;
                }
                match session.escalate(after).await {
                    Escalated::Allocated => gather.allocated(),
                    Escalated::NotNeeded | Escalated::Failed => {}
                    Escalated::Roaming => {
                        // A roam is under way: its own route (and its own
                        // allocation's window) gets the next look.
                        continue;
                    }
                }
                drop(gather);
                drop(session);
                // Armed again once a route came and went.
                if path.wait_for(|path| *path != LinkPath::NoPath).await.is_err() {
                    return;
                }
            }
        });
    }

    /// [`Self::escalate_when_silent`]'s step.
    async fn escalate(self: &Arc<Self>, after: Duration) -> Escalated {
        if !lock(&self.relayed).1.is_empty() {
            // Already on TURN over TCP or TLS.
            return Escalated::NotNeeded;
        }
        if self.roaming.try_lock().is_err() {
            return Escalated::Roaming;
        }
        tracing::info!(
            session = self.session_id,
            silent = ?after,
            "nothing from the peer over UDP although UDP answers (WireGuard dropped?): taking TURN over TLS"
        );
        self.options.timeline.mark("wg_silent_turn_tls");
        self.stream_only.store(true, Ordering::Relaxed);
        self.keeps_turn.store(true, Ordering::Relaxed);
        if self.replace_turn(self.roams.load(Ordering::Relaxed), &LateTurn::default()).await {
            Escalated::Allocated
        } else {
            self.retry_turn("no TURN over TLS for a silent tunnel; taking one", async { true });
            Escalated::Failed
        }
    }

    /// Take a new TURN allocation on the current network and tell the peer
    /// its address; `false` when none could be had. A grant landing in
    /// `late` meanwhile (from the roam numbered `since`) is taken instead.
    async fn replace_turn(self: &Arc<Self>, since: u64, late: &LateTurn) -> bool {
        // Allocate before taking the roam lock: a roam meanwhile must not wait
        // seconds for an allocation that belongs to the old network.
        let roams = self.roams.load(Ordering::Relaxed);
        let options = self.allocation_options();
        let (turn, roams) = tokio::select! {
            Some(turn) = late.landed() => (turn, since),
            turn = TurnCarrier::allocate_keeping(&options, late) => match turn {
                Some(turn) => (turn, roams),
                None => return false,
            },
        };
        self.take_turn(roams, turn).await
    }

    /// Install `turn`, allocated while the roam count was `roams`, and tell
    /// the peer its address. A later roam's network makes it stale: it is
    /// dropped (released).
    async fn take_turn(self: &Arc<Self>, roams: u64, turn: TurnCarrier) -> bool {
        let _one_at_a_time = self.roaming.lock().await;
        if self.roams.load(Ordering::Relaxed) != roams || self.closed.load(Ordering::Relaxed) {
            // A roam took its own allocation on the new network, or started
            // its own retry.
            return true;
        }
        if let Some(timeline) = lock(&self.last_roam).as_ref() {
            timeline.mark("turn_retry_allocated");
        }
        let Ok(net) = self.net() else { return true };
        let (old, _) = lock(&self.relayed).clone();
        let mut endpoints: Vec<String> =
            lock(&self.endpoints).iter().filter(|endpoint| !old.contains(endpoint)).cloned().collect();
        let (relayed, relayed_tls) = relayed_of(Some(&turn));
        endpoints.extend(relayed.iter().cloned());
        self.install_turn(turn, (relayed.clone(), relayed_tls.clone()));
        let _ = net.refresh().await;
        self.announce(endpoints, relayed, relayed_tls);
        true
    }

    /// The answer went out with this side's host endpoints only
    /// ([`answer_trickles`]): learn the reflexive address of the tunnel's
    /// socket now, take a TURN allocation if the network looks to drop UDP
    /// (as the answer's own gather would have), and announce the endpoints
    /// to the peer, inside the tunnel and through signaling. The same
    /// clock as the answer's gather ([`StunClock`]) bounds it.
    pub(super) fn gather_after_answer(self: &Arc<Self>, port: u16, timeline: Timeline) {
        let session = Arc::clone(self);
        tokio::spawn(async move { session.trickle(port, timeline).await });
    }

    async fn trickle(self: &Arc<Self>, port: u16, timeline: Timeline) {
        // This gather started with the tunnel's relay clock: the relay waits
        // for the TURN allocation it may take.
        let mut gather = self.relay_shared.gathering_turn();
        let roams = self.roams.load(Ordering::Relaxed);
        let stun = self.stun_servers().await;
        let asked = stun.len();
        let (reflexive_tx, mut reflexive_rx) = mpsc::unbounded_channel();
        if asked > 0 && self.control.send(Control::Gather { stun, reflexive: reflexive_tx }).is_err() {
            return;
        }
        let (stun_side, turn_side) = stun_turn_link();
        let reflexive = async {
            let mut clock = StunClock::new(asked > 0, Some(stun_side));
            let mut found: Vec<SocketAddr> = Vec::new();
            while found.len() < asked {
                let Some(address) = clock.next(reflexive_rx.recv()).await else { break };
                if !found.contains(&address) {
                    found.push(address);
                }
                clock.answered();
            }
            found
        };
        let late = LateTurn::default();
        let (reflexive, allocated) =
            tokio::join!(reflexive, turn_beside_keeping(&self.options, false, turn_side, Some(&late)));
        if let Some(refusal) = &allocated.refusal {
            tracing::warn!(%refusal, "this Mac's proxy refused TURN over TLS; a phone may not reach it");
        }
        let turn = allocated.carrier;
        let blocked = asked > 0 && reflexive.is_empty();
        // A STUN answer came after all: the early allocation is dropped
        // (released) unused.
        let turn = if blocked { turn } else { None };
        let turn_missed = missed_turn(blocked, turn.as_ref(), &self.options);
        let _one_at_a_time = self.roaming.lock().await;
        if self.roams.load(Ordering::Relaxed) != roams || self.closed.load(Ordering::Relaxed) {
            // A roam gathered on its own socket meanwhile.
            return;
        }
        let Ok(net) = self.net() else { return };
        if blocked {
            // As for an answer whose gather found UDP blocked: this Mac keeps
            // a TURN allocation through roams and dead streams.
            self.keeps_turn.store(true, Ordering::Relaxed);
        }
        let mut endpoints = lock(&self.endpoints).clone();
        let known = endpoints.len();
        for text in offered(reflexive.iter().copied(), &self.options) {
            if !endpoints.contains(&text) {
                endpoints.push(text);
            }
        }
        let (mut relayed, mut relayed_tls) = (Vec::new(), Vec::new());
        if let Some(turn) = turn {
            timeline.mark(if turn.transport.is_stream() { "turn_tls_allocated" } else { "turn_allocated" });
            endpoints.push(turn.relayed.to_string());
            (relayed, relayed_tls) = relayed_of(Some(&turn));
            self.install_turn(turn, (relayed.clone(), relayed_tls.clone()));
            let _ = net.refresh().await;
            gather.allocated();
        } else if turn_missed {
            self.retry_turn_after("no TURN allocation at answer; taking one", async { true }, late);
        }
        if endpoints.len() != known {
            self.announce(endpoints, relayed, relayed_tls);
        }
        timeline.mark("endpoints_trickled");
        tracing::debug!(session = self.session_id, port, timings = %timeline.summary(), "WireGuard answer gathered");
    }

    /// Hand `turn` to the underlay and watch its stream.
    fn install_turn(self: &Arc<Self>, turn: TurnCarrier, relayed: (Vec<String>, Vec<String>)) {
        // UDP too: its allocation dies when its server stops answering
        // (`TurnCarrier::check_server`).
        let dead = Some(turn.dead());
        *lock(&self.relayed) = relayed;
        if self.control.send(Control::Turn(turn)).is_err() {
            return;
        }
        match dead {
            Some(dead) => self.monitor_turn(dead),
            None => stop_monitor(lock(&self.turn_monitor).take()),
        }
    }

    /// Counts this session's network changes: its own roams and the peer's
    /// endpoint announcements.
    pub(super) fn path_changes(&self) -> watch::Receiver<u64> {
        self.path_epoch.subscribe()
    }

    pub(super) fn net(&self) -> Result<Arc<WgNet>, DialError> {
        running(&self.net)
    }

    fn signaling(&self) -> SignalingClient {
        lock(&self.signaling).clone()
    }

    /// The signaling socket this session follows now.
    pub(super) fn signaling_client(&self) -> SignalingClient {
        self.signaling()
    }

    pub(super) fn id(&self) -> &str {
        &self.session_id
    }

    /// Watch `events` for the peer's `bye`, replacing the subscription of
    /// an earlier signaling socket.
    pub(super) fn follow(&self, mut events: mpsc::UnboundedReceiver<SessionEvent>) {
        let net = Arc::clone(&self.net);
        let inject = self.inject.clone();
        let relay_shared = Arc::clone(&self.relay_shared);
        let task = tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Some(SessionEvent::Signal(SignalEnvelope {
                        payload:
                            SignalPayload::WgEndpoints {
                                generation,
                                endpoints,
                                relayed,
                                relayed_tls,
                                mapped,
                                mapped_by,
                            },
                        ..
                    })) => {
                        let _ = inject.send(RoamMessage::Endpoints {
                            generation,
                            endpoints,
                            relayed,
                            relayed_tls,
                            mapped,
                            mapped_by,
                        });
                    }
                    Some(SessionEvent::Signal(SignalEnvelope {
                        payload: SignalPayload::WgRelay {}, ..
                    })) => {
                        relay_shared.ask();
                    }
                    Some(SessionEvent::Signal(envelope)) => {
                        if matches!(envelope.payload, SignalPayload::Bye { .. }) {
                            lock(&net).take();
                            return;
                        }
                    }
                    // Direct UDP outlives a signaling outage; `rehome`
                    // follows the next socket.
                    Some(SessionEvent::Disconnected) | None => return,
                }
            }
        });
        if let Some(old) = lock(&self.follow).replace(task) {
            old.abort();
        }
    }

    /// Listen for the peer's endpoint announcements and send ours.
    pub(super) async fn start_control(&self, net: &WgNet) {
        let socket = match net.bind_datagram(ROAM_PORT).await {
            Ok(socket) => socket,
            Err(error) => {
                tracing::debug!(%error, "no roaming port; this session cannot announce endpoints");
                return;
            }
        };
        let (announce_tx, announce_rx) = mpsc::unbounded_channel();
        let peer = SocketAddr::new(IpAddr::V4(self.peer_ip), ROAM_PORT);
        // Taken once; a second start (never done today) gets closed ones.
        let reach = lock(&self.reach).take().unwrap_or_else(|| mpsc::unbounded_channel().1);
        let injected = lock(&self.injected).take().unwrap_or_else(|| mpsc::unbounded_channel().1);
        let resignal = lock(&self.resignals).take().unwrap_or_else(|| mpsc::unbounded_channel().1);
        let metered = lock(&self.metered_rx).take().unwrap_or_else(|| mpsc::unbounded_channel().1);
        let task = tokio::spawn(run_control(
            socket,
            peer,
            self.control.clone(),
            Arc::clone(&self.net),
            ControlChannels {
                announce: announce_rx,
                reach,
                injected,
                resignal,
                metered,
                peer_mapped: Arc::clone(&self.peer_mapped),
                signal: SignalTarget {
                    dialer: self.dialer,
                    signaling: Arc::clone(&self.signaling),
                    peer: self.peer.clone(),
                    session_id: self.session_id.clone(),
                },
            },
            Arc::clone(&self.path_epoch),
        ));
        *lock(&self.announce) = Some(announce_tx);
        if let Some(old) = lock(&self.control_task).replace(task) {
            old.abort();
        }
    }

    /// End the session: stop its tasks and tell the peer.
    pub(super) fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        if let Some(task) = lock(&self.follow).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.control_task).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.turn_monitor).take() {
            task.abort();
        }
        // Dropping the mapping deletes it at the router.
        if let Some(task) = lock(&self.mapping).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.relay_watch).take() {
            task.abort();
        }
        let signaling = self.signaling();
        // Tell the peer, so its tunnel stops too.
        if lock(&self.net).take().is_some() {
            let _ = signaling.send_signal(
                &self.peer,
                &self.session_id,
                SignalPayload::Bye { reason: "closed".into() },
            );
        }
        signaling.unsubscribe(&self.session_id);
    }

    /// Tell the peer this side's endpoints (an empty list: unchanged, but
    /// the network changed, so the peer resends what it sent lately).
    /// `relayed`: which of `endpoints` are this side's TURN relayed
    /// addresses; `relayed_tls`: which of those ride TCP or TLS.
    /// The mapped endpoint (if any, and still among `endpoints`) is labeled
    /// so.
    /// Announce this side's endpoints again as they stand (after a relay
    /// join), even when none is new.
    async fn reannounce(&self) {
        let _one_at_a_time = self.roaming.lock().await;
        let endpoints = lock(&self.endpoints).clone();
        if endpoints.is_empty() || self.closed.load(Ordering::Relaxed) {
            return;
        }
        let (relayed, relayed_tls) = lock(&self.relayed).clone();
        tracing::debug!(
            session = self.session_id,
            count = endpoints.len(),
            "endpoints go through cmux's relay"
        );
        self.announce(endpoints, relayed, relayed_tls);
    }

    fn announce(&self, endpoints: Vec<String>, relayed: Vec<String>, relayed_tls: Vec<String>) {
        if !endpoints.is_empty() {
            lock(&self.endpoints).clone_from(&endpoints);
        }
        let (mapped, mapped_by) = match lock(&self.own_mapped).as_ref() {
            Some((address, protocol)) if endpoints.contains(address) => {
                (vec![address.clone()], Some((*protocol).to_owned()))
            }
            _ => (Vec::new(), None),
        };
        if let Some(tx) = lock(&self.announce).as_ref() {
            let _ = tx.send(Announcement { endpoints, relayed, relayed_tls, mapped, mapped_by });
        }
    }

    /// Ask this process's mapper ([`portmap::install`], a Mac host) to map
    /// `port`, the session socket's, in the background, and offer the
    /// mapped address to the peer once (and each time) the router gives
    /// one. Nothing waits for it. A roam replaces it with its new socket's.
    pub(super) fn map_port(self: &Arc<Self>, port: u16) {
        if self.dialer || no_plain_udp(&self.options) {
            return;
        }
        let Some(mapper) = portmap::mapper() else { return };
        let weak = Arc::downgrade(self);
        let roams = self.roams.load(Ordering::Relaxed);
        let task = tokio::spawn(async move {
            let Some(mapping) = mapper.map(port).await else {
                tracing::debug!(port, "no port mapping on this network");
                return;
            };
            let portmap::PortMapping { protocol, mut external, lease: _lease } = mapping;
            loop {
                let address = *external.borrow_and_update();
                let Some(session) = weak.upgrade() else { return };
                if !session.offer_mapped(roams, address.map(|address| (address, protocol))).await {
                    return;
                }
                drop(session);
                if external.changed().await.is_err() {
                    // The mapper gave up on it: stop offering it.
                    if let Some(session) = weak.upgrade() {
                        session.offer_mapped(roams, None).await;
                    }
                    return;
                }
            }
        });
        if let Some(old) = lock(&self.mapping).replace(task) {
            old.abort();
        }
    }

    /// Offer `mapped` (or stop offering the old mapped endpoint) to the peer,
    /// unless the session roamed since `roams` (a new socket, a new mapping)
    /// or closed: then `false`.
    async fn offer_mapped(&self, roams: u64, mapped: Option<(SocketAddr, &'static str)>) -> bool {
        let _one_at_a_time = self.roaming.lock().await;
        if self.roams.load(Ordering::Relaxed) != roams || self.closed.load(Ordering::Relaxed) {
            return false;
        }
        let mapped = mapped.map(|(address, protocol)| (address.to_string(), protocol));
        let old = std::mem::replace(&mut *lock(&self.own_mapped), mapped.clone());
        if old == mapped {
            return true;
        }
        let mut endpoints = lock(&self.endpoints).clone();
        if let Some((old, _)) = &old
            && !*lock(&self.mapped_was_offered)
        {
            // Only the mapping offered it (not STUN as well).
            endpoints.retain(|endpoint| endpoint != old);
        }
        if let Some((address, protocol)) = &mapped {
            tracing::info!(session = self.session_id, %address, protocol, "offering the router's mapped endpoint");
            // A NAT that keeps the port maps to the reflexive address STUN found.
            *lock(&self.mapped_was_offered) = endpoints.contains(address);
            if !endpoints.contains(address) {
                endpoints.push(address.clone());
            }
        }
        let (relayed, relayed_tls) = lock(&self.relayed).clone();
        self.announce(endpoints, relayed, relayed_tls);
        true
    }

    async fn stun_servers(&self) -> Vec<SocketAddr> {
        let cached = lock(&self.stun).clone();
        if !cached.is_empty() || no_plain_udp(&self.options) {
            return cached;
        }
        let resolved = resolve_stun(&self.options).await;
        lock(&self.stun).clone_from(&resolved);
        resolved
    }

    /// Move the session onto the network the device has now.
    async fn roam(self: &Arc<Self>) -> Timeline {
        let _one_at_a_time = self.roaming.lock().await;
        self.roams.fetch_add(1, Ordering::Relaxed);
        // A new network: it may carry WireGuard over UDP again.
        self.stream_only.store(false, Ordering::Relaxed);
        let timeline = Timeline::new();
        timeline.mark("network_changed");
        *lock(&self.last_roam) = Some(timeline.clone());
        // The old socket's mapping is of no use on the new socket (or network).
        if let Some(task) = lock(&self.mapping).take() {
            task.abort();
        }
        if let Some((old, _)) = lock(&self.own_mapped).take()
            && !std::mem::take(&mut *lock(&self.mapped_was_offered))
        {
            // Only the mapping offered it (not STUN as well).
            lock(&self.endpoints).retain(|endpoint| *endpoint != old);
        }
        *lock(&self.mapped_was_offered) = false;
        let Ok(net) = self.net() else { return timeline };
        let socket = match bind_udp() {
            Ok(socket) => socket,
            Err(error) => {
                // No network yet (airplane mode): the next change roams.
                tracing::debug!(%error, "no socket for the roam");
                return timeline;
            }
        };
        let port = socket.local_addr().map(|addr| addr.port()).unwrap_or_default();
        let stun = self.stun_servers().await;
        let asked = stun.len();
        let (reflexive_tx, mut reflexive_rx) = mpsc::unbounded_channel();
        let rebind = Control::Rebind { socket, stun, reflexive: reflexive_tx, timeline: timeline.clone() };
        if self.control.send(rebind).is_err() {
            return timeline;
        }
        // The underlay applies the rebind before it sends this.
        if net.refresh().await.is_err() {
            return timeline;
        }
        timeline.mark("roam_reasserted");
        self.relay_shared.roamed();
        // The relay waits for the TURN allocation this roam may take.
        let mut gather = self.relay_shared.gathering_turn();
        self.path_epoch.send_modify(|epoch| *epoch += 1);
        let mut endpoints = host_endpoints(port, &self.options);
        self.announce(offered(endpoints.iter().copied(), &self.options), Vec::new(), Vec::new());
        // On the transport the new network allows: UDP, else TLS. The
        // allocation is installed and announced the moment it comes back,
        // not after the STUN wait below: on a network whose STUN is silent
        // (its one request lost) that wait is 1.5 s with no path at all.
        let mut keeps_turn = self.keeps_turn.load(Ordering::Relaxed);
        let host = endpoints.clone();
        // Allocations that run past their bound stay here: a miss below
        // takes the first grant that lands instead of asking again.
        let late = LateTurn::default();
        let turn = async {
            let turn =
                if keeps_turn { TurnCarrier::allocate_keeping(&self.options, &late).await } else { None };
            match turn {
                Some(turn) => Some(self.take_roam_turn(turn, &net, &host, &timeline).await),
                None => None,
            }
        };
        let reflexive = async {
            let mut deadline = Instant::now() + STUN_WAIT;
            let mut found = Vec::new();
            while found.len() < asked {
                match tokio::time::timeout_at(deadline, reflexive_rx.recv()).await {
                    Ok(Some(address)) => {
                        found.push(address);
                        // One answered: a silent server (port 53 on a cellular
                        // network) gets only a short grace (STUN_GRACE).
                        deadline = deadline.min(Instant::now() + STUN_GRACE);
                    }
                    _ => break,
                }
            }
            found
        };
        let (mut taken, reflexive) = tokio::join!(turn, reflexive);
        if taken.is_none() && !keeps_turn && asked > 0 && reflexive.is_empty() {
            // A Mac roamed onto a network that answers no STUN (it drops
            // UDP): from now on it keeps a TURN allocation, and keeps asking
            // below when this one misses.
            keeps_turn = true;
            self.keeps_turn.store(true, Ordering::Relaxed);
            if let Some(turn) = TurnCarrier::allocate_keeping(&self.options, &late).await {
                taken = Some(self.take_roam_turn(turn, &net, &host, &timeline).await);
            }
        }
        let mut known = endpoints.len();
        for address in reflexive {
            if !endpoints.contains(&address) {
                endpoints.push(address);
            }
        }
        let (mut relayed, mut relayed_tls) = (Vec::new(), Vec::new());
        if let Some((address, taken_relayed, taken_relayed_tls)) = taken {
            // The host endpoints and this went out already: announce again
            // only when STUN added reflexive ones.
            if endpoints.len() == known {
                known += 1;
            }
            endpoints.push(address);
            (relayed, relayed_tls) = (taken_relayed, taken_relayed_tls);
            gather.allocated();
        } else {
            // The old network's relayed address is dead: stop offering it
            // (a relay-only roam above announced nothing in its place).
            let (old, _) = std::mem::take(&mut *lock(&self.relayed));
            lock(&self.endpoints).retain(|endpoint| !old.contains(endpoint));
            if missed_turn(keeps_turn, None, &self.options) {
                // The new network's TURN server did not answer in time: keep
                // asking (this also replaces a retry started on the old one).
                self.retry_turn_after("roam took no TURN allocation; taking one", async { true }, late);
            }
        }
        if endpoints.len() != known {
            self.announce(offered(endpoints, &self.options), relayed, relayed_tls);
        }
        timeline.mark("roam_gathered");
        tracing::info!(session = self.session_id, timings = %timeline.summary(), "WireGuard roamed");
        // After the roam counted itself: the mapping belongs to this socket.
        self.map_port(port);
        timeline
    }

    /// Install a roam's TURN allocation and announce its relayed address
    /// beside `host` (the roam's host endpoints) at once. Returns the
    /// relayed address and which announced addresses are relayed.
    async fn take_roam_turn(
        self: &Arc<Self>,
        turn: TurnCarrier,
        net: &WgNet,
        host: &[SocketAddr],
        timeline: &Timeline,
    ) -> (SocketAddr, Vec<String>, Vec<String>) {
        timeline.mark(if turn.transport.is_stream() {
            "roam_turn_tls_allocated"
        } else {
            "roam_turn_allocated"
        });
        let address = turn.relayed;
        let (relayed, relayed_tls) = relayed_of(Some(&turn));
        self.install_turn(turn, (relayed.clone(), relayed_tls.clone()));
        let _ = net.refresh().await;
        let mut endpoints = host.to_vec();
        endpoints.push(address);
        self.announce(offered(endpoints, &self.options), relayed.clone(), relayed_tls.clone());
        (address, relayed, relayed_tls)
    }

    /// Our route to the peer went quiet: send the peer our latest endpoint
    /// announcement again through signaling (generation 0 with none yet).
    /// Already applied there, it is only acknowledged, inside the tunnel,
    /// which is the point: the peer sends on its route to us, and that
    /// starts its silence watch (and, on its TURN allocation, the server
    /// check) without waiting for its next probe.
    pub(super) fn nudge_peer(&self) {
        let _ = self.resignal.send(true);
    }

    fn rehome_onto(&self, client: &SignalingClient) {
        let old = std::mem::replace(&mut *lock(&self.signaling), client.clone());
        old.unsubscribe(&self.session_id);
        self.follow(client.subscribe(&self.session_id));
        // An announcement sent while the old socket was dead is sent again.
        let _ = self.resignal.send(false);
        tracing::debug!(session = self.session_id, "WireGuard session moved to a new signaling socket");
    }
}

async fn send_message(socket: &WgDatagramSocket, peer: SocketAddr, message: &RoamMessage) {
    let bytes = serde_json::to_vec(message).expect("roam message serializes");
    // An endpoint announcement keeps Ultra Mode's repair: it is what a roam
    // on a lossy network waits for. `reach`, `ack` and `metered` are
    // repeated by their senders and nothing answers them, so each goes as
    // one liveness datagram: no floor parity (which cost a lone `reach` as
    // much again, 12 a minute on an idle link) and no silence watch armed.
    let result = match message {
        RoamMessage::Endpoints { .. } => socket.send_to(&bytes, peer, Priority::Interactive).await,
        RoamMessage::Ack { .. } | RoamMessage::Metered { .. } | RoamMessage::Reach { .. } => {
            socket.send_liveness(&bytes, peer, true).await
        }
    };
    if let Err(error) = result {
        tracing::debug!(%error, "roam message not sent");
    }
}

/// Stop a TURN monitor task, unless it is the one running this (a monitor
/// that installs the new allocation replaces its own handle).
fn stop_monitor(task: Option<JoinHandle<()>>) {
    if let Some(task) = task
        && tokio::task::try_id() != Some(task.id())
    {
        task.abort();
    }
}

/// Where this side's announcements also go through signaling.
struct SignalTarget {
    dialer: bool,
    signaling: Arc<Mutex<SignalingClient>>,
    peer: String,
    session_id: String,
}

impl SignalTarget {
    fn send(&self, message: &RoamMessage) {
        let RoamMessage::Endpoints { generation, endpoints, relayed, relayed_tls, mapped, mapped_by } =
            message.clone()
        else {
            return;
        };
        let client = lock(&self.signaling).clone();
        let payload =
            SignalPayload::WgEndpoints { generation, endpoints, relayed, relayed_tls, mapped, mapped_by };
        if let Err(error) = client.send_signal(&self.peer, &self.session_id, payload) {
            tracing::debug!(%error, "endpoint announcement not sent through signaling");
        }
    }
}

/// What the control task is asked to send, and what reaches it from
/// signaling.
struct ControlChannels {
    announce: mpsc::UnboundedReceiver<Announcement>,
    reach: mpsc::UnboundedReceiver<(SocketAddr, Carrier)>,
    injected: mpsc::UnboundedReceiver<RoamMessage>,
    resignal: mpsc::UnboundedReceiver<bool>,
    /// The reflexive address of this side's second socket (`None`: gone).
    metered: mpsc::UnboundedReceiver<Option<SocketAddr>>,
    /// Where the peer's mapped endpoints are kept (for `link_stat`).
    peer_mapped: Arc<Mutex<portmap::PeerMapped>>,
    signal: SignalTarget,
}

/// The roaming messages of one session: announce this side's endpoints
/// until the peer acknowledges them, apply the peer's, and carry `reach`
/// both ways.
async fn run_control(
    mut socket: WgDatagramSocket,
    peer: SocketAddr,
    control: mpsc::UnboundedSender<Control>,
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    channels: ControlChannels,
    path_epoch: Arc<watch::Sender<u64>>,
) {
    let ControlChannels {
        mut announce,
        mut reach,
        mut injected,
        mut resignal,
        mut metered,
        peer_mapped,
        signal,
    } = channels;
    // This side's metered addresses, sent again every METERED_RESEND while
    // there are any (the message has no acknowledgment).
    let mut own_metered: Vec<String> = Vec::new();
    let mut metered_at: Option<Instant> = None;
    let mut cleared_left = 0usize;
    // The latest announcement, for a resend through a new signaling socket.
    let mut latest: Option<RoamMessage> = None;
    let mut generation = 0u64;
    let mut pending: Option<RoamMessage> = None;
    let mut resends = 0usize;
    let mut resend_at: Option<Instant> = None;
    let mut applied = 0u64;
    // The first endpoint the peer last announced (its new socket's host
    // address, or its TURN address when relay only). A new one is a network
    // change for the media lane; the same one again is not: a roam announces
    // twice (host endpoints at once, then with the reflexive ones), and an
    // empty list follows a mere signaling-socket move.
    let mut peer_first: Option<String> = None;
    loop {
        let resend = async {
            match resend_at {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        let metered_resend = async {
            match metered_at {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            Some(address) = metered.recv() => {
                own_metered = address.map(|addr| vec![addr.to_string()]).unwrap_or_default();
                cleared_left = METERED_CLEARED_RESENDS;
                send_message(&socket, peer, &RoamMessage::Metered { addresses: own_metered.clone() }).await;
                metered_at = Some(Instant::now() + METERED_RESEND);
            }
            () = metered_resend => {
                send_message(&socket, peer, &RoamMessage::Metered { addresses: own_metered.clone() }).await;
                // An empty list goes a few times more, then stops.
                if own_metered.is_empty() {
                    cleared_left = cleared_left.saturating_sub(1);
                }
                metered_at = (!own_metered.is_empty() || cleared_left > 0).then(|| Instant::now() + METERED_RESEND);
            }
            Some((from, carrier)) = reach.recv() => {
                let via = match carrier {
                    Carrier::Turn => "turn",
                    Carrier::Relay => "relay",
                    Carrier::Udp => "udp",
                };
                let message = RoamMessage::Reach { from: Some(from.to_string()), via: Some(via.to_owned()) };
                send_message(&socket, peer, &message).await;
            }
            endpoints = announce.recv() => {
                let Some(Announcement { mut endpoints, relayed, relayed_tls, mapped, mapped_by }) = endpoints
                else {
                    return;
                };
                // Past the limit, drop plain endpoints from the end first: a long
                // list never loses the relayed or mapped ones, and the order (the
                // first endpoint tells the peer the network changed) stays.
                while endpoints.len() > MAX_ENDPOINTS {
                    match endpoints.iter().rposition(|text| !relayed.contains(text) && !mapped.contains(text)) {
                        Some(index) => {
                            endpoints.remove(index);
                        }
                        None => endpoints.truncate(MAX_ENDPOINTS),
                    }
                }
                generation += 1;
                let relayed: Vec<String> =
                    relayed.into_iter().filter(|text| endpoints.contains(text)).take(MAX_RELAYED).collect();
                let relayed_tls = relayed_tls.into_iter().filter(|text| relayed.contains(text)).collect();
                let mapped: Vec<String> =
                    mapped.into_iter().filter(|text| endpoints.contains(text)).take(MAX_MAPPED).collect();
                let mapped_by = mapped_by.filter(|_| !mapped.is_empty());
                let message =
                    RoamMessage::Endpoints { generation, endpoints, relayed, relayed_tls, mapped, mapped_by };
                send_message(&socket, peer, &message).await;
                // Also through signaling: the peer may not receive anything
                // from this side's new address yet.
                signal.send(&message);
                latest = Some(message.clone());
                pending = Some(message);
                resends = 0;
                resend_at = Some(Instant::now() + ANNOUNCE_RESENDS[0]);
            }
            () = resend => {
                if let Some(message) = &pending {
                    send_message(&socket, peer, message).await;
                }
                resends += 1;
                resend_at = ANNOUNCE_RESENDS.get(resends).map(|wait| Instant::now() + *wait);
                if resend_at.is_none() {
                    pending = None;
                }
            }
            Some(nudge) = resignal.recv() => {
                match &latest {
                    Some(message) => signal.send(message),
                    // Nothing announced yet: generation 0, which every peer
                    // has applied, so it only acknowledges it.
                    None if nudge => signal.send(&RoamMessage::Endpoints {
                        generation: 0,
                        endpoints: Vec::new(),
                        relayed: Vec::new(),
                        relayed_tls: Vec::new(),
                        mapped: Vec::new(),
                        mapped_by: None,
                    }),
                    None => {}
                }
            }
            received = async {
                tokio::select! {
                    Some(message) = injected.recv() => Some(Ok(message)),
                    received = socket.recv_from() => {
                        let (payload, from) = received?;
                        Some(if from.ip() != peer.ip() {
                            Err("a roam message from another address".to_owned())
                        } else {
                            serde_json::from_slice::<RoamMessage>(&payload).map_err(|error| error.to_string())
                        })
                    }
                }
            } => {
                let Some(received) = received else {
                    tracing::debug!(dialer = signal.dialer, "roam control ends: the tunnel is gone");
                    return;
                };
                match received {
                    Ok(RoamMessage::Reach { from, via }) => {
                        let from = from.and_then(|text| text.parse().ok());
                        let via_turn = via.as_deref() == Some("turn");
                        if control.send(Control::Reached { from, via_turn }).is_err() {
                            return;
                        }
                    }
                    Ok(RoamMessage::Endpoints {
                        generation: theirs,
                        endpoints,
                        relayed,
                        relayed_tls,
                        mapped,
                        mapped_by,
                    }) => {
                        send_message(&socket, peer, &RoamMessage::Ack { generation: theirs }).await;
                        if theirs <= applied {
                            continue;
                        }
                        applied = theirs;
                        let endpoints: Vec<String> = endpoints
                            .into_iter()
                            .filter(|text| text.parse::<SocketAddr>().is_ok())
                            .take(MAX_ENDPOINTS)
                            .collect();
                        let moved = endpoints.first().is_some_and(|first| peer_first.as_ref() != Some(first));
                        if moved {
                            peer_first = endpoints.first().cloned();
                        }
                        let relayed: Vec<String> = relayed.into_iter().filter(|text| endpoints.contains(text)).take(MAX_RELAYED).collect();
                        let relayed_tls = relayed_tls.into_iter().filter(|text| relayed.contains(text)).collect();
                        if !endpoints.is_empty() {
                            *lock(&peer_mapped) = peer_mapped_of(&endpoints, &mapped, mapped_by.as_deref());
                        }
                        if control.send(Control::PeerEndpoints { endpoints, relayed, relayed_tls }).is_err() {
                            return;
                        }
                        if moved {
                            // The peer's network changed.
                            path_epoch.send_modify(|epoch| *epoch += 1);
                        }
                        // Send at once, so the spray opens this side's NAT
                        // toward the peer's new address (even while parked:
                        // the peer that says it moved is awake).
                        let current = lock(&net).clone();
                        if let Some(net) = current {
                            let _ = net.reach_moved_peer().await;
                        }
                    }
                    Ok(RoamMessage::Metered { addresses }) => {
                        let addresses: Vec<String> = addresses
                            .into_iter()
                            .filter(|text| text.parse::<SocketAddr>().is_ok())
                            .take(MAX_METERED)
                            .collect();
                        if control.send(Control::PeerMetered(addresses)).is_err() {
                            return;
                        }
                    }
                    Ok(RoamMessage::Ack { generation: acked }) => {
                        if matches!(&pending, Some(RoamMessage::Endpoints { generation, .. }) if *generation <= acked) {
                            pending = None;
                            resend_at = None;
                        }
                    }
                    Err(error) => tracing::debug!(%error, "unreadable roam message"),
                }
            }
        }
    }
}

/// The device's network changed (or came back): move every live WireGuard
/// session onto it. Returns each session's roam marks (`network_changed`,
/// `roam_reasserted`, `roam_first_packet`, `roam_direct` or `roam_turn`,
/// `roam_turn_allocated`, `roam_gathered`), which keep filling in after
/// this returns.
pub async fn network_changed() -> Vec<(String, Timeline)> {
    // The new network's proxy (and whether it inspects TLS) is asked afresh.
    crate::egress::network_changed();
    let sessions = live();
    let roams =
        sessions.iter().map(|session| async move { (session.session_id.clone(), session.roam().await) });
    futures_util::future::join_all(roams).await
}

/// Where each live session's plain UDP goes now (sessions on this side's
/// own TURN allocation, or with no route yet, name none). The Mac's network
/// watch reads it to tell a change on an interface a session uses from one
/// on an interface none does (`cmux-mobile-host` netwatch).
pub fn route_destinations() -> Vec<SocketAddr> {
    live().iter().filter_map(|session| *session.route_to.borrow()).collect()
}

/// Move the sessions on `client`'s device that run on another (dead or
/// replaced) signaling socket onto `client`. Returns how many moved.
pub fn rehome(client: &SignalingClient) -> usize {
    let mut moved = 0;
    for session in live() {
        let current = session.signaling();
        // A local hub socket and a Worker socket of one device are two
        // routes, not a replacement: each keeps its own sessions.
        if current.device_id() == client.device_id()
            && !current.same_socket(client)
            && current.is_local() == client.is_local()
        {
            session.rehome_onto(client);
            moved += 1;
        }
    }
    moved
}

/// The marks of session `session_id`'s latest roam.
pub fn roam_timeline(session_id: &str) -> Option<Timeline> {
    // Both sides of a session run in one process in tests: the side that roamed.
    live().into_iter().filter(|s| s.session_id == session_id).find_map(|s| lock(&s.last_roam).clone())
}

/// The phone is back from the background with a parked link: move its
/// session onto a fresh socket, as a network change would. iOS may have
/// reclaimed the old socket while the app was suspended, and the carrier's
/// NAT has likely dropped its mapping. The reassertion (a keepalive on a
/// session under 120 s old, else one handshake initiation) goes out at once;
/// the rest of the roam (STUN, a TURN allocation) fills in after.
pub fn resume_session(session_id: &str) {
    if let Some(session) = find(session_id, true) {
        tokio::spawn(async move {
            session.roam().await;
        });
    }
}

/// Test support: roam one side of one session (both sides of a test run in
/// one process).
#[doc(hidden)]
pub async fn roam_session(session_id: &str, dialer: bool) -> Option<Timeline> {
    let session = find(session_id, dialer)?;
    Some(session.roam().await)
}

/// How a dialer's session uses its peer's router mapping now: the protocol
/// that mapped the peer's offered endpoint, and whether the plain-UDP route
/// goes to it (`link_stat` `portmap`). `None`: no such session, or the peer
/// offered no mapped endpoint.
pub fn portmap_use(session_id: &str) -> Option<portmap::PortmapUse> {
    let session = find(session_id, true)?;
    let route = *session.route_to.borrow();
    lock(&session.peer_mapped).use_by(route)
}

/// Test support: the endpoints one side of `session_id` last told its peer.
#[doc(hidden)]
pub fn session_endpoints(session_id: &str, dialer: bool) -> Option<Vec<String>> {
    find(session_id, dialer).map(|session| lock(&session.endpoints).clone())
}

/// Debug and tests: the current network of one side of `session_id` (or of
/// every session when `None`) goes away without a roam: nothing its socket
/// or TURN allocation sends arrives, and nothing reaches it. Returns how
/// many sessions it hit.
#[doc(hidden)]
pub fn simulate_network_loss(session_id: Option<&str>, dialer: bool) -> usize {
    let mut hit = 0;
    for session in live() {
        if session.dialer == dialer && session_id.is_none_or(|id| id == session.session_id) {
            let _ = session.control.send(Control::Blackhole);
            hit += 1;
        }
    }
    hit
}

/// Debug and tests: one side's network (of `session_id`, or of every
/// session) goes dark or comes back on the same socket and addresses, with
/// no OS network event ([`Control::Dark`]). Returns how many sessions it hit.
#[doc(hidden)]
pub fn simulate_blackout(session_id: Option<&str>, dialer: bool, dark: bool) -> usize {
    let mut hit = 0;
    for session in live() {
        if session.dialer == dialer && session_id.is_none_or(|id| id == session.session_id) {
            let _ = session.control.send(Control::Dark(dark));
            hit += 1;
        }
    }
    hit
}

/// Debug and tests: the TCP or TLS stream of one side's TURN allocation
/// (of `session_id`, or of every session) dies, as when a middlebox resets
/// it. The session takes a new allocation. Returns how many sessions it hit.
#[doc(hidden)]
pub fn simulate_relay_loss(session_id: Option<&str>, dialer: bool) -> usize {
    live()
        .into_iter()
        .filter(|s| s.dialer == dialer && session_id.is_none_or(|id| s.session_id == id))
        .filter(|s| s.control.send(Control::KillRelay).is_ok())
        .count()
}

/// Whether a live session holds a relay socket now (tests and the debug
/// probes).
pub fn relay_held(session_id: &str, dialer: bool) -> Option<bool> {
    find(session_id, dialer).map(|s| s.relay_shared.held())
}

/// The relay-held send queue's socket for a live session (RFD 0142 R8): the
/// newest joined relay carrier's [`HoldPort`](super::super::relay::HoldPort),
/// as it changes (`None` before the first join). `None` without the session.
pub fn relay_hold_port(
    session_id: &str,
    dialer: bool,
) -> Option<watch::Receiver<Option<super::super::relay::HoldPort>>> {
    find(session_id, dialer).map(|s| s.relay_shared.hold_port.subscribe())
}

/// Join cmux's relay whenever this session needs it ([`RelayShared::due`]),
/// until the session ends. A side that joins on its own (not because the
/// peer asked or said it would) asks the peer to join too.
async fn run_relay_watch(session: Weak<Session>) {
    let Some(first) = session.upgrade() else { return };
    let mut join_now = first.relay.as_ref().is_some_and(|plan| plan.now);
    let shared = Arc::clone(&first.relay_shared);
    drop(first);
    let mut failures = 0usize;
    let started = Instant::now();
    let mut next_try = started;
    let mut peer_away_since: Option<Instant> = None;
    let mut asked_back: Option<Instant> = None;
    loop {
        if !join_now {
            tokio::select! {
                () = tokio::time::sleep(shared.poll_gap()) => {}
                () = shared.asked.notified() => {}
            }
        }
        let Some(session) = session.upgrade() else { return };
        if session.closed.load(Ordering::Relaxed) {
            return;
        }
        // A peer that left the relay while this side still needs it is asked back.
        if shared.peer_needed_back() {
            let since = *peer_away_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= RELAY_ASK_BACK
                && asked_back.is_none_or(|at| at.elapsed() >= RELAY_ASK_BACK * 2)
            {
                asked_back = Some(Instant::now());
                tracing::info!(session = session.session_id, "the peer left cmux's relay; asking it back");
                let _ = session.signaling().send_signal(
                    &session.peer,
                    &session.session_id,
                    SignalPayload::WgRelay {},
                );
            }
        } else {
            peer_away_since = None;
        }
        let reason = if join_now && !shared.held() {
            Some("one side has no other path")
        } else {
            shared.due(session.dialer)
        };
        // Once: a retry waits for `due` like any later join.
        join_now = false;
        let Some(reason) = reason else { continue };
        if Instant::now() < next_try {
            continue;
        }
        let Some(plan) = session.relay.clone() else { return };
        let asked = std::mem::take(&mut lock(&shared.state).asked);
        let decided = Instant::now();
        tracing::info!(session = session.session_id, reason, "WireGuard joins cmux's relay");
        let host = plan.endpoint.host();
        match join_or_take(&plan, &session.session_id, &session.peer).await {
            Ok(carrier) => {
                failures = 0;
                // The peer was heard while the join ran (a slow handshake, not a
                // blocked one): this side's own relay is not needed. A side that
                // was asked, or that has no other path, keeps it.
                // An asked join is dropped the same way once a route elsewhere is
                // confirmed both ways: the peer no longer needs it.
                if !plan.now && shared.heard_after(decided) && (!asked || shared.confirmed_elsewhere()) {
                    tracing::debug!(
                        session = session.session_id,
                        "the peer answered meanwhile; leaving cmux's relay unused"
                    );
                    shared.not_lost();
                    continue;
                }
                if lock(&shared.state).left.is_some_and(|left| left.elapsed() < RELAY_STICKY_WITHIN) {
                    shared.sticky.store(true, Ordering::Relaxed);
                }
                *lock(&shared.peer_online) = Some(carrier.peer_online_watch());
                shared.hold_port.send_replace(Some(carrier.hold_port()));
                if session.control.send(Control::Relay(carrier)).is_err() {
                    return;
                }
                shared.set_held(true);
                // Wake the tunnel so its handshake rides the relay: the dialer at once,
                // the answerer a random moment later and only if the dialer's did not
                // arrive meanwhile. Both sides often join in the same instant (their
                // watches run on the same clock since their tunnels started together),
                // and two handshake initiations that cross in lockstep each overwrite the
                // other side's pending one (boringtun keeps one handshake state), so
                // every response is refused and their fixed repeat schedule keeps them in
                // step until the dial times out.
                reassert_on_relay(&session, &shared).await;
                // Disco over the relay (ledger 13h): the peer may know none of
                // this side's direct endpoints (a signaling path that dropped
                // them, a peer that met this one on the relay), so they go to
                // it again through the tunnel. Its upgrade probes then find the
                // LAN path. The message is the roam announcement older peers
                // already take.
                session.reannounce().await;
                // The peer joins too unless it already does (it asked, or it said it
                // has no other path). A plan exists only when the peer offered the
                // relay, so `wg-relay` never reaches a build that does not know it.
                if !asked && !plan.now {
                    let _ = session.signaling().send_signal(
                        &session.peer,
                        &session.session_id,
                        SignalPayload::WgRelay {},
                    );
                }
            }
            Err(failure) => {
                tracing::info!(
                    session = session.session_id,
                    failure = failure.describe(),
                    "cmux relay join failed"
                );
                session.options.diagnosis.relay_failed(&failure, host);
                // The last way failed too: a dial still waiting ends, at once when it
                // had no other way, else once the others had their time.
                let give_up_at = if plan.now { started } else { started + RELAY_GIVE_UP_AFTER };
                if failure.is_final() {
                    let diagnosis = session.options.diagnosis.clone();
                    drop(session);
                    tokio::time::sleep_until(give_up_at).await;
                    diagnosis.give_up();
                    return;
                }
                if failures >= 1 && Instant::now() >= give_up_at {
                    session.options.diagnosis.give_up();
                }
                let wait = RELAY_RETRIES[failures.min(RELAY_RETRIES.len() - 1)];
                failures += 1;
                next_try = Instant::now() + wait;
                if asked {
                    lock(&shared.state).asked = true;
                }
            }
        }
    }
}

/// How long the answering side waits, at random within this range, before it
/// reasserts on a relay it just joined ([`reassert_on_relay`]).
const ANSWER_REASSERT_JITTER: std::ops::Range<u64> = 300..900;

/// Send a handshake (or keepalive) through the relay this side just joined.
async fn reassert_on_relay(session: &Arc<Session>, shared: &Arc<RelayShared>) {
    if !session.dialer {
        let mut bytes = [0u8; 8];
        getrandom::fill(&mut bytes).expect("operating system randomness");
        let span = ANSWER_REASSERT_JITTER.end - ANSWER_REASSERT_JITTER.start;
        let wait = Duration::from_millis(ANSWER_REASSERT_JITTER.start + u64::from_le_bytes(bytes) % span);
        let joined = Instant::now();
        tokio::time::sleep(wait).await;
        if shared.heard_after(joined) {
            return;
        }
    }
    if let Ok(net) = session.net() {
        let _ = net.refresh().await;
    }
}

pub fn simulate_turn_loss(session_id: Option<&str>, dialer: bool) -> usize {
    let mut hit = 0;
    for session in live() {
        if session.dialer == dialer && session_id.is_none_or(|id| id == session.session_id) {
            let _ = session.control.send(Control::KillTurn);
            hit += 1;
        }
    }
    hit
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An answer-side session with `endpoints`, no tunnel (`net` none), and
    /// its announcements collected.
    async fn offering(
        signaling: &crate::testing::FakeSignaling,
        endpoints: &[&str],
    ) -> (Arc<Session>, mpsc::UnboundedReceiver<Announcement>) {
        let client = SignalingClient::connect(&signaling.base_url, "user:alice", "team", "mac")
            .await
            .expect("signaling");
        let session = Session::register(SessionParts {
            session_id: uuid::Uuid::new_v4().to_string(),
            peer: "phone".into(),
            dialer: false,
            peer_ip: Ipv4Addr::new(10, 64, 0, 2),
            signaling: Arc::new(Mutex::new(client)),
            net: Arc::new(Mutex::new(None)),
            control: mpsc::unbounded_channel().0,
            reach: mpsc::unbounded_channel().1,
            options: DialOptions::default(),
            stun: Vec::new(),
            endpoints: endpoints.iter().map(|e| (*e).to_owned()).collect(),
            relayed: (Vec::new(), Vec::new()),
            keeps_turn: false,
            turn_dead: None,
            route_to: Arc::new(watch::channel(None).0),
            peer_version: super::super::WG_VERSION,
            relay: None,
            relay_shared: Arc::new(RelayShared::default()),
        });
        let (tx, rx) = mpsc::unbounded_channel();
        *lock(&session.announce) = Some(tx);
        (session, rx)
    }

    fn sent(rx: &mut mpsc::UnboundedReceiver<Announcement>) -> (Vec<String>, Vec<String>, Option<String>) {
        let a = rx.try_recv().expect("an announcement");
        (a.endpoints, a.mapped, a.mapped_by)
    }

    fn strings(all: &[&str]) -> Vec<String> {
        all.iter().map(|e| (*e).to_owned()).collect()
    }

    /// The mapped endpoint's lifecycle on the answer side: offered labeled,
    /// replaced when the router's address changes, withdrawn when the
    /// mapping lapses, kept when STUN found it too, and dropped by a roam,
    /// after which the old socket's mapping can no longer offer anything.
    #[tokio::test]
    async fn the_mapped_endpoint_is_offered_replaced_withdrawn_and_dropped_on_roam() {
        let signaling = crate::testing::FakeSignaling::start(crate::testing::FakeOptions::default()).await;
        let lan = "192.168.1.20:51000";
        let (session, mut rx) = offering(&signaling, &[lan]).await;
        let mapped: SocketAddr = "203.0.113.7:40000".parse().unwrap();
        let moved: SocketAddr = "203.0.113.7:40001".parse().unwrap();

        assert!(session.offer_mapped(0, Some((mapped, "pcp"))).await);
        assert_eq!(
            sent(&mut rx),
            (strings(&[lan, "203.0.113.7:40000"]), strings(&["203.0.113.7:40000"]), Some("pcp".into()))
        );
        // The same address again: nothing new to say.
        assert!(session.offer_mapped(0, Some((mapped, "pcp"))).await);
        assert!(rx.try_recv().is_err());
        // The router renewed it on another port: the old one goes.
        assert!(session.offer_mapped(0, Some((moved, "pcp"))).await);
        assert_eq!(
            sent(&mut rx),
            (strings(&[lan, "203.0.113.7:40001"]), strings(&["203.0.113.7:40001"]), Some("pcp".into()))
        );
        // It lapsed: withdrawn, unlabeled.
        assert!(session.offer_mapped(0, None).await);
        assert_eq!(sent(&mut rx), (strings(&[lan]), Vec::new(), None));

        // STUN found the same address: labeled while mapped, kept after.
        let stun = "203.0.113.9:51000";
        lock(&session.endpoints).push(stun.to_owned());
        assert!(session.offer_mapped(0, Some((stun.parse().unwrap(), "nat-pmp"))).await);
        assert_eq!(sent(&mut rx), (strings(&[lan, stun]), strings(&[stun]), Some("nat-pmp".into())));
        assert!(session.offer_mapped(0, None).await);
        assert_eq!(sent(&mut rx), (strings(&[lan, stun]), Vec::new(), None));

        // A roam drops a mapping-only endpoint (and keeps a STUN one), and
        // the old socket's mapping, from before the roam, offers nothing.
        assert!(session.offer_mapped(0, Some((mapped, "upnp"))).await);
        let _ = sent(&mut rx);
        let _ = session.roam().await;
        assert_eq!(*lock(&session.endpoints), strings(&[lan, stun]));
        assert!(lock(&session.own_mapped).is_none());
        assert!(!*lock(&session.mapped_was_offered));
        assert!(!session.offer_mapped(0, Some((moved, "upnp"))).await, "a stale mapping is not offered");
        assert!(rx.try_recv().is_err());
        // The new socket's mapping (after the roam) is.
        assert!(session.offer_mapped(1, Some((moved, "upnp"))).await);
        assert_eq!(sent(&mut rx).1, strings(&["203.0.113.7:40001"]));
        // A roam while the mapped endpoint is the one STUN found keeps it.
        assert!(session.offer_mapped(1, Some((stun.parse().unwrap(), "pcp"))).await);
        let _ = sent(&mut rx);
        let _ = session.roam().await;
        assert!(lock(&session.endpoints).contains(&stun.to_owned()), "the STUN endpoint stays");
        assert!(!lock(&session.endpoints).contains(&"203.0.113.7:40001".to_owned()));
        session.close();
    }

    #[test]
    fn roam_messages_are_small_json() {
        let message = RoamMessage::Endpoints {
            generation: 3,
            endpoints: vec!["203.0.113.7:40000".into()],
            relayed: Vec::new(),
            relayed_tls: Vec::new(),
            mapped: Vec::new(),
            mapped_by: None,
        };
        let text = serde_json::to_string(&message).unwrap();
        assert_eq!(text, r#"{"t":"endpoints","generation":3,"endpoints":["203.0.113.7:40000"]}"#);
        assert_eq!(serde_json::from_str::<RoamMessage>(&text).unwrap(), message);
        let many = RoamMessage::Endpoints {
            generation: u64::MAX,
            endpoints: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_ENDPOINTS],
            relayed: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_RELAYED],
            relayed_tls: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_RELAYED],
            mapped: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_MAPPED],
            mapped_by: Some("nat-pmp".into()),
        };
        // Fits one datagram of the 1280-byte tunnel.
        assert!(serde_json::to_vec(&many).unwrap().len() <= 1232);
        assert_eq!(
            serde_json::to_string(&RoamMessage::Ack { generation: 9 }).unwrap(),
            r#"{"t":"ack","generation":9}"#
        );
        let reach = RoamMessage::Reach { from: Some("203.0.113.7:4000".into()), via: Some("turn".into()) };
        let text = serde_json::to_string(&reach).unwrap();
        assert_eq!(text, r#"{"t":"reach","from":"203.0.113.7:4000","via":"turn"}"#);
        assert_eq!(serde_json::from_str::<RoamMessage>(&text).unwrap(), reach);
        // A bare `reach` names no route.
        assert_eq!(
            serde_json::from_str::<RoamMessage>(r#"{"t":"reach"}"#).unwrap(),
            RoamMessage::Reach { from: None, via: None }
        );
    }

    /// Protocol version 3's `metered` message, old against new both ways: a
    /// version-2 peer's messages all still parse, a `metered` one is new
    /// JSON a version-2 peer reads as unreadable and skips (its loop logs
    /// it and goes on), and only a version-3 peer gets a second socket.
    #[test]
    fn metered_messages_old_and_new() {
        let metered = RoamMessage::Metered { addresses: vec!["198.51.100.4:61000".into()] };
        let text = serde_json::to_string(&metered).unwrap();
        assert_eq!(text, r#"{"t":"metered","addresses":["198.51.100.4:61000"]}"#);
        assert_eq!(serde_json::from_str::<RoamMessage>(&text).unwrap(), metered);
        assert_eq!(
            serde_json::from_str::<RoamMessage>(r#"{"t":"metered"}"#).unwrap(),
            RoamMessage::Metered { addresses: Vec::new() }
        );
        // What a version-2 side sends parses the same here.
        let old = r#"{"t":"endpoints","generation":3,"endpoints":["203.0.113.7:40000"]}"#;
        assert!(matches!(serde_json::from_str::<RoamMessage>(old).unwrap(), RoamMessage::Endpoints { .. }));
        // A version-2 side's enum, which lacks `metered`, refuses it (and
        // `run_control` there only logs an unreadable message).
        #[derive(Debug, Deserialize)]
        #[serde(tag = "t", rename_all = "kebab-case")]
        #[allow(dead_code)]
        enum V2 {
            Endpoints { generation: u64, endpoints: Vec<String> },
            Ack { generation: u64 },
            Reach { from: Option<String>, via: Option<String> },
        }
        assert!(serde_json::from_str::<V2>(&text).is_err());
        assert!(serde_json::from_str::<V2>(old).is_ok());
        let many = RoamMessage::Metered {
            addresses: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_METERED],
        };
        assert!(serde_json::to_vec(&many).unwrap().len() <= 1232);
        const {
            assert!(super::super::WG_VERSION >= super::super::multipath::MULTIPATH_VERSION);
            assert!(2 < super::super::multipath::MULTIPATH_VERSION, "a version-2 peer gets no second socket");
        };
    }

    /// PROTOCOL.md "Mapped endpoints": a mapped endpoint is a plain endpoint
    /// plus a label, so a phone that predates it still dials it, and a new
    /// phone reads an old Mac's announcement as "nothing mapped".
    #[test]
    fn mapped_label_is_backward_compatible_both_ways() {
        // New Mac -> old phone: the old message type (no `mapped` fields)
        // still decodes and keeps the mapped address among its endpoints.
        #[derive(serde::Deserialize, Debug)]
        #[serde(tag = "t", rename_all = "kebab-case")]
        enum OldRoam {
            Endpoints {
                generation: u64,
                endpoints: Vec<String>,
                #[serde(default)]
                relayed: Vec<String>,
            },
        }
        let new = RoamMessage::Endpoints {
            generation: 4,
            endpoints: vec!["192.168.1.9:40000".into(), "203.0.113.7:41000".into()],
            relayed: Vec::new(),
            relayed_tls: Vec::new(),
            mapped: vec!["203.0.113.7:41000".into()],
            mapped_by: Some("pcp".into()),
        };
        let text = serde_json::to_string(&new).unwrap();
        assert!(text.contains(r#""mapped":["203.0.113.7:41000"],"mappedBy":"pcp""#), "{text}");
        let OldRoam::Endpoints { generation, endpoints, relayed } = serde_json::from_str(&text).unwrap();
        assert_eq!((generation, relayed.len()), (4, 0));
        assert!(endpoints.contains(&"203.0.113.7:41000".to_owned()));
        // Old Mac -> new phone: no label, nothing mapped.
        let old = r#"{"t":"endpoints","generation":2,"endpoints":["203.0.113.7:40000"]}"#;
        let RoamMessage::Endpoints { endpoints, mapped, mapped_by, .. } = serde_json::from_str(old).unwrap()
        else {
            panic!("not endpoints")
        };
        assert!(mapped.is_empty() && mapped_by.is_none());
        assert_eq!(peer_mapped_of(&endpoints, &mapped, mapped_by.as_deref()), portmap::PeerMapped::default());
        // A label naming no endpoint, or a protocol this build does not know.
        let peer = peer_mapped_of(
            &["203.0.113.7:41000".to_owned()],
            &["203.0.113.7:41000".to_owned(), "198.51.100.1:1".to_owned()],
            Some("future-proto"),
        );
        assert_eq!(peer.addresses, vec!["203.0.113.7:41000".parse::<SocketAddr>().unwrap()]);
        assert_eq!(peer.protocol, None);
    }

    /// A relay clock whose tunnel started `ago`, with nothing heard.
    fn started(ago: Duration) -> Arc<RelayShared> {
        let shared = Arc::new(RelayShared::default());
        lock(&shared.state).since = Instant::now().checked_sub(ago).expect("clock");
        shared
    }

    /// While this side takes a TURN allocation (a trickled answer's, a
    /// roam's), the relay waits for it: neither its own clock nor the
    /// peer's ask makes it join. One that came to nothing leaves the relay
    /// due at once.
    #[test]
    fn the_relay_waits_for_a_turn_allocation_under_way() {
        let shared = started(RELAY_AFTER * 2);
        assert_eq!(shared.due(true), Some("nothing reached the peer"));
        let gather = shared.gathering_turn();
        assert_eq!(shared.due(true), None, "the relay waits for the allocation");
        shared.ask();
        assert_eq!(shared.due(false), None, "the ask waits for it too");
        drop(gather);
        assert_eq!(shared.due(false), Some("the peer joined the relay"), "no allocation: join at once");
        let shared = started(RELAY_AFTER * 2);
        drop(shared.gathering_turn());
        assert_eq!(shared.due(true), Some("nothing reached the peer"));
    }

    /// An allocation that worked gets the relay's own window to carry the
    /// session, as a new tunnel does; a relay socket that died is joined
    /// again at once all the same.
    #[test]
    fn a_new_turn_allocation_gets_the_relays_window() {
        let shared = started(RELAY_AFTER * 2);
        let mut gather = shared.gathering_turn();
        gather.allocated();
        drop(gather);
        shared.ask();
        assert_eq!(shared.due(true), None, "the new allocation gets its window");
        lock(&shared.state).allocated =
            Some(Instant::now().checked_sub(RELAY_AFTER + Duration::from_millis(1)).expect("clock"));
        assert_eq!(shared.due(true), Some("the peer joined the relay"), "its window passed");
        let shared = started(RELAY_AFTER * 2);
        let _gather = shared.gathering_turn();
        shared.lost();
        assert_eq!(shared.due(true), Some("the relay socket closed"));
    }
}
