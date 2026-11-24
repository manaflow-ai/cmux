//! The tunnel's routes as paths of the shared path selector
//! (`cmux_transport::Selector`), probed inside the session with the same
//! schedule and quiet-path watch as every `cmux-wg` multipath tunnel
//! (`cmux_wg::PathWatch`).
//!
//! Each route the underlay can send on (plain UDP to a peer endpoint, plain
//! UDP to the peer's TURN relayed address, our TURN allocation to a peer
//! endpoint) is one path. A path is alive only after a probe sent on it is
//! answered, which proves both directions, so the selector's choice needs
//! no `reach` confirmation. The selector ranks alive paths: direct beats
//! relayed, and among direct paths the medium of the peer's address in
//! this device's interface table decides (a Thunderbolt or same-host link,
//! then the LAN, then a routed or tailnet address), RTT with hysteresis
//! after that. When the chosen path goes quiet (datagrams out, nothing
//! authenticated back on it for four round trips and an unanswered probe)
//! it is suspect: the underlay sends on every route until it answers or
//! dies, instead of waiting out the route rules' 14 s silence.
//!
//! Until a path is alive (the dial, right after a roam, or a peer whose
//! tunnel never answers probes) the selector chooses nothing and the
//! underlay's own route rules decide, as before.

use cmux_transport::selector::default_medium;
use cmux_transport::{
    LocalNetwork, Medium, PathId, PathKind, PathState, ProbeOutcome, Selector, SelectorConfig,
    local_networks, medium_of,
};
use cmux_wg::{DueProbes, PathWatch, ProbeConfig};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::time::Instant;

use super::{Carrier, Route};

/// While the session rides a relay and carries data, every dead direct path
/// is probed this often, not at a dead path's 30 s turn: the direct path
/// that starts working (the one WebRTC media just found, a NAT mapping that
/// opened) carries the session within about this long plus a round trip.
/// Both sides do it, so their probes open each other's NAT filters.
pub(super) const UPGRADE_PROBE_EVERY: Duration = Duration::from_millis(750);
/// How long after the last data datagram the session counts as carrying
/// data. An idle relayed link (keepalives only) keeps the 30 s turn, so a
/// phone on cellular does not wake its radio every second for nothing.
pub(super) const UPGRADE_BUSY: Duration = Duration::from_secs(3);

/// How often a path that is not the current one is probed while the app is
/// in front: each standby (the TURN allocation over UDP or TLS, the other
/// direct routes) stays warm, its NAT mapping, TURN permission and stream
/// under the common 30 s idle cut, so a failover from the current path
/// finds a route that answered within this and costs one packet. (The
/// shared schedule's 30 s sits on that cut.)
pub(super) const WARM_EVERY: Duration = Duration::from_secs(25);

/// The phone app is in the background ([`set_app_backgrounded`]). False
/// until it says (and always on the Mac), so nothing changes for a side
/// that never calls it.
static APP_BACKGROUNDED: AtomicBool = AtomicBool::new(false);

/// The phone app went to (`true`) or came back from (`false`) the
/// background. While it is there no session sends upgrade probes
/// ([`UPGRADE_PROBE_EVERY`]) nor keeps its standbys warm ([`WARM_EVERY`]):
/// while the current path answers only it is probed, so a backgrounded
/// phone (a call, a background task) does not wake its radio for routes it
/// is not using. Once the current path goes quiet every route is probed
/// again, and back in front each standby's overdue probe goes at once. The same app state as the Link's
/// foreground probe (`Link::set_foreground_probe`, off whenever the app is
/// backgrounded).
pub fn set_app_backgrounded(backgrounded: bool) {
    APP_BACKGROUNDED.store(backgrounded, Ordering::Relaxed);
}

/// The last value [`set_app_backgrounded`] stored.
pub fn app_backgrounded() -> bool {
    APP_BACKGROUNDED.load(Ordering::Relaxed)
}

/// Selector path ids start here: below are the receive origins
/// (`UDP_PATH`, `TURN_PATH`), which a peer's probe answer names.
const FIRST_ID: u16 = 16;

