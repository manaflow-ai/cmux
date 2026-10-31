//! The Mac's media routes (verify/hybrid-link.md): one lane may have more
//! than one carrier for the same video. On a WireGuard link with a media
//! session the lane has two: the WebRTC media session's video track
//! (preferred: libwebrtc-grade ICE paths, SRTP, its own congestion) and RTP
//! on overlay UDP inside the tunnel (the floor, always there while the link
//! is). Each route runs its own sender core; frames go to one at a time.
//!
//! Choosing a route is pure ([`Table`]): the preferred usable route wins. A
//! route is usable while its sender runs, its carrier reports healthy (the
//! media session's peer connection is connected) and it is not waiting out
//! a stall. A stall is a route that is current, has packets out and has
//! heard no TWCC feedback for [`STALL`]: video moves to the next route and
//! the stalled one is tried again after a backoff (1 s, doubling to 16 s).
//!
//! A switch happens only at a keyframe, so the phone's decoder never gets a
//! frame whose reference went the other way. While the old route still
//! works its frames keep flowing until the keyframe; while it does not, the
//! frames in between are dropped (the phone keeps showing the last one) and
//! the source is asked for a keyframe at once.

use std::time::{Duration, Instant};

use tokio::sync::{mpsc, watch};

use super::{CarrierKind, OutgoingFrame, SenderState};

/// A current route with packets out and no feedback for this long has
/// stalled (TWCC feedback comes every 25 ms on a working path).
pub const STALL: Duration = Duration::from_millis(500);
/// How long a stalled route waits before it is tried again, at first and at most.
pub const STALL_BACKOFF_MIN: Duration = Duration::from_secs(1);
pub const STALL_BACKOFF_MAX: Duration = Duration::from_secs(16);
/// A route that stays current and answered this long starts over at the
/// shortest backoff.
const STALL_FORGIVEN: Duration = Duration::from_secs(10);
/// Shortest time between two keyframe requests for a switch.
const SWITCH_KEYFRAME_INTERVAL: Duration = Duration::from_millis(250);

/// Lower is preferred.
pub(crate) fn rank(kind: CarrierKind) -> u8 {
    match kind {
        CarrierKind::WebRtcTrack => 0,
        CarrierKind::WireGuardUdp => 1,
    }
}

pub(crate) struct Route {
    pub id: u64,
    pub kind: CarrierKind,
    pub rank: u8,
    pub frames: mpsc::Sender<(u64, OutgoingFrame)>,
    pub state: watch::Receiver<SenderState>,
    pub health: watch::Receiver<bool>,
    /// Not tried again before this (a stall).
    pub retry_at: Option<Instant>,
    pub backoff: Duration,
}

impl Route {
    fn alive(&self) -> bool {
        !self.frames.is_closed()
    }

    fn usable(&self, now: Instant) -> bool {
        self.alive() && *self.health.borrow() && self.retry_at.is_none_or(|at| now >= at)
    }
}

/// What to do with one frame.
#[derive(Debug)]
pub(crate) enum Decision {
    Send {
        #[cfg_attr(not(test), allow(dead_code))]
        route: u64,
        frames: mpsc::Sender<(u64, OutgoingFrame)>,
    },
    /// Drop it: the route it would go on is gone and the next route needs a
    /// keyframe first.
    Drop,
    /// No route left: the lane is closed.
    Closed,
}

/// A route change for the logs and labels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Switch {
    pub from: Option<CarrierKind>,
    pub to: CarrierKind,
}

#[derive(Default)]
pub(crate) struct Table {
    pub routes: Vec<Route>,
    pub current: Option<u64>,
    /// Since when the current route has been current.
    pub current_since: Option<Instant>,
    /// A frame went out: from now on a switch waits for a keyframe.
    pub started: bool,
    pub next_id: u64,
    last_keyframe_ask: Option<Instant>,
    /// When the current route last answered with feedback after a stall-free stretch began.
    answered_since: Option<Instant>,
}

