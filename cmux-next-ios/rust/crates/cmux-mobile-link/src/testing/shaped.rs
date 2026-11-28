//! A phone's link offline, without a phone or a network: a named profile
//! from cmux-fault's `link-profiles.json` (the file cmux#49310's
//! `UdpShaper` plays) applied to every datagram a WireGuard tunnel
//! receives, through `DialOptions::impair_inbound`
//! ([`shape_by_profile`]). The same per-datagram model as `UdpShaper`
//! (`cmux-tui/crates/cmux-fault/src/shaper/udp.rs`):
//!
//! - **rate**: a datagram leaves after the one before it from the same
//!   sender has serialized; a backlog past the bearer's buffer (256
//!   segments of 1460 bytes) is tail-dropped;
//! - **delay and jitter**: `rtt_ms / 2` plus a seeded draw in
//!   `0..=jitter_ms`; nothing holds a datagram behind another, so jitter
//!   reorders;
//! - **loss**: dropped with `loss_percent`, never retransmitted (the link's
//!   TCP inside the tunnel recovers).
//!
//! Why not the relay itself: a WireGuard link's peers learn each other's
//! addresses from signaling and probe them directly, so there is no single
//! address a relay could stand in for; the receive hook sits on the same
//! datagrams. Each sender address is one direction of one link (its own
//! bearer); the rate is the profile's lower of `up_kbit` and `down_kbit`
//! (`lte` and both `lossy` profiles are symmetric).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use tokio::time::Instant;

/// cmux-fault's profiles, read when a harness asks for one (a hand-run
/// measurement; nothing compiles them in).
pub const LINK_PROFILES_JSON: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../cmux-tui/crates/cmux-fault/link-profiles.json");

/// One TCP segment's payload on a 1500-byte path (cmux-fault's `SEGMENT`).
const SEGMENT: usize = 1460;
/// Datagrams a direction may hold in flight (cmux-fault's `QUEUE_SEGMENTS`).
const QUEUE_SEGMENTS: usize = 256;

/// The fields of a cmux-fault `LinkProfile` this model plays.
#[derive(Debug, Clone, PartialEq)]
pub struct LinkProfile {
    pub name: String,
    pub up_kbit: u64,
    pub down_kbit: u64,
    pub rtt_ms: u64,
    pub jitter_ms: u64,
    pub loss_percent: f64,
}

impl LinkProfile {
    /// The profile `name` from [`LINK_PROFILES_JSON`]. Panics when the file
    /// or the profile is missing: a measurement must not run unshaped.
    pub fn named(name: &str) -> Self {
        let text = std::fs::read_to_string(LINK_PROFILES_JSON)
            .unwrap_or_else(|error| panic!("{LINK_PROFILES_JSON}: {error}"));
        let file: serde_json::Value =
            serde_json::from_str(&text).unwrap_or_else(|error| panic!("{LINK_PROFILES_JSON}: {error}"));
        let profile = file["profiles"]
            .as_array()
            .and_then(|profiles| profiles.iter().find(|profile| profile["name"] == name))
            .unwrap_or_else(|| panic!("{LINK_PROFILES_JSON}: no profile {name}"));
        let number = |key: &str| profile[key].as_u64().unwrap_or(0);
        Self {
            name: name.to_owned(),
            up_kbit: number("up_kbit"),
            down_kbit: number("down_kbit"),
            rtt_ms: number("rtt_ms"),
            jitter_ms: number("jitter_ms"),
            loss_percent: profile["loss_percent"].as_f64().unwrap_or(0.0),
        }
    }

    fn rate_kbit(&self) -> u64 {
        match (self.up_kbit, self.down_kbit) {
            (0, rate) | (rate, 0) => rate,
            (up, down) => up.min(down),
        }
    }

    fn serialize(&self, bytes: usize) -> Duration {
        match self.rate_kbit() {
            0 => Duration::ZERO,
            kbit => Duration::from_micros(bytes as u64 * 8 * 1000 / kbit),
        }
    }
}

