//! One keepalive clock for the phone (Settings → Transport → Align
//! Keepalives, off by default).
//!
//! Every connection the phone holds sends its own keepalive on its own
//! timer: the link ping, WireGuard's persistent keepalive, the signaling
//! socket's ping, the presence socket's ping, the Cloud Chief socket's
//! ping and the foreground heartbeat's probe. Each timer started when its
//! connection did, so on an idle phone their packets go out at different
//! instants and the radio wakes for each.
//!
//! With alignment on, every one of them waits for a beat of one grid
//! instead: the instants that are a multiple of its period since the Unix
//! epoch. Every period is a multiple of [`BEAT`] (10 s, the WireGuard
//! keepalive's interval, which already holds NAT bindings), or of the
//! foreground probe beat (2.5 s) that divides it, so all of them fall on
//! the same instants. No period is longer than the one it replaces, so no
//! timeout or detection bound gets looser:
//!
//! | keepalive | today | aligned |
//! | --- | --- | --- |
//! | link ping ([`crate::link`]) | 15 s after the last pong | every 10 s beat |
//! | WireGuard persistent keepalive | 10 s, from the tunnel's start | off: the link ping is a tunnel datagram on the same routes every 10 s |
//! | signaling ping ([`crate::signaling`]) | 15 s, from the socket's start | every 10 s beat |
//! | presence ping (Swift `PresenceListener`) | 15 s after the last pong | every 10 s beat |
//! | Cloud Chief ping (Swift `ChiefCloudBackend`) | 25 s after the last pong | every 20 s beat |
//! | foreground probe (Swift `LinkController`) | 2.5 s after the last frame | an idle link: every 2.5 s beat; a link with traffic: as today |
//! | background probe (Swift `LinkController`) | 15 s after the last frame | an idle link: every 10 s beat |
//!
//! The grid is anchored on the wall clock so the Swift timers (which ask
//! [`delay_to_beat`] through the FFI) and the Rust ones share it, and a Mac
//! on the same grid would line up too. Only the phone turns it on
//! ([`set_aligned`]); the Mac host never does.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::time::Instant;

/// The aligned keepalive period of the link and the sockets: the WireGuard
/// keepalive interval (`dial::wireguard`), so NAT bindings are refreshed as
/// often as today.
pub const BEAT: Duration = Duration::from_secs(10);
/// The Cloud Chief socket's aligned period (25 s today): two beats.
pub const CHIEF_PERIOD: Duration = Duration::from_secs(20);

static ALIGNED: AtomicBool = AtomicBool::new(false);

/// Settings → Transport → Align Keepalives. Read by each dial (the link and
/// its tunnel keep what they started with) and by each signaling keepalive
/// tick.
pub fn set_aligned(on: bool) {
    ALIGNED.store(on, Ordering::Relaxed);
}

/// The last value [`set_aligned`] stored; false until the app says.
pub fn aligned() -> bool {
    ALIGNED.load(Ordering::Relaxed)
}

/// Every period here divides this, so one anchor serves them all.
const ANCHOR_SPAN_MS: u128 = 60_000;

/// An instant that is a whole minute since the Unix epoch, on the
/// monotonic clock (taken once; wall-clock steps afterwards do not move it).
fn anchor() -> Instant {
    static ANCHOR: OnceLock<Instant> = OnceLock::new();
    *ANCHOR.get_or_init(|| {
        let now = Instant::now();
        let wall = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        let into_minute = Duration::from_millis((wall.as_millis() % ANCHOR_SPAN_MS) as u64);
        now.checked_sub(into_minute).unwrap_or(now)
    })
}

/// The first beat of `period` strictly after `after`: an instant that is a
/// whole number of `period`s from the anchor.
pub fn next_beat(after: Instant, period: Duration) -> Instant {
    next_beat_from(anchor(), after, period)
}

fn next_beat_from(anchor: Instant, after: Instant, period: Duration) -> Instant {
    let period_ns = period.as_nanos().max(1);
    if after < anchor {
        return anchor;
    }
    let elapsed = after.duration_since(anchor).as_nanos();
    let beats = elapsed / period_ns + 1;
    anchor + Duration::from_nanos(u64::try_from(beats * period_ns).unwrap_or(u64::MAX))
}

