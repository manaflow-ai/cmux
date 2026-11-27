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

use std::sync::Weak;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_wg::{Priority, WgDatagramSocket};
use serde::{Deserialize, Serialize};
use tokio::task::JoinHandle;

use super::*;

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
    /// Debug and tests: the TURN allocation's stream to its server dies.
    KillTurn,
}

/// Relayed addresses one announcement carries (a phone has one TURN
/// allocation), so the message stays within one tunnel datagram.
const MAX_RELAYED: usize = 2;

/// This side's endpoints to announce, which of them are its TURN relayed
/// addresses, and which of those ride TCP or TLS.
type Announcement = (Vec<String>, Vec<String>, Vec<String>);

/// Waits before each new try to replace a dead TURN allocation.
const TURN_RETRIES: [Duration; 5] = [
    Duration::ZERO,
    Duration::from_secs(1),
    Duration::from_secs(3),
    Duration::from_secs(10),
    Duration::from_secs(30),
];

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
    },
    Ack {
        generation: u64,
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
    turn_monitor: Mutex<Option<JoinHandle<()>>>,
    /// Announcements the peer sent through signaling, for the control task.
    inject: mpsc::UnboundedSender<RoamMessage>,
    injected: Mutex<Option<mpsc::UnboundedReceiver<RoamMessage>>>,
    /// Asks the control task to send its latest announcement through
    /// signaling again (a new signaling socket).
    resignal: mpsc::UnboundedSender<()>,
    resignals: Mutex<Option<mpsc::UnboundedReceiver<()>>>,
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
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn registry() -> &'static Mutex<Vec<Weak<Session>>> {
    static SESSIONS: Mutex<Vec<Weak<Session>>> = Mutex::new(Vec::new());
    &SESSIONS
}