/// The phone's cellular radio (LTE RRC, Huang et al., MobiSys 2012): after
/// `tail` with nothing sent or received it is idle, and the next datagram
/// waits for it to reconnect: `promote` for one the phone sends, a draw in
/// `0..paging` (the DRX paging cycle: the network waits for the phone's
/// next paging slot) plus `promote` for one it receives. Datagrams in the
/// meantime wait for the same moment. Off unless [`set_radio_model`].
///
/// Connected, the radio sleeps too (connected-mode DRX): after
/// `drx_inactivity` with nothing crossing it, it listens only once per
/// `drx_cycle`, so a datagram coming down waits for the next listening
/// slot. A zero `drx_cycle` (the default) leaves it listening throughout.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RadioModel {
    pub tail: Duration,
    pub promote: Duration,
    pub paging: Duration,
    pub drx_inactivity: Duration,
    pub drx_cycle: Duration,
}

impl RadioModel {
    /// The paper's measured LTE values: an 11.576 s tail, 260 ms promotion,
    /// a 1.28 s paging cycle, and its 100 ms DRX inactivity timer with
    /// connected-mode DRX off ([`Self::with_drx`]).
    pub fn lte() -> Self {
        Self {
            tail: Duration::from_millis(11_576),
            promote: Duration::from_millis(260),
            paging: Duration::from_millis(1280),
            drx_inactivity: Duration::from_millis(100),
            drx_cycle: Duration::ZERO,
        }
    }

    /// Connected-mode DRX with a long cycle of `cycle` (the paper's 40 ms;
    /// carriers run 40 to 320 ms).
    pub fn with_drx(self, cycle: Duration) -> Self {
        Self { drx_cycle: cycle, ..self }
    }
}

/// Which way a datagram crosses the phone's radio.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Phone to Mac: the Mac's tunnel receives it.
    Up,
    /// Mac to phone: the phone's tunnel receives it.
    Down,
}

struct Radio {
    model: RadioModel,
    /// The last moment a datagram crossed the radio.
    last_active: Option<Instant>,
    /// When the radio is connected again after its last wake.
    awake_at: Instant,
    wakes: u64,
    /// The last moment a datagram crossed the radio, on the phone's clock
    /// (one coming down crosses half a round trip after it is sent): when
    /// connected-mode DRX starts sleeping.
    on_air: Option<Instant>,
}

/// Loss that comes back on a schedule, as a Starlink dish's every 15 s
/// reconfiguration (RFD 0142 O5): for `burst` after each `period` since
/// [`set_periodic_loss`], a datagram is lost with `loss_percent`, on top of
/// the profile's own loss. Off unless set.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PeriodicLoss {
    pub period: Duration,
    pub burst: Duration,
    pub loss_percent: f64,
}

impl PeriodicLoss {
    /// `PERIOD_MS:BURST_MS:PERCENT`, as `15000:300:40`.
    pub fn parse(text: &str) -> Option<Self> {
        let mut parts = text.split(':');
        let period = Duration::from_millis(parts.next()?.trim().parse().ok()?);
        let burst = Duration::from_millis(parts.next()?.trim().parse().ok()?);
        let loss_percent: f64 = parts.next()?.trim().parse().ok()?;
        (parts.next().is_none() && !period.is_zero() && burst <= period).then_some(Self {
            period,
            burst,
            loss_percent,
        })
    }
}

struct Periodic {
    loss: PeriodicLoss,
    since: Instant,
    rng: u64,
}

struct Air {
    profile: LinkProfile,
    /// When each sender's bearer is free again.
    free_at: HashMap<SocketAddr, Instant>,
    rng: u64,
    radio: Option<Radio>,
    periodic: Option<Periodic>,
}

static AIR: Mutex<Option<Air>> = Mutex::new(None);
static DELIVERED: AtomicU64 = AtomicU64::new(0);
static DROPPED: AtomicU64 = AtomicU64::new(0);

