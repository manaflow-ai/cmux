//! Dormant tunnels: a handshake-first redial (PROTOCOL.md "Dormant
//! tunnels").
//!
//! A WireGuard link that ends without either side asking (its keepalive
//! timed out, its stream failed, a park lapsed) leaves its tunnel dormant on
//! both sides for [`DORMANT_HOLD`]: the session, its keys, its UDP socket and
//! TURN allocation, the peer's key and endpoints all stay, and nothing goes
//! out on its own (the tunnel is held, as a parked link holds it). A link
//! the app or the Mac closes on purpose, a `bye`, or the bound ends it as
//! before.
//!
//! The phone's next dial to that Mac holds a [`Ticket`] and runs
//! [`hedged`]: [`try_resume`] reasserts the tunnel at once (a keepalive, or
//! one handshake initiation once its keys are over two minutes old) and
//! opens a new in-tunnel connection to the link port, while the full dial
//! (signaling, `wg-init` / `wg-resp`, a new tunnel) runs beside it. The
//! first link up wins; the other is dropped. No signaling round trip is on
//! the resumed path, so a redial on a slow or dead signaling socket still
//! links in one or two round trips.
//!
//! The Mac's dormant tunnel keeps its link listener. A new connection on it
//! is a resumed link: the Mac ends any older link on that tunnel and hands
//! the new one to its answer loop as a local session ([`resumed`]), so the
//! host serves it like any dialed link.
//!
//! Nothing new is trusted: only the two WireGuard static keys of the
//! original `wg-init` / `wg-resp` (exchanged over the authenticated
//! signaling socket) can complete a Noise IK handshake or produce a datagram
//! the tunnel accepts, and the handshake's TAI64N timestamp refuses a
//! replayed initiation.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cmux_wg::WgListener;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;

use super::super::{Connected, DialError, Dialed, LinkPath, PeerAddr, TransportKind};
use super::roam::Session;
use super::{LANE_TIMEOUT, LINK_PORT, hold_hook, transport_error};
use crate::link::{Link, LinkConfig, Role};
use crate::signaling::{IncomingSession, SignalEnvelope, SignalPayload};
use crate::timing::Timeline;

/// How long a side keeps a dormant tunnel after its link ended on its own.
/// Under WireGuard's 180 s key lifetime, so a resume inside it needs no
/// handshake when both sides still hold the keys.
pub const DORMANT_HOLD: Duration = Duration::from_secs(150);
/// The phone gives a dormant tunnel up this much before the Mac does, so it
/// never resumes one the Mac just dropped at its bound.
const PHONE_MARGIN: Duration = Duration::from_secs(10);
/// The transport hold outlasts the bound a little (the tunnel is dropped at
/// the bound anyway).
const HOLD_MARGIN: Duration = Duration::from_secs(5);
/// How long a resumed link waits for the Mac's answer loop to take it.
const UNCLAIMED: Duration = Duration::from_secs(10);
/// How often a dormant tunnel looks for the peer's `bye`.
const BYE_CHECK: Duration = Duration::from_millis(250);
/// The most dormant tunnels one side keeps (each peer has at most one: a
/// newer one replaces it). The oldest goes first.
pub const MAX_DORMANT: usize = 8;
/// How long a resumed connection may take before [`try_resume`] gives up
/// (the full dial beside it goes on regardless).
pub const RESUME_WAIT: Duration = Duration::from_secs(5);

/// Link close reasons that leave the tunnel dormant: the link ended on its
/// own. Anything else (the app's close, a removed phone, a test's "done")
/// ends the tunnel too.
fn ended_on_its_own(reason: &str) -> bool {
    reason == "keepalive timed out"
        || reason == "park expired"
        || reason == "peer closed the link"
        || reason.starts_with("read failed")
        || reason.starts_with("write failed")
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Every dormant tunnel of this process, oldest first.
fn dormant() -> &'static Mutex<Vec<Arc<Keeper>>> {
    static DORMANT: Mutex<Vec<Arc<Keeper>>> = Mutex::new(Vec::new());
    &DORMANT
}