struct Entry {
    id: PathId,
    route: Route,
    watch: PathWatch,
    /// When this (dead, direct) path may get its next upgrade probe.
    upgrade_probe_at: Option<Instant>,
}

/// One route the underlay may use, and whether it rides a TURN server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Wanted {
    pub route: Route,
    pub relayed: bool,
}

pub(super) struct Paths {
    selector: Selector,
    entries: Vec<Entry>,
    next_id: u16,
    /// This device's interfaces, for each direct path's medium.
    networks: Vec<LocalNetwork>,
    probes: ProbeConfig,
    last_probe_id: u64,
    /// Until when the session counts as carrying data ([`UPGRADE_BUSY`]).
    busy_until: Option<Instant>,
    /// Where the app's background state is read ([`APP_BACKGROUNDED`]; a
    /// test's own flag in unit tests, which run side by side).
    backgrounded: &'static AtomicBool,
}

impl Paths {
    pub fn new() -> Self {
        Self {
            selector: Selector::new(SelectorConfig::default()),
            entries: Vec::new(),
            next_id: FIRST_ID,
            networks: local_networks(),
            probes: ProbeConfig { other_interval: WARM_EVERY, ..ProbeConfig::default() },
            last_probe_id: 0,
            busy_until: None,
            backgrounded: &APP_BACKGROUNDED,
        }
    }

    fn rank_of(&self, wanted: Wanted) -> (PathKind, Medium) {
        if wanted.relayed || wanted.route.carrier == Carrier::Turn {
            return (PathKind::TurnRelay, Medium::Routed);
        }
        if self.networks.is_empty() {
            return (PathKind::DirectWan, default_medium(PathKind::DirectWan));
        }
        match medium_of(wanted.route.addr.ip(), &self.networks) {
            Medium::Routed => (PathKind::DirectWan, Medium::Routed),
            medium => (PathKind::DirectLan, medium),
        }
    }

    /// Make the path set exactly `wanted`: new routes become probing paths,
    /// routes no longer wanted are removed (the selector moves off them). A
    /// route whose kind changed (a learned address the peer then announced
    /// as its new TURN relayed address) is removed and added again, so the
    /// selector never ranks a relay as direct.
    pub fn sync(&mut self, wanted: &[Wanted]) {
        let gone: Vec<PathId> = self
            .entries
            .iter()
            .filter(|entry| match wanted.iter().find(|want| want.route == entry.route) {
                None => true,
                Some(want) => {
                    self.selector.path(entry.id).is_some_and(|view| view.kind != self.rank_of(*want).0)
                }
            })
            .map(|entry| entry.id)
            .collect();
        for id in gone {
            self.remove_id(id);
        }
        for want in wanted {
            if self.entries.iter().any(|entry| entry.route == want.route) {
                continue;
            }
            let (kind, medium) = self.rank_of(*want);
            // Ids are never reused (a late answer must not revive a new
            // path); after all of them, the oldest free ones come back.
            for _ in 0..=u16::MAX {
                let id = PathId(self.next_id);
                self.next_id = self.next_id.checked_add(1).unwrap_or(FIRST_ID);
                if self.selector.add_path_on(id, kind, medium).is_ok() {
                    self.entries.push(Entry {
                        id,
                        route: want.route,
                        watch: PathWatch::default(),
                        upgrade_probe_at: None,
                    });
                    break;
                }
            }
        }
    }

    fn remove_id(&mut self, id: PathId) {
        let _ = self.selector.remove_path(id);
        self.entries.retain(|entry| entry.id != id);
    }

    /// The route can carry nothing (the OS refused it).
    pub fn remove(&mut self, route: Route) {
        if let Some(id) = self.entries.iter().find(|entry| entry.route == route).map(|entry| entry.id) {
            self.remove_id(id);
        }
    }

