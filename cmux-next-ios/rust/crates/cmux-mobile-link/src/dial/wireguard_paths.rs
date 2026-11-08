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
use tokio::time::Instant;

use super::{Carrier, Route};

/// Selector path ids start here: below are the receive origins
/// (`UDP_PATH`, `TURN_PATH`), which a peer's probe answer names.
const FIRST_ID: u16 = 16;

struct Entry {
    id: PathId,
    route: Route,
    watch: PathWatch,
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
}

impl Paths {
    pub fn new() -> Self {
        Self {
            selector: Selector::new(SelectorConfig::default()),
            entries: Vec::new(),
            next_id: FIRST_ID,
            networks: local_networks(),
            probes: ProbeConfig::default(),
            last_probe_id: 0,
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
    /// routes no longer wanted are removed (the selector moves off them).
    pub fn sync(&mut self, wanted: &[Wanted]) {
        let gone: Vec<PathId> = self
            .entries
            .iter()
            .filter(|entry| !wanted.iter().any(|want| want.route == entry.route))
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
                    self.entries.push(Entry { id, route: want.route, watch: PathWatch::default() });
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
        let current = self.selector.current();
        let chosen = self.selector.chosen();
        let mut due = DueProbes::default();
        let mut lost = Vec::new();
        let mut silent = Vec::new();
        let config = self.probes;
        for entry in &mut self.entries {
            let Some(view) = self.selector.path(entry.id) else { continue };
            let roles = (current == Some(entry.id), chosen == Some(entry.id));
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
        for id in silent {
            tracing::debug!(route = ?self.route_of(id), "WireGuard route went quiet; sending on every route");
            let _ = self.selector.on_silence(id);
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
