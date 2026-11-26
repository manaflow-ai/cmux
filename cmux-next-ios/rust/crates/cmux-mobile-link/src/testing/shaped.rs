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

struct Air {
    profile: LinkProfile,
    /// When each sender's bearer is free again.
    free_at: HashMap<SocketAddr, Instant>,
    rng: u64,
}

static AIR: Mutex<Option<Air>> = Mutex::new(None);
static DELIVERED: AtomicU64 = AtomicU64::new(0);
static DROPPED: AtomicU64 = AtomicU64::new(0);

/// Shape every tunnel dialed with [`shape_by_profile`] by `profile` from
/// now on, seeded (`None`: deliver at once). Process-wide: one profile per
/// measurement.
pub fn set_link_profile(profile: Option<LinkProfile>, seed: u64) {
    *AIR.lock().unwrap_or_else(PoisonError::into_inner) =
        profile.map(|profile| Air { profile, free_at: HashMap::new(), rng: seed });
    DELIVERED.store(0, Ordering::Relaxed);
    DROPPED.store(0, Ordering::Relaxed);
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
pub fn shape_by_profile(_via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    let mut air = AIR.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(air) = air.as_mut() else { return Some(Duration::ZERO) };
    let now = Instant::now();
    // Draw before deciding, so a drop never shifts the draws after it.
    let jitter = match air.profile.jitter_ms {
        0 => 0,
        most => next(&mut air.rng) % (most + 1),
    };
    let draw = (next(&mut air.rng) >> 11) as f64 / (1_u64 << 53) as f64;
    let lost = draw * 100.0 < air.profile.loss_percent;
    let free = air.free_at.entry(*from).or_insert(now);
    let start = (*free).max(now);
    if start - now > air.profile.serialize(QUEUE_SEGMENTS * SEGMENT) {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return None;
    }
    let left = start + air.profile.serialize(len);
    *free = left;
    if lost {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return None;
    }
    DELIVERED.fetch_add(1, Ordering::Relaxed);
    let arrive = left + Duration::from_micros(air.profile.rtt_ms * 500) + Duration::from_millis(jitter);
    // Never zero: zero means "deliver now, unordered" to the hook's caller.
    Some((arrive - now).max(Duration::from_micros(1)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_profiles_the_udp_shaper_plays() {
        let lte = LinkProfile::named("lte");
        assert_eq!((lte.rtt_ms, lte.loss_percent, lte.rate_kbit()), (70, 0.5, 12_000));
        let lossy = LinkProfile::named("lossy-3");
        assert_eq!((lossy.rtt_ms, lossy.jitter_ms, lossy.loss_percent), (70, 300, 3.0));
    }
}