    /// Every path on `carrier` is gone (a new TURN allocation replaced the
    /// old one); the next [`Paths::sync`] adds fresh ones.
    pub fn forget_carrier(&mut self, carrier: Carrier) {
        let ids: Vec<PathId> = self
            .entries
            .iter()
            .filter(|entry| entry.route.carrier == carrier)
            .map(|entry| entry.id)
            .collect();
        for id in ids {
            self.remove_id(id);
        }
    }

    /// This device's network changed: read the interface table again and
    /// start every path over (mappings changed; each must answer again).
    pub fn on_network_change(&mut self) {
        self.networks = local_networks();
        let ranks: Vec<(PathId, Medium)> = self
            .entries
            .iter()
            .map(|entry| {
                let relayed = self.selector.path(entry.id).is_some_and(|view| !view.kind.class().is_direct());
                (entry.id, self.rank_of(Wanted { route: entry.route, relayed }).1)
            })
            .collect();
        for (id, medium) in ranks {
            let _ = self.selector.set_medium(id, medium);
        }
        self.selector.on_network_change();
        for entry in &mut self.entries {
            entry.watch = PathWatch::default();
        }
    }

    fn route_of_id(&self, id: Option<PathId>) -> Option<Route> {
        let id = id?;
        self.entries.iter().find(|entry| entry.id == id).map(|entry| entry.route)
    }

    /// The route the selector sends on: an alive path.
    pub fn current(&self) -> Option<Route> {
        self.route_of_id(self.selector.current())
    }

    /// The chosen path went quiet: datagrams go on every route.
    pub fn suspect(&self) -> bool {
        self.selector.chosen().is_some() && self.selector.current().is_none()
    }

    /// The selector holds a path, alive or suspect: it decides the route,
    /// not the arrival and `reach` rules.
    pub fn drives(&self) -> bool {
        self.selector.chosen().is_some()
    }

    /// The route of one of our paths (a probe goes out on it).
    pub fn route_of(&self, id: PathId) -> Option<Route> {
        self.route_of_id(Some(id))
    }

