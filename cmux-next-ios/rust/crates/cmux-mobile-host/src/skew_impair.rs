//! Network impairment for the phone side of the link gates (`cmux-mobile-applike`,
//! `scripts/ci/mobile-pair-skew.sh`): plain-`fn` `DialOptions` hooks driven by env, so a
//! phone binary built from an older commit can carry them too (the gate copies this file
//! beside `cmux-mobile-applike.rs` into that commit's tree; `impair_inbound` took two
//! arguments up to 2026-11-20, three after: `impair2`, `impair3`).
//!
//! `CMUX_SKEW_IMPAIR=delay_ms=N,jitter_ms=N,loss_pct=N,burst=N,flip_s=N,seed=N` shapes
//! every datagram WireGuard receives (direct or through TURN; WebRTC and the WSS relay are
//! not shaped): delay +- jitter; `loss_pct` lost on average, in Gilbert-Elliott bursts of
//! mean length `burst`; and with `flip_s`, an address hop: from the first `flip_s` on, odd
//! phases blackhole the Mac's loopback address and even phases every other one, both ways
//! ([`drop_out`] is the `drop_udp_to` hook), so the tunnel has to move between the Mac's
//! addresses (a Wi-Fi/cellular hop). Burst loss and the hop follow plink-bisect's oracle
//! profile (300+-250 ms, 3% in bursts of ~4, a hop every 25 s). [`blackout`] drops all
//! inbound datagrams for a while: a carrier gone, then back.

#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Impair {
    pub delay_ms: u64,
    pub jitter_ms: u64,
    pub loss_pct: f64,
    pub burst: u64,
    pub flip_s: u64,
    pub seed: u64,
}

impl Impair {
    pub fn parse(text: &str) -> Impair {
        let mut impair = Impair::default();
        for part in text.split(',').map(str::trim).filter(|part| !part.is_empty()) {
            let Some((key, value)) = part.split_once('=') else { continue };
            match key {
                "delay_ms" => impair.delay_ms = value.parse().unwrap_or(0),
                "jitter_ms" => impair.jitter_ms = value.parse().unwrap_or(0),
                "loss_pct" => impair.loss_pct = value.parse().unwrap_or(0.0),
                "burst" => impair.burst = value.parse().unwrap_or(0),
                "flip_s" => impair.flip_s = value.parse().unwrap_or(0),
                "seed" => impair.seed = value.parse().unwrap_or(0),
                _ => {}
            }
        }
        impair
    }