/// Resumed links waiting for the Mac's answer loop, by ticket.
fn waiting() -> &'static Mutex<HashMap<u64, Dialed>> {
    static WAITING: OnceLock<Mutex<HashMap<u64, Dialed>>> = OnceLock::new();
    WAITING.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Tests: a side that keeps no dormant tunnel, as a build before this one
/// (bit 0: the phone, bit 1: the Mac).
static OLD_SIDES_FOR_TESTS: AtomicU64 = AtomicU64::new(0);

/// Tests: the phone (`dialer`) or the Mac side of this process acts as a
/// build without dormant tunnels: its tunnel ends with its link, and it
/// tells the peer (`bye`), as before.
#[doc(hidden)]
pub fn act_old_for_tests(dialer: bool, old: bool) {
    let bit = if dialer { 1 } else { 2 };
    if old {
        OLD_SIDES_FOR_TESTS.fetch_or(bit, Ordering::Relaxed);
    } else {
        OLD_SIDES_FOR_TESTS.fetch_and(!bit, Ordering::Relaxed);
    }
}

fn acts_old(dialer: bool) -> bool {
    OLD_SIDES_FOR_TESTS.load(Ordering::Relaxed) & if dialer { 1 } else { 2 } != 0
}

/// A shorter bound for tests (0: [`DORMANT_HOLD`]).
static HOLD_FOR_TESTS: AtomicU64 = AtomicU64::new(0);

/// Tests: tunnels that go dormant from now on keep for `hold` (`None`: the
/// real [`DORMANT_HOLD`]).
#[doc(hidden)]
pub fn set_hold_for_tests(hold: Option<Duration>) {
    HOLD_FOR_TESTS.store(hold.map_or(0, |hold| hold.as_millis().max(1) as u64), Ordering::Relaxed);
}

/// What a side knows to start a keeper.
pub(super) struct KeeperSpec {
    pub session: Arc<Session>,
    pub dialer: bool,
    pub peer_device: String,
    /// The peer's Stack user as the backend stamped its `wg-init` (the Mac's
    /// answer loop admits a resumed link by it, as it admitted the dial).
    pub from_user_id: Option<String>,
    pub peer_ip: Ipv4Addr,
    pub input_lane: bool,
    /// Both sides agreed on the reliable link: a resumed link offers or
    /// accepts it as the first link did.
    pub reliable: bool,
    pub path: watch::Receiver<LinkPath>,
    pub peer: PeerAddr,
    /// The tunnel's static keys: a resumed link reports the ones its tunnel
    /// authenticated, as the first link did.
    pub tunnel_keys: super::super::TunnelKeys,
}

#[derive(Default)]
struct State {
    /// Links on this tunnel now.
    links: usize,
    /// The bound's timer while dormant.
    timer: Option<JoinHandle<()>>,
    /// Ended for good.
    closed: bool,
}

/// One tunnel's lifetime: its links hold it ([`Lease`]); the last one to end
/// on its own leaves it dormant, any other end closes it.
pub(super) struct Keeper {
    id: u64,
    session: Arc<Session>,
    dialer: bool,
    peer_device: String,
    from_user_id: Option<String>,
    peer_ip: Ipv4Addr,
    input_lane: bool,
    reliable: bool,
    path: watch::Receiver<LinkPath>,
    peer: PeerAddr,
    tunnel_keys: super::super::TunnelKeys,
    state: Mutex<State>,
    /// The Mac's accept loop for resumed connections.
    resumes: Mutex<Option<JoinHandle<()>>>,
    /// Counts resumed links: an older link on this tunnel ends at each.
    generation: watch::Sender<u64>,
}