    /// A datagram went out on `route`.
    pub fn sent(&mut self, route: Route, now: Instant) {
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.route == route) {
            entry.watch.sent(now);
        }
    }

    /// A data datagram (not a keepalive or handshake) went out: while the
    /// session is relayed its dead direct paths are probed every
    /// [`UPGRADE_PROBE_EVERY`] for the next [`UPGRADE_BUSY`].
    pub fn sent_data(&mut self, now: Instant) {
        self.busy_until = Some(now + UPGRADE_BUSY);
    }

    /// The session rides a relay: the alive path it sends on is not direct.
    fn relayed(&self) -> bool {
        self.selector
            .current()
            .and_then(|id| self.selector.path(id))
            .is_some_and(|view| !view.kind.class().is_direct())
    }

    /// While relayed and busy: each dead direct path whose upgrade probe is
    /// due gets one now. Returns when the next is due.
    fn upgrade_probes(&mut self, now: Instant) -> Option<Instant> {
        // Stops when the session goes direct, when no data went out for
        // UPGRADE_BUSY, or while the phone app is in the background.
        if !self.relayed()
            || self.busy_until.is_none_or(|until| now >= until)
            || self.backgrounded.load(Ordering::Relaxed)
        {
            for entry in &mut self.entries {
                entry.upgrade_probe_at = None;
            }
            return None;
        }
        let mut next: Option<Instant> = None;
        for entry in &mut self.entries {
            let Some(view) = self.selector.path(entry.id) else { continue };
            if !view.kind.class().is_direct() || view.state != PathState::Dead {
                entry.upgrade_probe_at = None;
                continue;
            }
            let at = *entry.upgrade_probe_at.get_or_insert(now);
            let at = if now >= at {
                entry.watch.probe_now(now);
                let again = now + UPGRADE_PROBE_EVERY;
                entry.upgrade_probe_at = Some(again);
                again
            } else {
                at
            };
            next = Some(next.map_or(at, |next| next.min(at)));
        }
        next
    }

    /// A datagram went out on every route (the chosen one is suspect).
    pub fn sent_everywhere(&mut self, now: Instant) {
        for entry in &mut self.entries {
            entry.watch.sent(now);
        }
    }

    /// An authenticated datagram arrived on `route`. On a dead path that
    /// is a sign it works again (the peer's upgrade spray, a network that
    /// came back): probe it now rather than at the dead path's 30 s turn.
    pub fn heard(&mut self, route: Route, now: Instant) {
        let Some(entry) = self.entries.iter_mut().find(|entry| entry.route == route) else { return };
        entry.watch.heard();
        if self.selector.path(entry.id).is_some_and(|view| view.state == PathState::Dead) {
            entry.watch.probe_now(now);
        }
    }

    /// The answer to probe `probe` of path `id` arrived.
    pub fn on_pong(&mut self, id: PathId, probe: u64, now: Instant) {
        let config = self.probes;
        let Some(entry) = self.entries.iter_mut().find(|entry| entry.id == id) else { return };
        if let Some(rtt_us) = entry.watch.answer(&config, probe, now) {
            // An answer also says the path is not silent.
            entry.watch.heard();
            let _ = self.selector.on_probe(id, ProbeOutcome::Answered { rtt_us });
        }
    }

    /// The probes due at `now`, after applying lost probes and silences.
    pub fn poll(&mut self, now: Instant) -> DueProbes {
        let upgrade_next = self.upgrade_probes(now);
        let current = self.selector.current();
        let chosen = self.selector.chosen();
        let mut due = DueProbes::default();
        let mut lost = Vec::new();
        let mut silent = Vec::new();
        let config = self.probes;
        // Backgrounded with a current path that answers: the standbys rest
        // (their probes come due again in front, or when it goes quiet).
        let standbys_rest = self.backgrounded.load(Ordering::Relaxed)
            && current
                .and_then(|id| self.selector.path(id))
                .is_some_and(|view| view.state == PathState::Alive);
        for entry in &mut self.entries {
            let Some(view) = self.selector.path(entry.id) else { continue };
            let roles = (current == Some(entry.id), chosen == Some(entry.id));
            if standbys_rest
                && !roles.0
                && !roles.1
                && !matches!(view.state, PathState::Probing | PathState::Suspect)
            {
                continue;
            }
            let step = entry.watch.step(&config, &view, roles, &mut self.last_probe_id, now);
            if step.lost {
                lost.push(entry.id);
            }
            if step.silent {
                silent.push(entry.id);
            }
            if let Some(probe) = step.ping {
                due.pings.push((entry.id, probe));
            }
            due.next = match (due.next, step.next) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
        }
        for id in lost {
            let _ = self.selector.on_probe(id, ProbeOutcome::Lost);
        }
        let chosen_quiet = chosen.is_some_and(|id| silent.contains(&id));
        for id in silent {
            tracing::debug!(route = ?self.route_of(id), "WireGuard route went quiet; sending on every route");
            let _ = self.selector.on_silence(id);
        }
        // The path we sent on lost its standing in this poll, by silence or
        // by a lost probe. Above about 250 ms of RTT the probe's 1 s timeout
        // comes before the silence deadline (four round trips and an
        // unanswered probe), so a lost probe is how such a path turns
        // suspect, and the fallback needs the same fresh answers.
        let left_current = current.is_some() && self.selector.current() != current;
        if chosen_quiet || left_current {
            // The other paths were last heard up to a 30 s probe ago, and the
            // cut that silenced the chosen one may have taken them too (one
            // Wi-Fi carries the LAN and the routed address): probe them all
            // now, so the fallback is a path that answers today.
            for entry in &mut self.entries {
                if Some(entry.id) != chosen {
                    entry.watch.probe_now(now);
                }
            }
            due.next = Some(now);
        }
        if let Some(at) = upgrade_next {
            due.next = Some(due.next.map_or(at, |next| next.min(at)));
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use super::*;

    fn udp(addr: &str) -> Route {
        Route { carrier: Carrier::Udp, addr: addr.parse::<SocketAddr>().unwrap() }
    }

    fn turn(addr: &str) -> Route {
        Route { carrier: Carrier::Turn, addr: addr.parse::<SocketAddr>().unwrap() }
    }

    fn paths_on(networks: Vec<LocalNetwork>) -> Paths {
        let mut paths = Paths::new();
        paths.networks = networks;
        paths
    }

    fn lan_table() -> Vec<LocalNetwork> {
        vec![
            LocalNetwork { interface: "en0".into(), address: "192.168.1.20".parse().unwrap(), prefix: 24 },
            LocalNetwork { interface: "utun4".into(), address: "100.70.1.2".parse().unwrap(), prefix: 32 },
        ]
    }

    /// Answer every outstanding probe, `rtt` after it left.
    fn answer_all(paths: &mut Paths, at: Instant, rtt: std::time::Duration) -> Instant {
        let due = paths.poll(at);
        for (id, probe) in due.pings {
            paths.on_pong(id, probe, at + rtt);
        }
        at + rtt
    }

    /// The relay answers, the LAN path never does: it dies, the relay carries.
    /// Returns when, and the LAN path's id.
    fn relayed_with_a_dead_lan(paths: &mut Paths, lan: Route, relay: Route) -> (Instant, PathId) {
        paths.sync(&[Wanted { route: lan, relayed: false }, Wanted { route: relay, relayed: true }]);
        let mut now = Instant::now();
        for _ in 0..80 {
            let due = paths.poll(now);
            for (id, probe) in due.pings {
                if paths.route_of(id) == Some(relay) {
                    paths.on_pong(id, probe, now + std::time::Duration::from_millis(20));
                }
            }
            now += std::time::Duration::from_millis(100);
        }
        let id = paths.entries.iter().find(|entry| entry.route == lan).unwrap().id;
        assert_eq!(paths.current(), Some(relay));
        assert_eq!(paths.selector.path(id).unwrap().state, PathState::Dead);
        (now, id)
    }

    /// Pings for `id` over `span` in 50 ms steps (the others answered), `busy`
    /// marking data sent at every step.
    fn pings_for(
        paths: &mut Paths,
        id: PathId,
        from: Instant,
        span: std::time::Duration,
        busy: bool,
    ) -> usize {
        let mut now = from;
        let mut count = 0;
        while now < from + span {
            if busy {
                paths.sent_data(now);
            }
            // The relay answers; the dead path does not.
            for (ping, probe) in paths.poll(now).pings {
                if ping == id {
                    count += 1;
                } else {
                    paths.on_pong(ping, probe, now + std::time::Duration::from_millis(20));
                }
            }
            now += std::time::Duration::from_millis(50);
        }
        count
    }

    #[test]
    fn a_dead_direct_path_is_probed_often_while_a_busy_session_rides_the_relay() {
        let mut paths = paths_on(lan_table());
        let (lan, relay) = (udp("192.168.1.30:4100"), turn("203.0.113.9:4100"));
        let (now, id) = relayed_with_a_dead_lan(&mut paths, lan, relay);
        // Idle (keepalives only): the dead path keeps its 30 s turn.
        let idle = pings_for(&mut paths, id, now, std::time::Duration::from_secs(6), false);
        assert!(idle <= 1, "idle: {idle} probes in 6 s");
        // Busy: about one probe per UPGRADE_PROBE_EVERY.
        let later = now + std::time::Duration::from_secs(6);
        let busy = pings_for(&mut paths, id, later, std::time::Duration::from_secs(6), true);
        assert!((6..=9).contains(&busy), "busy: {busy} probes in 6 s");
    }

    #[test]
    fn a_backgrounded_phone_sends_no_upgrade_probes() {
        static BACKGROUNDED: AtomicBool = AtomicBool::new(false);
        let mut paths = paths_on(lan_table());
        paths.backgrounded = &BACKGROUNDED;
        let (lan, relay) = (udp("192.168.1.30:4100"), turn("203.0.113.9:4100"));
        let (now, id) = relayed_with_a_dead_lan(&mut paths, lan, relay);
        BACKGROUNDED.store(true, Ordering::Relaxed);
        // Busy but backgrounded: the dead path keeps its 30 s turn.
        let background = pings_for(&mut paths, id, now, std::time::Duration::from_secs(6), true);
        assert!(background <= 1, "backgrounded: {background} probes in 6 s");
        // Back in front: the upgrade probes resume at once.
        BACKGROUNDED.store(false, Ordering::Relaxed);
        let later = now + std::time::Duration::from_secs(6);
        let front = pings_for(&mut paths, id, later, std::time::Duration::from_secs(6), true);
        assert!((6..=9).contains(&front), "foreground: {front} probes in 6 s");
    }

    /// Probes for `id` over `span` in 100 ms steps; every path answers but
    /// the ones in `quiet`.
    fn probes_to(
        paths: &mut Paths,
        id: PathId,
        from: Instant,
        span: std::time::Duration,
        quiet: &[PathId],
    ) -> usize {
        let mut now = from;
        let mut count = 0;
        while now < from + span {
            for (ping, probe) in paths.poll(now).pings {
                count += usize::from(ping == id);
                if !quiet.contains(&ping) {
                    paths.on_pong(ping, probe, now + std::time::Duration::from_millis(20));
                }
            }
            now += std::time::Duration::from_millis(100);
        }
        count
    }

    #[test]
    fn standbys_stay_warm_in_front_and_rest_in_the_background() {
        static BACKGROUNDED: AtomicBool = AtomicBool::new(false);
        let mut paths = paths_on(lan_table());
        paths.backgrounded = &BACKGROUNDED;
        let (lan, relay) = (udp("192.168.1.30:4100"), turn("203.0.113.9:4100"));
        paths.sync(&[Wanted { route: lan, relayed: false }, Wanted { route: relay, relayed: true }]);
        let start = Instant::now();
        let id = |paths: &Paths, route| paths.entries.iter().find(|entry| entry.route == route).unwrap().id;
        let (lan_id, relay_id) = (id(&paths, lan), id(&paths, relay));
        probes_to(&mut paths, relay_id, start, std::time::Duration::from_secs(2), &[]);
        assert_eq!(paths.current(), Some(lan));
        // In front: the relay standby hears a probe every WARM_EVERY.
        let minute = std::time::Duration::from_secs(60);
        let warm = probes_to(&mut paths, relay_id, start + std::time::Duration::from_secs(2), minute, &[]);
        assert!((2..=3).contains(&warm), "in front: {warm} standby probes in 60 s");
        // Backgrounded, the LAN answering: the standby rests.
        BACKGROUNDED.store(true, Ordering::Relaxed);
        let at = start + std::time::Duration::from_secs(62);
        let resting = probes_to(&mut paths, relay_id, at, minute, &[]);
        assert_eq!(resting, 0, "backgrounded: {resting} standby probes in 60 s");
        // The LAN goes quiet: the relay is probed again and takes over.
        let at = at + minute;
        let failover = probes_to(&mut paths, relay_id, at, std::time::Duration::from_secs(10), &[lan_id]);
        assert!(failover >= 1, "no probe to the standby after the current path went quiet");
        // It answered, so the spray that follows the quiet path reaches the
        // peer through it.
        assert_eq!(paths.selector.path(relay_id).unwrap().state, PathState::Alive);
        assert_ne!(paths.current(), Some(lan));
        BACKGROUNDED.store(false, Ordering::Relaxed);
    }

    #[test]
    fn the_first_answer_of_a_dead_direct_path_takes_the_session_from_the_relay() {
        let mut paths = paths_on(lan_table());
        let (lan, relay) = (udp("192.168.1.30:4100"), turn("203.0.113.9:4100"));
        let (now, id) = relayed_with_a_dead_lan(&mut paths, lan, relay);
        paths.sent_data(now);
        let due = paths.poll(now);
        let (_, probe) = *due.pings.iter().find(|(ping, _)| *ping == id).expect("an upgrade probe at once");
        paths.on_pong(id, probe, now + std::time::Duration::from_millis(3));
        assert_eq!(paths.current(), Some(lan));
    }

    #[test]
    fn the_lan_address_wins_over_the_tailnet_and_the_relay() {
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        let tailnet = udp("100.80.2.3:4100");
        let relay = turn("203.0.113.9:4100");
        paths.sync(&[
            Wanted { route: tailnet, relayed: false },
            Wanted { route: relay, relayed: true },
            Wanted { route: lan, relayed: false },
        ]);
        assert_eq!(paths.current(), None, "nothing answered yet: the route rules decide");
        assert!(!paths.drives());
        answer_all(&mut paths, Instant::now(), std::time::Duration::from_millis(5));
        assert_eq!(paths.current(), Some(lan));
        assert!(paths.drives());
    }

    #[test]
    fn a_quiet_route_sprays_then_falls_back_to_the_relay() {
        let ms = std::time::Duration::from_millis;
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        let relay = turn("203.0.113.9:4100");
        paths.sync(&[Wanted { route: lan, relayed: false }, Wanted { route: relay, relayed: true }]);
        let cut = answer_all(&mut paths, Instant::now(), ms(2));
        assert_eq!(paths.current(), Some(lan));
        // The LAN is cut: datagrams go out on it, nothing comes back.
        paths.sent(lan, cut);
        let (mut sprayed_at, mut relay_at) = (None, None);
        let mut now = cut;
        for _ in 0..800 {
            now += ms(10);
            let due = paths.poll(now);
            for (id, probe) in due.pings {
                // Only the relay answers.
                if paths.route_of(id) == Some(relay) {
                    paths.on_pong(id, probe, now);
                }
            }
            if sprayed_at.is_none() && paths.suspect() {
                sprayed_at = Some(now);
            }
            if paths.current() == Some(relay) {
                relay_at = Some(now);
                break;
            }
        }
        let sprayed = sprayed_at.expect("the quiet route turns suspect").duration_since(cut);
        assert!(sprayed <= ms(250), "sprays {sprayed:?} after the cut, not at the 14 s silence");
        let relay = relay_at.expect("the relay takes over once the LAN path dies").duration_since(cut);
        assert!(relay <= std::time::Duration::from_secs(5), "relay after {relay:?}");
    }

    #[test]
    fn a_cut_that_takes_every_direct_path_falls_back_to_the_relay_not_a_stale_one() {
        let ms = std::time::Duration::from_millis;
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        let tailnet = udp("100.80.2.3:4100");
        let relay = turn("203.0.113.9:4100");
        paths.sync(&[
            Wanted { route: lan, relayed: false },
            Wanted { route: tailnet, relayed: false },
            Wanted { route: relay, relayed: true },
        ]);
        let cut = answer_all(&mut paths, Instant::now(), ms(2));
        assert_eq!(paths.current(), Some(lan));
        // The Wi-Fi drops: the LAN and the tailnet address both go silent,
        // though the tailnet path answered its last (30 s) probe.
        paths.sent(lan, cut);
        let mut now = cut;
        let mut seen = vec![lan];
        for _ in 0..800 {
            now += ms(10);
            let due = paths.poll(now);
            for (id, probe) in due.pings {
                if paths.route_of(id) == Some(relay) {
                    paths.on_pong(id, probe, now);
                }
            }
            if let Some(route) = paths.current()
                && seen.last() != Some(&route)
            {
                seen.push(route);
            }
            if paths.current() == Some(relay) {
                break;
            }
        }
        assert_eq!(seen, vec![lan, relay], "never moves to the stale tailnet path");
        let relay_after = now.duration_since(cut);
        assert!(relay_after <= std::time::Duration::from_secs(5), "relay after {relay_after:?}");
    }

    #[test]
    fn a_slow_route_that_loses_a_probe_probes_the_others_at_once() {
        let ms = std::time::Duration::from_millis;
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        let tailnet = udp("100.80.2.3:4100");
        let relay = turn("203.0.113.9:4100");
        paths.sync(&[
            Wanted { route: lan, relayed: false },
            Wanted { route: tailnet, relayed: false },
            Wanted { route: relay, relayed: true },
        ]);
        // A 400 ms path: four round trips of silence outlast the 1 s probe
        // timeout, so the chosen path turns suspect by a lost probe.
        let mut now = answer_all(&mut paths, Instant::now(), ms(400));
        assert_eq!(paths.current(), Some(lan));
        let mut refreshed = None;
        let mut suspect_at = None;
        for _ in 0..1000 {
            now += ms(10);
            let due = paths.poll(now);
            if suspect_at.is_none() && paths.suspect() {
                suspect_at = Some(now);
            }
            let others: Vec<_> = due
                .pings
                .iter()
                .filter(|(id, _)| paths.route_of(*id) != Some(lan))
                .map(|(id, _)| *id)
                .collect();
            if let Some(at) = suspect_at
                && refreshed.is_none()
                && others.len() == 2
            {
                refreshed = Some(now.duration_since(at));
            }
            // Nothing answers: the LAN is cut.
            if refreshed.is_some() {
                break;
            }
        }
        let at = suspect_at.expect("the slow chosen path turns suspect");
        let refreshed = refreshed.expect("the other paths are probed after the chosen one turns suspect");
        assert!(
            refreshed <= ms(20),
            "others probed {refreshed:?} after suspicion at {at:?}, not at their 30 s turn"
        );
    }

    #[test]
    fn a_route_announced_as_relayed_later_is_ranked_as_a_relay() {
        let ms = std::time::Duration::from_millis;
        let mut paths = paths_on(lan_table());
        let wan = udp("198.51.100.20:41000");
        let new_relay = udp("203.0.113.9:50002");
        // A datagram from the peer's new relayed address came before its
        // announcement: learned as a direct address.
        paths.sync(&[Wanted { route: new_relay, relayed: false }]);
        answer_all(&mut paths, Instant::now(), ms(30));
        assert_eq!(paths.current(), Some(new_relay));
        paths.sync(&[Wanted { route: new_relay, relayed: false }, Wanted { route: wan, relayed: false }]);
        answer_all(&mut paths, Instant::now(), ms(30));
        assert_eq!(paths.current(), Some(new_relay), "the same rank: the held path stays");
        // The announcement names it relayed; the direct WAN path must win.
        paths.sync(&[Wanted { route: wan, relayed: false }, Wanted { route: new_relay, relayed: true }]);
        answer_all(&mut paths, Instant::now(), ms(5));
        assert_eq!(paths.current(), Some(wan));
        let id = paths.entries.iter().find(|entry| entry.route == new_relay).map(|entry| entry.id).unwrap();
        assert_eq!(paths.selector.path(id).map(|view| view.kind), Some(PathKind::TurnRelay));
    }

    #[test]
    fn a_route_no_longer_wanted_is_left() {
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        let relay = turn("203.0.113.9:4100");
        paths.sync(&[Wanted { route: lan, relayed: false }, Wanted { route: relay, relayed: true }]);
        answer_all(&mut paths, Instant::now(), std::time::Duration::from_millis(2));
        assert_eq!(paths.current(), Some(lan));
        paths.sync(&[Wanted { route: relay, relayed: true }]);
        assert_eq!(paths.current(), Some(relay));
        paths.forget_carrier(Carrier::Turn);
        assert_eq!(paths.current(), None);
        assert!(!paths.drives());
    }

    #[test]
    fn a_network_change_hands_the_route_back_until_paths_answer_again() {
        let mut paths = paths_on(lan_table());
        let lan = udp("192.168.1.30:4100");
        paths.sync(&[Wanted { route: lan, relayed: false }]);
        answer_all(&mut paths, Instant::now(), std::time::Duration::from_millis(2));
        assert!(paths.drives());
        paths.on_network_change();
        paths.networks = lan_table();
        assert!(!paths.drives());
        answer_all(&mut paths, Instant::now(), std::time::Duration::from_millis(2));
        assert_eq!(paths.current(), Some(lan));
    }
}