/// Shape every tunnel dialed with [`shape_by_profile`] by `profile` from
/// now on, seeded (`None`: deliver at once). Process-wide: one profile per
/// measurement.
pub fn set_link_profile(profile: Option<LinkProfile>, seed: u64) {
    *AIR.lock().unwrap_or_else(PoisonError::into_inner) = profile.map(|profile| Air {
        profile,
        free_at: HashMap::new(),
        rng: seed,
        radio: None,
        periodic: None,
    });
    DELIVERED.store(0, Ordering::Relaxed);
    DROPPED.store(0, Ordering::Relaxed);
}

/// Play the phone's radio ([`RadioModel`]) on the profile set by
/// [`set_link_profile`] (call after it). Only datagrams shaped by
/// [`shape_uplink`] and [`shape_downlink`] cross it.
pub fn set_radio_model(model: Option<RadioModel>) {
    if let Some(air) = AIR.lock().unwrap_or_else(PoisonError::into_inner).as_mut() {
        air.radio = model.map(|model| Radio {
            model,
            last_active: None,
            awake_at: Instant::now(),
            wakes: 0,
            on_air: None,
        });
    }
}

/// Add [`PeriodicLoss`] to the profile set by [`set_link_profile`] (call
/// after it), its windows counted from now. Its draws come from their own
/// stream, so the profile's draws stay the same with it on or off.
pub fn set_periodic_loss(loss: Option<PeriodicLoss>) {
    if let Some(air) = AIR.lock().unwrap_or_else(PoisonError::into_inner).as_mut() {
        air.periodic = loss.map(|loss| Periodic { loss, since: Instant::now(), rng: air.rng ^ 0x0e5d_0000 });
    }
}

/// Times the radio woke from idle since [`set_radio_model`].
pub fn radio_wakes() -> u64 {
    AIR.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .and_then(|air| air.radio.as_ref())
        .map_or(0, |radio| radio.wakes)
}

/// [`shape_by_profile`] for the Mac's tunnel: what it receives the phone
/// sent, across the phone's radio.
pub fn shape_uplink(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    shape(via_turn, from, len, Some(Direction::Up))
}

/// [`shape_by_profile`] for the phone's tunnel: what it receives comes
/// down to the phone's radio.
pub fn shape_downlink(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    shape(via_turn, from, len, Some(Direction::Down))
}

/// Datagrams shaped since [`set_link_profile`]: (delivered, dropped).
pub fn shaped_counts() -> (u64, u64) {
    (DELIVERED.load(Ordering::Relaxed), DROPPED.load(Ordering::Relaxed))
}