impl Keeper {
    pub(super) fn new(spec: KeeperSpec) -> Arc<Self> {
        Arc::new(Self {
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            session: spec.session,
            dialer: spec.dialer,
            peer_device: spec.peer_device,
            from_user_id: spec.from_user_id,
            peer_ip: spec.peer_ip,
            input_lane: spec.input_lane,
            reliable: spec.reliable,
            path: spec.path,
            peer: spec.peer,
            tunnel_keys: spec.tunnel_keys,
            state: Mutex::new(State::default()),
            resumes: Mutex::new(None),
            generation: watch::channel(0).0,
        })
    }

    /// The tunnel's overlay, as the first link on it had: a resumed link
    /// syncs its viewport over the same tunnel (`None` once it stopped).
    fn overlay(&self) -> Option<super::super::Overlay> {
        let net = self.session.net().ok()?;
        Some(super::super::Overlay { net, peer_ip: IpAddr::V4(self.peer_ip) })
    }

    fn hold(&self) -> Duration {
        let bound = match HOLD_FOR_TESTS.load(Ordering::Relaxed) {
            0 => DORMANT_HOLD,
            millis => Duration::from_millis(millis),
        };
        if self.dialer { bound.saturating_sub(PHONE_MARGIN.min(bound / 10)) } else { bound }
    }

    /// A link ended (`reason`, `None` when no link ever ran on the lease).
    fn release(self: &Arc<Self>, reason: Option<&str>) {
        let dormant = {
            let mut state = lock(&self.state);
            state.links = state.links.saturating_sub(1);
            if state.links > 0 || state.closed {
                return;
            }
            reason.is_some_and(ended_on_its_own)
                && !acts_old(self.dialer)
                && self.session.net().is_ok()
                && tokio::runtime::Handle::try_current().is_ok()
        };
        if dormant {
            self.go_dormant();
        } else {
            self.close();
        }
    }

    fn go_dormant(self: &Arc<Self>) {
        let hold = self.hold();
        let weak = Arc::downgrade(self);
        let timer = tokio::spawn(async move {
            // Ends at the bound, or once the peer's `bye` dropped the tunnel
            // (its link closed on purpose after this side saw it end).
            let bound = tokio::time::Instant::now() + hold;
            loop {
                let now = tokio::time::Instant::now();
                if now >= bound {
                    break;
                }
                tokio::time::sleep((bound - now).min(BYE_CHECK)).await;
                let Some(keeper) = weak.upgrade() else { return };
                if keeper.session.net().is_err() {
                    break;
                }
            }
            if let Some(keeper) = weak.upgrade()
                && unlist(keeper.id).is_some()
            {
                tracing::info!(session = keeper.session.id(), "dormant tunnel ended (bound or bye)");
                keeper.close();
            }
        });
        lock(&self.state).timer = Some(timer);
        let replaced: Vec<Arc<Keeper>> = {
            let mut list = lock(dormant());
            let mut replaced = Vec::new();
            list.retain(|other| {
                let same = other.dialer == self.dialer && other.peer_device == self.peer_device;
                if same {
                    replaced.push(Arc::clone(other));
                }
                !same
            });
            list.push(Arc::clone(self));
            while list.len() > MAX_DORMANT {
                replaced.push(list.remove(0));
            }
            replaced
        };
        for old in replaced {
            old.close();
        }
        if let Ok(net) = self.session.net() {
            tokio::spawn(async move {
                let _ = net.hold(Some(hold + HOLD_MARGIN)).await;
            });
        }
        tracing::info!(session = self.session.id(), peer = self.peer_device, ?hold, "tunnel dormant");
    }

    /// A new link takes the tunnel: it is not dormant any more.
    fn wake(&self) {
        unlist(self.id);
        if let Some(timer) = lock(&self.state).timer.take() {
            timer.abort();
        }
        if let Ok(net) = self.session.net() {
            tokio::spawn(async move {
                let _ = net.hold(None).await;
            });
        }
    }

    /// End the tunnel (and tell the peer, as any closed session does).
    fn close(&self) {
        {
            let mut state = lock(&self.state);
            if state.closed {
                return;
            }
            state.closed = true;
            if let Some(timer) = state.timer.take() {
                timer.abort();
            }
        }
        unlist(self.id);
        if let Some(task) = lock(&self.resumes).take() {
            task.abort();
        }
        self.session.close();
    }