impl Table {
    pub fn route(&self, id: u64) -> Option<&Route> {
        self.routes.iter().find(|r| r.id == id)
    }

    fn route_mut(&mut self, id: u64) -> Option<&mut Route> {
        self.routes.iter_mut().find(|r| r.id == id)
    }

    pub fn add(
        &mut self,
        kind: CarrierKind,
        frames: mpsc::Sender<(u64, OutgoingFrame)>,
        state: watch::Receiver<SenderState>,
        health: watch::Receiver<bool>,
    ) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.routes.push(Route {
            id,
            kind,
            rank: rank(kind),
            frames,
            state,
            health,
            retry_at: None,
            backoff: STALL_BACKOFF_MIN,
        });
        id
    }

    pub fn remove(&mut self, id: u64) {
        self.routes.retain(|r| r.id != id);
    }

    /// Whether any route can still carry video.
    pub fn alive(&self) -> bool {
        self.routes.iter().any(Route::alive)
    }

    /// The route frames should go on now.
    pub fn target(&self, now: Instant) -> Option<u64> {
        self.routes.iter().filter(|r| r.usable(now)).min_by_key(|r| r.rank).map(|r| r.id)
    }

    pub fn current_usable(&self, now: Instant) -> bool {
        self.current.and_then(|id| self.route(id)).is_some_and(|r| r.usable(now))
    }

    pub fn current_kind(&self) -> Option<CarrierKind> {
        self.current.and_then(|id| self.route(id)).map(|r| r.kind)
    }

    /// The route whose state the source should follow: the current one while
    /// it works, else the one video moves to next.
    pub fn shown(&self, now: Instant) -> Option<u64> {
        if self.current_usable(now) { self.current } else { self.target(now) }
    }

    /// Whether to ask the source for a keyframe now (rate limited).
    fn ask_keyframe(&mut self, now: Instant) -> bool {
        let due = self.last_keyframe_ask.is_none_or(|at| now.duration_since(at) >= SWITCH_KEYFRAME_INTERVAL);
        if due {
            self.last_keyframe_ask = Some(now);
        }
        due
    }

    /// A switch is due: the source should make a keyframe (rate limited).
    pub fn switch_keyframe(&mut self, now: Instant) -> bool {
        let pending = self.started && self.target(now).is_some_and(|t| Some(t) != self.current);
        pending && self.ask_keyframe(now)
    }

    /// Where one frame goes, and whether to ask for a keyframe. Moves the
    /// current route when the frame lets it.
    pub fn decide(&mut self, keyframe: bool, now: Instant) -> (Decision, bool, Option<Switch>) {
        let Some(target) = self.target(now) else {
            return (if self.alive() { Decision::Drop } else { Decision::Closed }, false, None);
        };
        if !self.started || self.current == Some(target) || (keyframe && self.current != Some(target)) {
            let switch = (self.current != Some(target)).then(|| Switch {
                from: self.current_kind(),
                to: self.route(target).map_or(CarrierKind::WireGuardUdp, |r| r.kind),
            });
            if switch.is_some() {
                self.current = Some(target);
                self.current_since = Some(now);
                self.answered_since = None;
            }
            self.started = true;
            let frames = self.route(target).map(|r| r.frames.clone()).expect("target exists");
            return (Decision::Send { route: target, frames }, false, switch);
        }
        // A better (or the only working) route waits for a keyframe.
        let ask = self.ask_keyframe(now);
        if self.current_usable(now) {
            let id = self.current.expect("usable current");
            let frames = self.route(id).map(|r| r.frames.clone()).expect("current exists");
            (Decision::Send { route: id, frames }, ask, None)
        } else {
            (Decision::Drop, ask, None)
        }
    }

    /// Applies the current route's state: marks it stalled (and returns
    /// true) when its packets have gone unanswered too long and another
    /// route could take the video.
    pub fn check_stall(&mut self, now: Instant) -> bool {
        let Some(id) = self.current else { return false };
        let since = self.current_since.unwrap_or(now);
        let Some(rank) = self.route(id).map(|r| r.rank) else { return false };
        // Only a route with a floor below it stalls away: the floor (the
        // tunnel) carries on whatever its feedback says.
        let fallback =
            self.routes.iter().any(|r| r.id != id && r.rank > rank && r.alive() && *r.health.borrow());
        let Some(route) = self.route_mut(id) else { return false };
        let state = *route.state.borrow();
        let waiting = Duration::from_micros(state.feedback_wait_us);
        if fallback
            && waiting >= STALL
            && now.duration_since(since) >= STALL
            && route.retry_at.is_none_or(|at| now >= at)
        {
            route.retry_at = Some(now + route.backoff);
            route.backoff = (route.backoff * 2).min(STALL_BACKOFF_MAX);
            self.answered_since = None;
            return true;
        }
        if waiting < STALL {
            let answered = *self.answered_since.get_or_insert(now);
            if now.duration_since(answered) >= STALL_FORGIVEN
                && let Some(route) = self.route_mut(id)
            {
                route.backoff = STALL_BACKOFF_MIN;
            }
        }
        false
    }

    /// The next time a stalled route may be tried again.
    pub fn next_retry(&self, now: Instant) -> Option<Instant> {
        self.routes.iter().filter_map(|r| r.retry_at).filter(|at| *at > now).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(wait_us: u64) -> SenderState {
        SenderState {
            target_bps: 1_000_000,
            in_flight_bytes: 0,
            congested: false,
            loss: 0.0,
            feedback_delay_us: 0,
            keyframe_requests: 0,
            packets_sent: 0,
            nacks_received: 0,
            feedback_wait_us: wait_us,
        }
    }

    struct Fixture {
        table: Table,
        webrtc_health: watch::Sender<bool>,
        webrtc_state: watch::Sender<SenderState>,
        _wg_state: watch::Sender<SenderState>,
        _rx: Vec<mpsc::Receiver<(u64, OutgoingFrame)>>,
        webrtc: u64,
        wg: u64,
    }

    fn fixture() -> Fixture {
        let mut table = Table::default();
        let (wg_tx, wg_rx) = mpsc::channel(4);
        let (wg_state, wg_state_rx) = watch::channel(state(0));
        let wg = table.add(CarrierKind::WireGuardUdp, wg_tx, wg_state_rx, watch::channel(true).1);
        let (rtc_tx, rtc_rx) = mpsc::channel(4);
        let (webrtc_state, rtc_state_rx) = watch::channel(state(0));
        let (webrtc_health, health) = watch::channel(true);
        let webrtc = table.add(CarrierKind::WebRtcTrack, rtc_tx, rtc_state_rx, health);
        Fixture {
            table,
            webrtc_health,
            webrtc_state,
            _wg_state: wg_state,
            _rx: vec![wg_rx, rtc_rx],
            webrtc,
            wg,
        }
    }

    fn sent_on(decision: &Decision) -> Option<u64> {
        match decision {
            Decision::Send { route, .. } => Some(*route),
            _ => None,
        }
    }

    #[test]
    fn the_webrtc_route_wins_and_the_first_frame_needs_no_keyframe() {
        let mut f = fixture();
        let now = Instant::now();
        let (decision, ask, switch) = f.table.decide(false, now);
        assert_eq!(sent_on(&decision), Some(f.webrtc));
        assert!(!ask);
        assert_eq!(switch, Some(Switch { from: None, to: CarrierKind::WebRtcTrack }));
    }

    #[test]
    fn a_dead_route_falls_back_only_at_a_keyframe_and_drops_frames_meanwhile() {
        let mut f = fixture();
        let now = Instant::now();
        f.table.decide(true, now);
        f.webrtc_health.send_replace(false);
        // A P frame cannot start the WireGuard route: dropped, keyframe asked.
        let (decision, ask, _) = f.table.decide(false, now);
        assert!(matches!(decision, Decision::Drop));
        assert!(ask);
        // Asked once per 250 ms.
        assert!(!f.table.decide(false, now + Duration::from_millis(10)).1);
        let (decision, _, switch) = f.table.decide(true, now + Duration::from_millis(20));
        assert_eq!(sent_on(&decision), Some(f.wg));
        assert_eq!(
            switch,
            Some(Switch { from: Some(CarrierKind::WebRtcTrack), to: CarrierKind::WireGuardUdp })
        );
    }

    #[test]
    fn a_recovered_route_takes_over_at_a_keyframe_while_the_old_one_keeps_sending() {
        let mut f = fixture();
        let now = Instant::now();
        f.webrtc_health.send_replace(false);
        f.table.decide(true, now);
        assert_eq!(f.table.current, Some(f.wg));
        f.webrtc_health.send_replace(true);
        assert!(f.table.switch_keyframe(now));
        let (decision, _, _) = f.table.decide(false, now);
        assert_eq!(sent_on(&decision), Some(f.wg), "P frames stay on the working route");
        let (decision, _, switch) = f.table.decide(true, now);
        assert_eq!(sent_on(&decision), Some(f.webrtc));
        assert!(switch.is_some());
    }

    #[test]
    fn a_stalled_route_backs_off_and_is_tried_again() {
        let mut f = fixture();
        let start = Instant::now();
        f.table.decide(true, start);
        // Unanswered for 600 ms on a route current for 600 ms: stalled.
        f.webrtc_state.send_replace(state(600_000));
        let t = start + Duration::from_millis(600);
        assert!(f.table.check_stall(t));
        assert_eq!(f.table.target(t), Some(f.wg));
        assert_eq!(f.table.next_retry(t), Some(t + STALL_BACKOFF_MIN));
        f.table.decide(true, t);
        assert_eq!(f.table.current, Some(f.wg));
        // After the backoff it is tried again; a second stall waits twice as long.
        let retry = t + STALL_BACKOFF_MIN;
        assert_eq!(f.table.target(retry), Some(f.webrtc));
        f.table.decide(true, retry);
        let t2 = retry + Duration::from_millis(600);
        assert!(f.table.check_stall(t2));
        assert_eq!(f.table.next_retry(t2), Some(t2 + STALL_BACKOFF_MIN * 2));
    }

    #[test]
    fn the_last_route_never_stalls_away() {
        let mut f = fixture();
        let now = Instant::now();
        f.webrtc_health.send_replace(false);
        f.table.decide(true, now);
        f.table.remove(f.webrtc);
        assert!(!f.table.check_stall(now + Duration::from_secs(5)));
    }

    #[test]
    fn the_floor_never_stalls_away_while_the_preferred_route_backs_off() {
        let mut f = fixture();
        let start = Instant::now();
        f.table.decide(true, start);
        f.webrtc_state.send_replace(state(600_000));
        let t = start + Duration::from_millis(600);
        assert!(f.table.check_stall(t));
        f.table.decide(true, t);
        assert_eq!(f.table.current, Some(f.wg));
        // The tunnel is slow to answer too (a backed-up TURN over TLS stream),
        // but it is the floor: it stays usable.
        f._wg_state.send_replace(state(900_000));
        let later = t + Duration::from_millis(700);
        assert!(!f.table.check_stall(later));
        assert_eq!(f.table.target(later), Some(f.wg));
    }

    #[test]
    fn no_route_left_closes_the_lane() {
        let mut table = Table::default();
        let (tx, rx) = mpsc::channel(1);
        table.add(CarrierKind::WireGuardUdp, tx, watch::channel(state(0)).1, watch::channel(true).1);
        drop(rx);
        assert!(matches!(table.decide(true, Instant::now()).0, Decision::Closed));
    }
}