/// SplitMix64, as cmux-fault's `Rng`.
fn next(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// A `DialOptions::impair_inbound` hook: the datagram's fate on the
/// profile set by [`set_link_profile`] (`None`: lost or tail-dropped).
pub fn shape_by_profile(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    shape(via_turn, from, len, None)
}

fn shape(via_turn: bool, from: &SocketAddr, len: usize, direction: Option<Direction>) -> Option<Duration> {
    let mut air = AIR.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(air) = air.as_mut() else { return Some(Duration::ZERO) };
    let now = Instant::now();
    // Draw before deciding, so a drop never shifts the draws after it.
    let jitter = match air.profile.jitter_ms {
        0 => 0,
        most => next(&mut air.rng) % (most + 1),
    };
    let draw = (next(&mut air.rng) >> 11) as f64 / (1_u64 << 53) as f64;
    let mut lost = draw * 100.0 < air.profile.loss_percent;
    if let Some(periodic) = air.periodic.as_mut() {
        let draw = (next(&mut periodic.rng) >> 11) as f64 / (1_u64 << 53) as f64;
        let phase = now.duration_since(periodic.since).as_nanos() % periodic.loss.period.as_nanos();
        if phase < periodic.loss.burst.as_nanos() && draw * 100.0 < periodic.loss.loss_percent {
            lost = true;
        }
    }
    // The radio, when it is idle, wakes for this datagram, which waits.
    // The wake's draw comes from its own stream so the profile's draws
    // stay the same with the radio on or off.
    let awake = match (air.radio.as_mut(), direction) {
        (Some(radio), Some(direction)) => {
            let idle = radio.last_active.is_none_or(|last| now.duration_since(last) > radio.model.tail);
            if idle && now >= radio.awake_at {
                let paging = match direction {
                    Direction::Up => Duration::ZERO,
                    Direction::Down => {
                        let mut state = air.rng ^ 0x5ad1_0000 ^ radio.wakes;
                        let most = radio.model.paging.as_micros() as u64;
                        Duration::from_micros(if most == 0 { 0 } else { next(&mut state) % most })
                    }
                };
                radio.awake_at = now + paging + radio.model.promote;
                radio.wakes += 1;
                tracing::debug!(
                    ?direction,
                    wait_ms = (paging + radio.model.promote).as_millis() as u64,
                    "radio wakes from idle"
                );
            }
            let mut awake = radio.awake_at.max(now);
            // Connected but asleep between listening slots: a datagram
            // coming down reaches the radio half a round trip from now and
            // waits there for the next slot.
            let half = Duration::from_micros(air.profile.rtt_ms * 500);
            if !radio.model.drx_cycle.is_zero()
                && direction == Direction::Down
                && let Some(last) = radio.on_air.filter(|_| !idle)
            {
                let reach = awake + half;
                let asleep = last + radio.model.drx_inactivity;
                if reach > asleep {
                    let cycle = radio.model.drx_cycle.as_nanos();
                    let into = (reach - asleep).as_nanos() % cycle;
                    if into != 0 {
                        let wait = Duration::from_nanos((cycle - into) as u64);
                        tracing::trace!(
                            wait_us = wait.as_micros() as u64,
                            "radio listens at its next DRX slot"
                        );
                        awake += wait;
                    }
                }
            }
            radio.last_active = Some(awake);
            let crossed = if direction == Direction::Down { awake + half } else { awake };
            radio.on_air = Some(radio.on_air.map_or(crossed, |last| last.max(crossed)));
            awake
        }
        _ => now,
    };
    let free = air.free_at.entry(*from).or_insert(now);
    let start = (*free).max(awake);
    // The bearer's buffer holds what waits for the radio too.
    if start - awake > air.profile.serialize(QUEUE_SEGMENTS * SEGMENT) {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        tracing::debug!(%from, len, via_turn, "shaper drops a datagram: queue full");
        return None;
    }
    let left = start + air.profile.serialize(len);
    *free = left;
    if lost {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        tracing::debug!(%from, len, via_turn, "shaper drops a datagram: loss");
        return None;
    }
    DELIVERED.fetch_add(1, Ordering::Relaxed);
    tracing::trace!(%from, len, via_turn, ?direction, "shaper delivers a datagram");
    let arrive = left + Duration::from_micros(air.profile.rtt_ms * 500) + Duration::from_millis(jitter);
    // Never zero: zero means "deliver now, unordered" to the hook's caller.
    Some((arrive - now).max(Duration::from_micros(1)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shaper is one process-wide profile: tests that set it take turns.
    static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    #[test]
    fn reads_the_profiles_the_udp_shaper_plays() {
        let lte = LinkProfile::named("lte");
        assert_eq!((lte.rtt_ms, lte.loss_percent, lte.rate_kbit()), (70, 0.5, 12_000));
        let lossy = LinkProfile::named("lossy-3");
        assert_eq!((lossy.rtt_ms, lossy.jitter_ms, lossy.loss_percent), (70, 300, 3.0));
    }

    /// Periodic loss drops inside its window and never outside it.
    #[tokio::test(start_paused = true)]
    async fn periodic_loss_drops_only_inside_its_window() {
        let _serial = SERIAL.lock().await;
        let flat = LinkProfile {
            name: "flat".into(),
            up_kbit: 0,
            down_kbit: 0,
            rtt_ms: 0,
            jitter_ms: 0,
            loss_percent: 0.0,
        };
        set_link_profile(Some(flat), 3);
        let loss = PeriodicLoss::parse("1000:100:100").unwrap();
        set_periodic_loss(Some(loss));
        let from: SocketAddr = "127.0.0.1:9".parse().unwrap();
        let mut fates = Vec::new();
        for _ in 0..40 {
            fates.push(shape_by_profile(false, &from, 64).is_some());
            tokio::time::advance(Duration::from_millis(50)).await;
        }
        // 0, 50 ms and 1000, 1050 ms are inside a 100 ms window; the rest are not.
        let lost: Vec<usize> =
            fates.iter().enumerate().filter(|(_, delivered)| !**delivered).map(|(i, _)| i).collect();
        assert_eq!(lost, vec![0, 1, 20, 21]);
        assert_eq!(
            PeriodicLoss::parse("15000:300:40").map(|loss| loss.burst),
            Some(Duration::from_millis(300))
        );
        assert_eq!(PeriodicLoss::parse("100:300:40"), None);
        set_link_profile(None, 0);
    }

    /// An idle radio holds the next datagram for its wake (promotion up,
    /// paging plus promotion down); traffic inside the tail does not wake it.
    #[tokio::test(start_paused = true)]
    async fn an_idle_radio_holds_the_next_datagram_for_its_wake() {
        let _serial = SERIAL.lock().await;
        let profile = LinkProfile {
            name: "flat".into(),
            up_kbit: 0,
            down_kbit: 0,
            rtt_ms: 70,
            jitter_ms: 0,
            loss_percent: 0.0,
        };
        let model = RadioModel::lte();
        set_link_profile(Some(profile), 7);
        set_radio_model(Some(model));
        let from: SocketAddr = "127.0.0.1:9".parse().unwrap();
        let one_way = Duration::from_millis(35);
        // Never used: the first datagram wakes it.
        assert_eq!(shape_uplink(false, &from, 64), Some(model.promote + one_way));
        tokio::time::advance(model.promote + Duration::from_secs(5)).await;
        assert_eq!(shape_downlink(false, &from, 64), Some(one_way));
        assert_eq!(radio_wakes(), 1);
        tokio::time::advance(model.tail + Duration::from_millis(1)).await;
        let down = shape_downlink(false, &from, 64).unwrap();
        assert!(down >= model.promote + one_way && down < model.paging + model.promote + one_way, "{down:?}");
        // A datagram during the wake waits for the same moment.
        let up = shape_uplink(false, &from, 64).unwrap();
        assert_eq!(up, down);
        assert_eq!(radio_wakes(), 2);
        set_link_profile(None, 0);
    }

    /// Connected-mode DRX: inside the inactivity timer a datagram coming
    /// down is let through; past it, it waits for the next listening slot.
    #[tokio::test(start_paused = true)]
    async fn a_connected_radio_past_its_inactivity_timer_waits_for_its_slot() {
        let _serial = SERIAL.lock().await;
        let profile = LinkProfile {
            name: "flat".into(),
            up_kbit: 0,
            down_kbit: 0,
            rtt_ms: 70,
            jitter_ms: 0,
            loss_percent: 0.0,
        };
        let model = RadioModel::lte().with_drx(Duration::from_millis(320));
        set_link_profile(Some(profile), 7);
        set_radio_model(Some(model));
        let from: SocketAddr = "127.0.0.1:9".parse().unwrap();
        let one_way = Duration::from_millis(35);
        assert_eq!(shape_uplink(false, &from, 64), Some(model.promote + one_way));
        tokio::time::advance(model.promote).await;
        // A key goes up; its echo, sent half a round trip later, reaches
        // the radio 70 ms after the key: inside the 100 ms timer.
        assert_eq!(shape_uplink(false, &from, 64), Some(one_way));
        tokio::time::advance(one_way).await;
        assert_eq!(shape_downlink(false, &from, 64), Some(one_way));
        // 2 s of quiet. The echo crossed at t0; the radio sleeps from
        // t0 + 100 ms with slots every 320 ms. The next datagram down
        // reaches it at t0 + 2000 ms, 1900 ms into the sleep: it waits
        // 20 ms for the slot at 1920 ms (6 x 320).
        tokio::time::advance(Duration::from_secs(2)).await;
        let down = shape_downlink(false, &from, 64).unwrap();
        assert_eq!(down, one_way + Duration::from_millis(20));
        set_link_profile(None, 0);
    }
}