    /// Mac: accept resumed connections on the tunnel's link listener for as
    /// long as the tunnel lives, and hand each to the answer loop.
    pub(super) fn serve_resumes(self: &Arc<Self>, mut listener: WgListener) {
        let weak = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            while let Some(stream) = listener.accept().await {
                let Some(keeper) = weak.upgrade() else { return };
                let lease = Lease::new(&keeper);
                keeper.wake();
                // The older link on this tunnel (the Mac may not have seen it
                // fail yet) ends now; the lease above keeps the tunnel.
                keeper.generation.send_modify(|generation| *generation += 1);
                let lane = if keeper.input_lane {
                    let (tx, rx) = oneshot::channel();
                    match tokio::time::timeout(LANE_TIMEOUT, listener.accept()).await {
                        Ok(Some(stream)) => {
                            let _ = tx.send(Box::new(stream) as Box<dyn super::super::LinkStream>);
                        }
                        _ => tracing::info!("a resumed link's input lane was not opened in time"),
                    }
                    Some(rx)
                } else {
                    None
                };
                keeper.hand_to_answer(lease, Box::new(stream), lane);
            }
        });
        if let Some(old) = lock(&self.resumes).replace(task) {
            old.abort();
        }
    }

    fn hand_to_answer(
        self: &Arc<Self>,
        lease: Lease,
        stream: Box<dyn super::super::LinkStream>,
        lane: Option<oneshot::Receiver<Box<dyn super::super::LinkStream>>>,
    ) {
        let ticket = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let on_link = lease.on_link();
        let dialed = Dialed {
            stream,
            path: self.path.clone(),
            peer: self.peer.clone(),
            guard: Box::new(lease),
            lane,
            media: None,
            webrtc_media: false,
            hold: Some(hold_hook(&self.session)),
            liveness: None,
            on_link: Some(on_link),
            reliable: self.reliable,
            tunnel_keys: Some(self.tunnel_keys.clone()),
            overlay: self.overlay(),
        };
        lock(waiting()).insert(ticket, dialed);
        let signaling = self.session.signaling_client();
        let (_events_tx, events) = mpsc::unbounded_channel();
        let session = IncomingSession {
            first: SignalEnvelope {
                to: signaling.device_id().to_owned(),
                from: self.peer_device.clone(),
                session_id: uuid::Uuid::new_v4().to_string(),
                payload: SignalPayload::WgResumed { ticket },
                from_user_id: self.from_user_id.clone(),
                relay_ticket: None,
            },
            events,
        };
        if signaling.inject_session(session) {
            tracing::info!(
                session = self.session.id(),
                phone = self.peer_device,
                "resumed link from a dormant tunnel"
            );
            // The answer loop refused it (admission: the Mac's owner changed)
            // or never took it: the link is dropped, and with it the tunnel.
            tokio::spawn(async move {
                tokio::time::sleep(UNCLAIMED).await;
                lock(waiting()).remove(&ticket);
            });
        } else {
            // No answer loop to take it: the phone's full dial goes on.
            lock(waiting()).remove(&ticket);
        }
    }
}

fn unlist(id: u64) -> Option<Arc<Keeper>> {
    let mut list = lock(dormant());
    let at = list.iter().position(|keeper| keeper.id == id)?;
    Some(list.remove(at))
}

/// One link's hold on its tunnel ([`Dialed::guard`]). Dropping it (the link
/// closed) leaves the tunnel dormant when the link ended on its own and no
/// other link runs on it, else closes it.
pub(super) struct Lease {
    keeper: Arc<Keeper>,
    closed: Arc<OnceLock<watch::Receiver<Option<String>>>>,
}

impl Lease {
    pub(super) fn new(keeper: &Arc<Keeper>) -> Self {
        lock(&keeper.state).links += 1;
        Self { keeper: Arc::clone(keeper), closed: Arc::new(OnceLock::new()) }
    }