/// Every live session of this process.
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
        });
        lock(registry()).push(Arc::downgrade(&session));
        if let Some(dead) = turn_dead {
            session.monitor_turn(dead);
        }
        session
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
        let weak = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            if !start.await {
                return;
            }
            for wait in TURN_RETRIES {
                tokio::time::sleep(wait).await;
                let Some(session) = weak.upgrade() else { return };
                if session.closed.load(Ordering::Relaxed) {
                    return;
                }
                tracing::info!(session = session.session_id, "{why}");
                if session.replace_turn().await {
                    return;
                }
            }
            tracing::info!("no new TURN allocation; the session goes on without TURN");
        });
        stop_monitor(lock(&self.turn_monitor).replace(task));
    }

    /// Take a new TURN allocation on the current network and tell the peer
    /// its address; `false` when none could be had.
    async fn replace_turn(self: &Arc<Self>) -> bool {
        // Allocate before taking the roam lock: a roam meanwhile must not wait
        // seconds for an allocation that belongs to the old network.
        let roams = self.roams.load(Ordering::Relaxed);
        let Some(turn) = TurnCarrier::allocate(&self.options).await else { return false };
        let _one_at_a_time = self.roaming.lock().await;
        if self.roams.load(Ordering::Relaxed) != roams || self.closed.load(Ordering::Relaxed) {
            // A roam took its own allocation on the new network, or started
            // its own retry.
            return true;
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

    /// Hand `turn` to the underlay and watch its stream.
    fn install_turn(self: &Arc<Self>, turn: TurnCarrier, relayed: (Vec<String>, Vec<String>)) {
        let dead = turn.transport.is_stream().then(|| turn.dead());
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

    /// Watch `events` for the peer's `bye`, replacing the subscription of
    /// an earlier signaling socket.
    pub(super) fn follow(&self, mut events: mpsc::UnboundedReceiver<SessionEvent>) {
        let net = Arc::clone(&self.net);
        let inject = self.inject.clone();
        let task = tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Some(SessionEvent::Signal(SignalEnvelope {
                        payload: SignalPayload::WgEndpoints { generation, endpoints, relayed, relayed_tls },
                        ..
                    })) => {
                        let _ = inject.send(RoamMessage::Endpoints {
                            generation,
                            endpoints,
                            relayed,
                            relayed_tls,
                        });
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
    fn announce(&self, endpoints: Vec<String>, relayed: Vec<String>, relayed_tls: Vec<String>) {
        if !endpoints.is_empty() {
            lock(&self.endpoints).clone_from(&endpoints);
        }
        if let Some(tx) = lock(&self.announce).as_ref() {
            let _ = tx.send((endpoints, relayed, relayed_tls));
        }
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
        let timeline = Timeline::new();
        timeline.mark("network_changed");
        *lock(&self.last_roam) = Some(timeline.clone());
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
        self.path_epoch.send_modify(|epoch| *epoch += 1);
        let mut endpoints = host_endpoints(port, &self.options);
        self.announce(offered(endpoints.iter().copied(), &self.options), Vec::new(), Vec::new());
        // On the transport the new network allows: UDP, else TLS.
        let mut keeps_turn = self.keeps_turn.load(Ordering::Relaxed);
        let turn = async { if keeps_turn { TurnCarrier::allocate(&self.options).await } else { None } };
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
        let (mut turn, reflexive) = tokio::join!(turn, reflexive);
        if turn.is_none() && !keeps_turn && asked > 0 && reflexive.is_empty() {
            // A Mac roamed onto a network that answers no STUN (it drops
            // UDP): from now on it keeps a TURN allocation, and keeps asking
            // below when this one misses.
            keeps_turn = true;
            self.keeps_turn.store(true, Ordering::Relaxed);
            turn = TurnCarrier::allocate(&self.options).await;
        }
        let known = endpoints.len();
        for address in reflexive {
            if !endpoints.contains(&address) {
                endpoints.push(address);
            }
        }
        let (mut relayed, mut relayed_tls) = (Vec::new(), Vec::new());
        if let Some(turn) = turn {
            timeline.mark(if turn.transport.is_stream() {
                "roam_turn_tls_allocated"
            } else {
                "roam_turn_allocated"
            });
            endpoints.push(turn.relayed);
            (relayed, relayed_tls) = relayed_of(Some(&turn));
            self.install_turn(turn, (relayed.clone(), relayed_tls.clone()));
            let _ = net.refresh().await;
        } else {
            // The old network's relayed address is dead: stop offering it
            // (a relay-only roam above announced nothing in its place).
            let (old, _) = std::mem::take(&mut *lock(&self.relayed));
            lock(&self.endpoints).retain(|endpoint| !old.contains(endpoint));
            if missed_turn(keeps_turn, None, &self.options) {
                // The new network's TURN server did not answer in time: keep
                // asking (this also replaces a retry started on the old one).
                self.retry_turn("roam took no TURN allocation; taking one", async { true });
            }
        }
        if endpoints.len() != known {
            self.announce(offered(endpoints, &self.options), relayed, relayed_tls);
        }
        timeline.mark("roam_gathered");
        tracing::info!(session = self.session_id, timings = %timeline.summary(), "WireGuard roamed");
        timeline
    }

    fn rehome_onto(&self, client: &SignalingClient) {
        let old = std::mem::replace(&mut *lock(&self.signaling), client.clone());
        old.unsubscribe(&self.session_id);
        self.follow(client.subscribe(&self.session_id));
        // An announcement sent while the old socket was dead is sent again.
        let _ = self.resignal.send(());
        tracing::debug!(session = self.session_id, "WireGuard session moved to a new signaling socket");
    }
}

async fn send_message(socket: &WgDatagramSocket, peer: SocketAddr, message: &RoamMessage) {
    let bytes = serde_json::to_vec(message).expect("roam message serializes");
    if let Err(error) = socket.send_to(&bytes, peer, Priority::Interactive).await {
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
        let RoamMessage::Endpoints { generation, endpoints, relayed, relayed_tls } = message.clone() else {
            return;
        };
        let client = lock(&self.signaling).clone();
        let payload = SignalPayload::WgEndpoints { generation, endpoints, relayed, relayed_tls };
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
    resignal: mpsc::UnboundedReceiver<()>,
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
    let ControlChannels { mut announce, mut reach, mut injected, mut resignal, signal } = channels;
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
        tokio::select! {
            Some((from, carrier)) = reach.recv() => {
                let via = if carrier == Carrier::Turn { "turn" } else { "udp" };
                let message = RoamMessage::Reach { from: Some(from.to_string()), via: Some(via.to_owned()) };
                send_message(&socket, peer, &message).await;
            }
            endpoints = announce.recv() => {
                let Some((mut endpoints, relayed, relayed_tls)) = endpoints else { return };
                // Past the limit, drop plain endpoints from the end first: a long
                // list never loses the relayed ones, and the order (the first
                // endpoint tells the peer the network changed) stays.
                while endpoints.len() > MAX_ENDPOINTS {
                    match endpoints.iter().rposition(|text| !relayed.contains(text)) {
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
                let message = RoamMessage::Endpoints { generation, endpoints, relayed, relayed_tls };
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
            Some(()) = resignal.recv() => {
                if let Some(message) = &latest {
                    signal.send(message);
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
                    Ok(RoamMessage::Endpoints { generation: theirs, endpoints, relayed, relayed_tls }) => {
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
                        if control.send(Control::PeerEndpoints { endpoints, relayed, relayed_tls }).is_err() {
                            return;
                        }
                        if moved {
                            // The peer's network changed.
                            path_epoch.send_modify(|epoch| *epoch += 1);
                        }
                        // Send at once, so the spray opens this side's NAT
                        // toward the peer's new address.
                        let current = lock(&net).clone();
                        if let Some(net) = current {
                            let _ = net.refresh().await;
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
    let sessions = live();
    let roams =
        sessions.iter().map(|session| async move { (session.session_id.clone(), session.roam().await) });
    futures_util::future::join_all(roams).await
}

/// Move the sessions on `client`'s device that run on another (dead or
/// replaced) signaling socket onto `client`. Returns how many moved.
pub fn rehome(client: &SignalingClient) -> usize {
    let mut moved = 0;
    for session in live() {
        let current = session.signaling();
        if current.device_id() == client.device_id() && !current.same_socket(client) {
            session.rehome_onto(client);
            moved += 1;
        }
    }
    moved
}

/// The marks of session `session_id`'s latest roam.
pub fn roam_timeline(session_id: &str) -> Option<Timeline> {
    live().into_iter().find(|s| s.session_id == session_id).and_then(|s| lock(&s.last_roam).clone())
}

/// Test support: roam one side of one session (both sides of a test run in
/// one process).
#[doc(hidden)]
pub async fn roam_session(session_id: &str, dialer: bool) -> Option<Timeline> {
    let session = find(session_id, dialer)?;
    Some(session.roam().await)
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

/// Debug and tests: the TCP or TLS stream of one side's TURN allocation
/// (of `session_id`, or of every session) dies, as when a middlebox resets
/// it. The session takes a new allocation. Returns how many sessions it hit.
#[doc(hidden)]
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

    #[test]
    fn roam_messages_are_small_json() {
        let message = RoamMessage::Endpoints {
            generation: 3,
            endpoints: vec!["203.0.113.7:40000".into()],
            relayed: Vec::new(),
            relayed_tls: Vec::new(),
        };
        let text = serde_json::to_string(&message).unwrap();
        assert_eq!(text, r#"{"t":"endpoints","generation":3,"endpoints":["203.0.113.7:40000"]}"#);
        assert_eq!(serde_json::from_str::<RoamMessage>(&text).unwrap(), message);
        let many = RoamMessage::Endpoints {
            generation: u64::MAX,
            endpoints: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_ENDPOINTS],
            relayed: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_RELAYED],
            relayed_tls: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_RELAYED],
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
}