/// How long from now until the next beat of `period` (the FFI's
/// `keepalive_beat_delay_ms`, for the Swift timers).
pub fn delay_to_beat(period: Duration) -> Duration {
    let now = Instant::now();
    next_beat(now, period).duration_since(now)
}

/// When a keepalive with `period` that just fired at `now` fires next: the
/// next beat when aligned, else `period` later (today's timers).
pub fn next_tick(now: Instant, period: Duration, aligned: bool) -> Instant {
    if aligned { next_beat(now, period) } else { now + period }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn beats_of_every_period_fall_on_the_ten_second_grid() {
        let anchor = Instant::now();
        let at = |ms: u64| anchor + Duration::from_millis(ms);
        assert_eq!(next_beat_from(anchor, at(0), BEAT), at(10_000));
        assert_eq!(next_beat_from(anchor, at(9_999), BEAT), at(10_000));
        // Strictly after: a timer that fires on a beat waits for the next one.
        assert_eq!(next_beat_from(anchor, at(10_000), BEAT), at(20_000));
        assert_eq!(next_beat_from(anchor, at(10_001), CHIEF_PERIOD), at(20_000));
        assert_eq!(next_beat_from(anchor, at(1_000), Duration::from_millis(2500)), at(2_500));
        // A Chief beat is always a link beat.
        for ms in (0..600_000).step_by(1_250) {
            let chief = next_beat_from(anchor, at(ms), CHIEF_PERIOD);
            assert_eq!(chief.duration_since(anchor).as_millis() % 10_000, 0);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn next_tick_is_todays_period_unless_aligned() {
        let now = Instant::now();
        assert_eq!(next_tick(now, BEAT, false), now + BEAT);
        let aligned = next_tick(now, BEAT, true);
        assert!(aligned > now && aligned <= now + BEAT);
        assert_eq!(next_beat(aligned - Duration::from_millis(1), BEAT), aligned);
    }
}

/// Radio wakes per idle minute: every keepalive of one connected Mac plus
/// presence and Cloud Chief, today and with Align Keepalives on, on virtual
/// time (milliseconds). Each timer follows the rule its code has (cited per
/// source); the periods are the code's own constants. A wake is an outbound
/// packet more than [`WAKE_WINDOW_MS`] after the phone's previous one, so a
/// reply that leaves within a round trip (a `reach` for a pong, a delayed
/// TCP ACK) shares its wake.
#[cfg(test)]
mod wake_budget {
    use std::collections::BTreeMap;

    use super::{BEAT, CHIEF_PERIOD};
    use crate::dial::wireguard::{KEEPALIVE_SECONDS, MARKER_INTERVAL};
    use crate::link::LinkConfig;
    use crate::signaling::KEEPALIVE_INTERVAL as SIGNALING_INTERVAL;

    const WAKE_WINDOW_MS: u64 = 250;
    /// Phone to Mac and back over the tunnel, and phone to the service.
    const LINK_RTT_MS: u64 = 40;
    const SERVICE_RTT_MS: u64 = 30;
    /// Swift `LinkController.heartbeat` / `backgroundHeartbeat`.
    const FOREGROUND_BEAT_MS: u64 = 2_500;
    const BACKGROUND_BEAT_MS: u64 = 15_000;
    /// Swift `PresenceListener.pingInterval`, `ChiefCloudBackend.keepAlive`.
    const PRESENCE_MS: u64 = 15_000;
    const CHIEF_MS: u64 = 25_000;
    /// webrtc-rs `turn` 0.17: permissions every 120 s, the allocation at
    /// half its 600 s lifetime. Not aligned (inside the crate).
    const TURN_PERMS_MS: u64 = 120_000;
    const TURN_ALLOC_MS: u64 = 300_000;
    const RUN_MS: u64 = 600_000;

    fn ms(duration: std::time::Duration) -> u64 {
        u64::try_from(duration.as_millis()).unwrap()
    }

    /// [`super::next_beat`] in milliseconds from an anchor at 0.
    fn beat_after(t: u64, period: u64) -> u64 {
        (t / period + 1) * period
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Side {
        Phone,
        Mac,
        Service,
    }

    #[derive(Clone, Copy)]
    enum Msg {
        /// A link ping; `probe` marks the phone heartbeat's.
        LinkPing {
            probe: bool,
        },
        LinkPong {
            probe: bool,
        },
        /// Any other tunnel datagram (a WireGuard keepalive, a `reach`).
        Datagram,
        /// A socket ping to the service, answered with a pong to `socket`.
        SocketPing {
            socket: usize,
        },
        SocketPong {
            socket: usize,
        },
    }

    struct Scenario {
        phone_aligned: bool,
        mac_aligned: bool,
        background: bool,
        seed: u64,
    }

    /// Phases: connections opened at different moments, like a real launch.
    fn phases(seed: u64) -> impl FnMut(u64) -> u64 {
        let mut state = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        move |below| {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (state >> 33) % below
        }
    }

    /// Wakes per minute of the phone's radio over one run.
    fn wakes_per_minute(scenario: &Scenario) -> f64 {
        let mut phase = phases(scenario.seed);
        let rtt = LINK_RTT_MS;
        let half = rtt / 2;
        let wg_ka = u64::from(KEEPALIVE_SECONDS) * 1000;
        let marker = ms(MARKER_INTERVAL);
        let link_ka_today = ms(LinkConfig::default().keepalive.unwrap());
        let link_ka_aligned = ms(LinkConfig::aligned().keepalive.unwrap());
        let beat = ms(BEAT);
        let heartbeat = if scenario.background { BACKGROUND_BEAT_MS } else { FOREGROUND_BEAT_MS };
        // With alignment the background heartbeat keeps the 10 s beat (never
        // longer than today's 15 s); the foreground one keeps 2.5 s.
        let aligned_heartbeat = if scenario.background { beat } else { FOREGROUND_BEAT_MS };

        let mut sent: Vec<u64> = Vec::new();
        let mut queue: BTreeMap<(u64, u64), (Side, Msg)> = BTreeMap::new();
        let mut seq = 0u64;
        let mut post = |queue: &mut BTreeMap<(u64, u64), (Side, Msg)>, at: u64, to: Side, msg: Msg| {
            seq += 1;
            queue.insert((at, seq), (to, msg));
        };

        // Phone link state (cmux-mobile-link `link.rs`, Swift `LinkController`).
        let mut last_frame = 0u64;
        let mut hb_wake = heartbeat;
        let mut probe_out = false;
        let mut phone_ka_next =
            if scenario.phone_aligned { beat_after(0, link_ka_aligned) } else { link_ka_today };
        let mut phone_ka_waiting = false;
        // WireGuard persistent keepalive (boringtun, from each tunnel's start).
        let mut phone_wg_next = (!scenario.phone_aligned).then(|| phase(wg_ka) + wg_ka);
        let mut mac_wg_next = (!scenario.mac_aligned).then(|| phase(wg_ka) + wg_ka);
        let mut last_marker = [0u64; 2];
        // The Mac's link keepalive (`LinkConfig::default()` on cmux-mobile-host).
        let mut mac_ka_next = if scenario.mac_aligned {
            beat_after(0, link_ka_aligned)
        } else {
            phase(link_ka_today) + link_ka_today
        };
        let mut mac_ka_waiting = false;
        // Sockets: 0 signaling (fixed rate), 1 presence, 2 Chief (after the pong).
        let mut socket_next = [phase(ms(SIGNALING_INTERVAL)), phase(PRESENCE_MS), phase(CHIEF_MS)];
        let mut turn_next = [phase(TURN_PERMS_MS), phase(TURN_ALLOC_MS)];

        let mut t = 0u64;
        while t < RUN_MS {
            // Arrivals due now.
            while let Some((&(at, key), _)) = queue.iter().next() {
                if at > t {
                    break;
                }
                let (to, msg) = queue.remove(&(at, key)).unwrap();
                match (to, msg) {
                    (Side::Phone, Msg::LinkPing { .. }) => {
                        last_frame = t;
                        sent.push(t);
                        post(&mut queue, t + half, Side::Mac, Msg::LinkPong { probe: false });
                    }
                    (Side::Phone, Msg::LinkPong { probe }) => {
                        last_frame = t;
                        if probe {
                            probe_out = false;
                        } else if phone_ka_waiting {
                            phone_ka_waiting = false;
                            if !scenario.phone_aligned {
                                phone_ka_next = t + link_ka_today;
                            }
                        }
                    }
                    (Side::Mac, Msg::LinkPing { probe }) => {
                        post(&mut queue, t + half, Side::Phone, Msg::LinkPong { probe });
                    }
                    (Side::Mac, Msg::LinkPong { .. }) => {
                        if mac_ka_waiting {
                            mac_ka_waiting = false;
                            if !scenario.mac_aligned {
                                mac_ka_next = t + link_ka_today;
                            }
                        }
                    }
                    (Side::Phone | Side::Mac, Msg::Datagram) => {}
                    (Side::Service, Msg::SocketPing { socket }) => {
                        post(&mut queue, t + SERVICE_RTT_MS / 2, Side::Phone, Msg::SocketPong { socket });
                    }
                    (Side::Phone, Msg::SocketPong { socket }) => {
                        // Presence and Chief wait their interval after the pong.
                        if socket > 0 {
                            let period = if socket == 1 { PRESENCE_MS } else { CHIEF_MS };
                            socket_next[socket] = if scenario.phone_aligned {
                                beat_after(t, if socket == 1 { beat } else { ms(CHIEF_PERIOD) })
                            } else {
                                t + period
                            };
                        }
                    }
                    _ => {}
                }
                // `reach`: each tunnel datagram that arrives draws one, at
                // most every MARKER_INTERVAL (wireguard.rs).
                if matches!(msg, Msg::LinkPing { .. } | Msg::LinkPong { .. } | Msg::Datagram)
                    && matches!(to, Side::Phone | Side::Mac)
                {
                    let index = usize::from(to == Side::Mac);
                    if t >= last_marker[index] + marker {
                        last_marker[index] = t;
                        let other = if to == Side::Phone { Side::Mac } else { Side::Phone };
                        if to == Side::Phone {
                            sent.push(t);
                        }
                        post(&mut queue, t + half, other, Msg::Datagram);
                    }
                }
            }

            // The phone heartbeat (Swift `LinkController.startHeartbeat`).
            if t >= hb_wake {
                let quiet = t - last_frame;
                let interval = if scenario.phone_aligned { aligned_heartbeat } else { heartbeat };
                if scenario.phone_aligned {
                    // Probe a link quiet for a beat, or an idle one (no
                    // traffic, only keepalives) on the beat.
                    let on_beat = t % interval == 0;
                    if !probe_out && (quiet >= interval || on_beat) {
                        probe_out = true;
                        sent.push(t);
                        post(&mut queue, t + half, Side::Mac, Msg::LinkPing { probe: true });
                    }
                    let mut next = beat_after(t, interval);
                    if last_frame + interval > t {
                        next = next.min(last_frame + interval);
                    }
                    hb_wake = next;
                } else if quiet < interval {
                    hb_wake = last_frame + interval;
                } else {
                    if !probe_out {
                        probe_out = true;
                        sent.push(t);
                        post(&mut queue, t + half, Side::Mac, Msg::LinkPing { probe: true });
                    }
                    hb_wake = t + interval;
                }
            }
            // The phone link keepalive.
            if t >= phone_ka_next && (scenario.phone_aligned || !phone_ka_waiting) {
                sent.push(t);
                phone_ka_waiting = true;
                post(&mut queue, t + half, Side::Mac, Msg::LinkPing { probe: false });
                phone_ka_next =
                    if scenario.phone_aligned { beat_after(t, link_ka_aligned) } else { u64::MAX };
            }
            // The Mac link keepalive.
            if t >= mac_ka_next && (scenario.mac_aligned || !mac_ka_waiting) {
                mac_ka_waiting = true;
                post(&mut queue, t + half, Side::Phone, Msg::LinkPing { probe: false });
                mac_ka_next = if scenario.mac_aligned { beat_after(t, link_ka_aligned) } else { u64::MAX };
            }
            // WireGuard persistent keepalives.
            if let Some(next) = phone_wg_next
                && t >= next
            {
                sent.push(t);
                post(&mut queue, t + half, Side::Mac, Msg::Datagram);
                phone_wg_next = Some(next + wg_ka);
            }
            if let Some(next) = mac_wg_next
                && t >= next
            {
                post(&mut queue, t + half, Side::Phone, Msg::Datagram);
                mac_wg_next = Some(next + wg_ka);
            }
            // Signaling (fixed rate), presence and Chief (after their pong).
            for socket in 0..3 {
                if t >= socket_next[socket] {
                    sent.push(t);
                    post(&mut queue, t + SERVICE_RTT_MS / 2, Side::Service, Msg::SocketPing { socket });
                    socket_next[socket] = if socket == 0 {
                        if scenario.phone_aligned { beat_after(t, beat) } else { t + ms(SIGNALING_INTERVAL) }
                    } else {
                        u64::MAX
                    };
                }
            }
            for (index, period) in [TURN_PERMS_MS, TURN_ALLOC_MS].into_iter().enumerate() {
                if t >= turn_next[index] {
                    sent.push(t);
                    turn_next[index] += period;
                }
            }
            t += 1;
        }

        sent.sort_unstable();
        let mut wakes = 0u64;
        let mut last: Option<u64> = None;
        for at in sent {
            if last.is_none_or(|last| at > last + WAKE_WINDOW_MS) {
                wakes += 1;
            }
            last = Some(at);
        }
        wakes as f64 * 60_000.0 / RUN_MS as f64
    }

    fn summary(phone_aligned: bool, mac_aligned: bool, background: bool) -> (f64, f64, f64) {
        let runs: Vec<f64> = (1..=8)
            .map(|seed| wakes_per_minute(&Scenario { phone_aligned, mac_aligned, background, seed }))
            .collect();
        let mean = runs.iter().sum::<f64>() / runs.len() as f64;
        let min = runs.iter().copied().fold(f64::MAX, f64::min);
        let max = runs.iter().copied().fold(0.0, f64::max);
        (mean, min, max)
    }

    #[test]
    fn the_millisecond_grid_is_the_code_grid() {
        let anchor = tokio::time::Instant::now();
        for t in (0..120_000u64).step_by(37) {
            for period in [FOREGROUND_BEAT_MS, ms(BEAT), ms(CHIEF_PERIOD)] {
                let code = super::next_beat_from(
                    anchor,
                    anchor + std::time::Duration::from_millis(t),
                    std::time::Duration::from_millis(period),
                );
                assert_eq!(code.duration_since(anchor).as_millis(), u128::from(beat_after(t, period)));
            }
        }
    }

    /// The number for the proposal (cmux#42818). Prints one row per case.
    #[test]
    fn radio_wakes_per_idle_minute() {
        let mut rows = Vec::new();
        for background in [false, true] {
            let today = summary(false, false, background);
            let phone = summary(true, false, background);
            let both = summary(true, true, background);
            let state = if background { "background (Chief call)" } else { "foreground" };
            for (label, (mean, min, max)) in
                [("today", today), ("setting on", phone), ("setting on, Mac aligned too", both)]
            {
                rows.push(format!("{state:<24} {label:<28} {mean:>5.1} wakes/min ({min:.1}-{max:.1})"));
            }
            assert!(phone.0 < today.0, "{state}: aligned {phone:?} not below today {today:?}");
            assert!(both.0 <= phone.0, "{state}: Mac aligned {both:?} above phone only {phone:?}");
        }
        eprintln!("radio wakes per idle minute (8 phase sets, 10 min each):\n{}", rows.join("\n"));
    }
}