    /// Run once the link exists: the lease learns how it closes, and an older
    /// link ends when the peer resumes the tunnel with a new one.
    pub(super) fn on_link(&self) -> crate::dial::OnLink {
        let closed = Arc::clone(&self.closed);
        let mut generation = self.keeper.generation.subscribe();
        generation.mark_unchanged();
        Box::new(move |link: &Link| {
            let _ = closed.set(link.closed_state());
            let link = link.clone();
            tokio::spawn(async move {
                tokio::select! {
                    changed = generation.changed() => {
                        if changed.is_ok() {
                            link.close("resumed on a new link");
                        }
                    }
                    _ = link.closed() => {}
                }
            });
        })
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        let reason = self.closed.get().and_then(|closed| closed.borrow().clone());
        self.keeper.release(reason.as_deref());
    }
}

/// Mac: a full dial from `peer_device` linked, so its dormant tunnel (if
/// any) is stale. Phone: likewise for a Mac.
pub(super) fn superseded(dialer: bool, peer_device: &str) {
    let stale: Vec<Arc<Keeper>> = {
        let mut list = lock(dormant());
        let mut stale = Vec::new();
        list.retain(|keeper| {
            let same = keeper.dialer == dialer && keeper.peer_device == peer_device;
            if same {
                stale.push(Arc::clone(keeper));
            }
            !same
        });
        stale
    };
    for keeper in stale {
        keeper.close();
    }
}

/// The Mac's answer for a [`SignalPayload::WgResumed`] session.
pub(super) fn resumed(ticket: u64) -> Result<Dialed, DialError> {
    lock(waiting())
        .remove(&ticket)
        .ok_or_else(|| DialError::Unexpected("no resumed link for this ticket".into()))
}

/// End every dormant tunnel with `peer_device` (either side): the phone was
/// removed or signed out.
pub fn forget(peer_device: &str) -> usize {
    let gone: Vec<Arc<Keeper>> = {
        let mut list = lock(dormant());
        let mut gone = Vec::new();
        list.retain(|keeper| {
            let same = keeper.peer_device.eq_ignore_ascii_case(peer_device);
            if same {
                gone.push(Arc::clone(keeper));
            }
            !same
        });
        gone
    };
    let count = gone.len();
    for keeper in gone {
        keeper.close();
    }
    count
}

/// End every dormant tunnel of this process (sign-out, a reset).
pub fn forget_all() -> usize {
    let gone = std::mem::take(&mut *lock(dormant()));
    let count = gone.len();
    for keeper in gone {
        keeper.close();
    }
    count
}

/// Whether a dormant tunnel with `peer_device` is kept (the Mac's side: a
/// phone's device id).
pub fn keeps(peer_device: &str) -> bool {
    lock(dormant()).iter().any(|keeper| !keeper.dialer && keeper.peer_device == peer_device)
}

/// How many dormant tunnels this side keeps now.
pub fn count() -> usize {
    lock(dormant()).len()
}

/// The phone's claim on a dormant tunnel to a Mac.
#[derive(Debug, Clone)]
pub struct Ticket {
    pub mac: String,
    id: u64,
}

/// The phone's dormant tunnel to `mac`, if it keeps one.
pub fn ticket(mac: &str) -> Option<Ticket> {
    lock(dormant())
        .iter()
        .find(|keeper| keeper.dialer && keeper.peer_device == mac && keeper.session.net().is_ok())
        .map(|keeper| Ticket { mac: mac.to_owned(), id: keeper.id })
}