    /// The `n`th datagram's fate: `None` drops it, else its added delay. `bad` is the
    /// Gilbert-Elliott state, carried between datagrams.
    pub fn fate(&self, n: u64, bad: &AtomicBool) -> Option<Duration> {
        let roll = splitmix(self.seed ^ n.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        if self.loss_pct > 0.0 {
            let lost = if self.burst > 1 {
                // bad -> good with 1/burst; good -> bad so that loss_pct of datagrams are bad.
                let p = (self.loss_pct / 100.0).min(0.99);
                let to_bad = p / (self.burst as f64 * (1.0 - p));
                let unit = (roll % 1_000_000) as f64 / 1_000_000.0;
                let next = if bad.load(Ordering::Relaxed) { unit >= 1.0 / self.burst as f64 } else { unit < to_bad };
                bad.store(next, Ordering::Relaxed);
                next
            } else {
                (roll % 10_000) as f64 / 100.0 < self.loss_pct
            };
            if lost {
                return None;
            }
        }
        let jitter = if self.jitter_ms > 0 { (roll >> 20) % (2 * self.jitter_ms + 1) } else { 0 };
        Some(Duration::from_millis((self.delay_ms + jitter).saturating_sub(self.jitter_ms)))
    }

    /// With `flip_s`, whether `to` is blackholed in the phase `elapsed` falls in.
    pub fn hopped_away(&self, to: &SocketAddr, elapsed: Duration) -> bool {
        if self.flip_s == 0 {
            return false;
        }
        let phase = elapsed.as_secs() / self.flip_s;
        phase > 0 && (phase % 2 == 1) == to.ip().is_loopback()
    }
}

fn splitmix(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

static IMPAIR: OnceLock<Impair> = OnceLock::new();
static T0: OnceLock<Instant> = OnceLock::new();
static BAD: AtomicBool = AtomicBool::new(false);
static DATAGRAMS: AtomicU64 = AtomicU64::new(0);
pub static IN_DROPPED: AtomicU64 = AtomicU64::new(0);
/// Unix ms until which every datagram is dropped.
static BLACKOUT_UNTIL_MS: AtomicU64 = AtomicU64::new(0);

/// The env's impairment; the hop clock starts at the first call.
pub fn impair() -> Impair {
    T0.get_or_init(Instant::now);
    *IMPAIR.get_or_init(|| Impair::parse(&std::env::var("CMUX_SKEW_IMPAIR").unwrap_or_default()))
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn elapsed() -> Duration {
    T0.get_or_init(Instant::now).elapsed()
}

fn impair_from(from: &SocketAddr) -> Option<Duration> {
    let impair = impair();
    let n = DATAGRAMS.fetch_add(1, Ordering::Relaxed);
    let fate = if now_ms() < BLACKOUT_UNTIL_MS.load(Ordering::Relaxed) || impair.hopped_away(from, elapsed()) {
        None
    } else {
        impair.fate(n, &BAD)
    };
    if fate.is_none() {
        IN_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    fate
}

/// Datagrams the hooks saw, and dropped.
pub fn counts() -> (u64, u64) {
    (DATAGRAMS.load(Ordering::Relaxed), IN_DROPPED.load(Ordering::Relaxed))
}

/// `DialOptions::impair_inbound`, the three-argument hook (2026-11-2x on).
pub fn impair3(_relayed: bool, from: &SocketAddr, _len: usize) -> Option<Duration> {
    impair_from(from)
}

/// `DialOptions::impair_inbound`, the two-argument hook (2026-11-20 and before).
pub fn impair2(_relayed: bool, from: &SocketAddr) -> Option<Duration> {
    impair_from(from)
}

/// `DialOptions::drop_udp_to`: the outbound half of the address hop.
pub fn drop_out(to: &SocketAddr) -> bool {
    impair().hopped_away(to, elapsed())
}

/// Drop every inbound datagram for `span` from now.
pub fn blackout(span: Duration) {
    BLACKOUT_UNTIL_MS.store(now_ms() + span.as_millis() as u64, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn impairment_parses_and_drops_about_its_share() {
        let impair = Impair::parse("delay_ms=50,jitter_ms=10,loss_pct=10,seed=7");
        assert_eq!(impair.delay_ms, 50);
        let bad = AtomicBool::new(false);
        let dropped = (0..10_000).filter(|n| impair.fate(*n, &bad).is_none()).count();
        assert!((800..1200).contains(&dropped), "{dropped}");
        assert!((0..100).filter_map(|n| impair.fate(n, &bad)).all(|d| (40..=60).contains(&(d.as_millis() as u64))));
    }

    #[test]
    fn burst_loss_keeps_its_share_in_runs() {
        let impair = Impair::parse("loss_pct=3,burst=4,seed=11");
        let bad = AtomicBool::new(false);
        let fates: Vec<bool> = (0..200_000).map(|n| impair.fate(n, &bad).is_none()).collect();
        let lost = fates.iter().filter(|l| **l).count();
        let runs = fates.windows(2).filter(|w| !w[0] && w[1]).count();
        assert!((4_000..8_000).contains(&lost), "{lost}");
        let mean = lost as f64 / runs as f64;
        assert!((3.0..5.0).contains(&mean), "{mean}");
    }

    #[test]
    fn the_hop_alternates_between_loopback_and_the_rest() {
        let impair = Impair::parse("flip_s=25");
        let (lo, lan): (SocketAddr, SocketAddr) = ("127.0.0.1:1".parse().unwrap(), "10.0.0.2:1".parse().unwrap());
        let at = Duration::from_secs;
        assert!(!impair.hopped_away(&lo, at(10)) && !impair.hopped_away(&lan, at(10)));
        assert!(impair.hopped_away(&lo, at(30)) && !impair.hopped_away(&lan, at(30)));
        assert!(!impair.hopped_away(&lo, at(55)) && impair.hopped_away(&lan, at(55)));
    }
}