/// Phone: run a new link on the dormant tunnel `ticket` names, with no
/// signaling. Marks `dormant_resume`, `dormant_connected` and `link_ready`.
/// On failure (the tunnel was dropped, the Mac does not answer within
/// [`RESUME_WAIT`]) the tunnel is closed.
pub async fn try_resume(
    ticket: &Ticket,
    link_config: LinkConfig,
    timeline: &Timeline,
) -> Result<Connected, DialError> {
    let keeper = lock(dormant())
        .iter()
        .find(|keeper| keeper.id == ticket.id)
        .cloned()
        .ok_or_else(|| DialError::Transport("the dormant tunnel is gone".into()))?;
    // The lease closes the tunnel if this is dropped (the full dial won)
    // before a link runs on it.
    let lease = Lease::new(&keeper);
    keeper.wake();
    timeline.mark("dormant_resume");
    let net = keeper.session.net()?;
    // Release the hold, then reassert at once (a keepalive, or a handshake
    // initiation once the keys are old) toward the remembered endpoints.
    let _ = net.hold(None).await;
    net.refresh().await.map_err(transport_error)?;
    let link_addr = SocketAddr::new(IpAddr::V4(keeper.peer_ip), LINK_PORT);
    let stream = tokio::time::timeout(RESUME_WAIT, net.connect(link_addr))
        .await
        .map_err(|_| DialError::Timeout)?
        .map_err(transport_error)?;
    timeline.mark("dormant_connected");
    let lane = keeper.input_lane.then(|| {
        let (tx, rx) = oneshot::channel();
        let net = Arc::clone(&net);
        tokio::spawn(async move {
            if let Ok(Ok(stream)) = tokio::time::timeout(LANE_TIMEOUT, net.connect(link_addr)).await {
                let _ = tx.send(Box::new(stream) as Box<dyn super::super::LinkStream>);
            }
        });
        rx
    });
    let on_link = lease.on_link();
    let link_config = super::super::reliable_config(link_config, keeper.reliable, None);
    let link = Link::new(stream, Role::Phone, link_config, Some(Box::new(lease)));
    on_link(&link);
    link.set_hold_hook(hold_hook(&keeper.session));
    super::super::follow_lane(&link, lane);
    timeline.mark("link_ready");
    Ok(Connected {
        link,
        transport: TransportKind::WireGuard,
        path: keeper.path.clone(),
        peer: keeper.peer.clone(),
        session_id: keeper.session.id().to_owned(),
        webrtc_media: false,
        resumed: false,
        tunnel_keys: Some(keeper.tunnel_keys.clone()),
        overlay: keeper.overlay(),
    })
}

/// Which path linked.
pub enum Hedged<T> {
    /// The full dial.
    Full(T),
    /// The dormant tunnel.
    Resumed(Connected),
}

/// Phone: a redial. With a `ticket`, [`try_resume`] runs beside `full`; the
/// first link up wins and the other is dropped. Without one, `full` alone.
/// A failed resume adds nothing to `full`'s time; when both fail, `full`'s
/// error is returned.
pub async fn hedged<T, E, F>(
    ticket: Option<Ticket>,
    link_config: LinkConfig,
    timeline: &Timeline,
    full: F,
) -> Result<Hedged<T>, E>
where
    F: std::future::Future<Output = Result<T, E>>,
{
    let Some(ticket) = ticket else { return full.await.map(Hedged::Full) };
    let resume = try_resume(&ticket, link_config, timeline);
    tokio::pin!(resume);
    tokio::pin!(full);
    let mut resume_failed = false;
    let mut full_failed: Option<E> = None;
    loop {
        tokio::select! {
            resumed = &mut resume, if !resume_failed => match resumed {
                Ok(connected) => {
                    timeline.mark("dormant_won");
                    return Ok(Hedged::Resumed(connected));
                }
                Err(error) => {
                    tracing::info!(%error, mac = ticket.mac, "dormant tunnel did not resume; the full dial goes on");
                    timeline.mark("dormant_failed");
                    resume_failed = true;
                    if let Some(error) = full_failed.take() {
                        return Err(error);
                    }
                }
            },
            dialed = &mut full, if full_failed.is_none() => match dialed {
                Ok(dialed) => return Ok(Hedged::Full(dialed)),
                Err(error) if resume_failed => return Err(error),
                Err(error) => full_failed = Some(error),
            },
        }
    }
}
