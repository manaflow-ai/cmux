//! The phone's key-to-paint histogram: per typed key, the time from the tap to the frame that
//! shows the Mac's echo of it, tagged by the network (`wifi`, `lte`, ...) and the link's route
//! (`direct`, `turn`, `https-relay`, ...), with p50/p95/p99 and fixed buckets.
//!
//! [`key_echo`](crate::key_echo) times the echo's bytes arriving and is drained into every
//! `link_stat`. This one times the paint, is never drained (a debug read and the harness print
//! it with [`snapshot`]), and keeps the gaps between spikes: lag spikes "in intervals" while
//! typing show up as gaps that are multiples of one period, and [`Period`] names the timer on
//! the phone's link whose interval it is ([`KNOWN_TIMERS`]).
//!
//! Bounded: at most [`MAX_TAGS`] tags, [`RECENT`] samples per tag for the percentiles (buckets
//! count every key), and [`MAX_SPIKES`] spikes.

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;

/// A key slower than its tag's usual (the median of its newest keys) by more than this (ms) is
/// a spike (the median follows every key for the first [`BASELINE_KEYS`], then every
/// [`BASELINE_KEYS`] keys). On a
/// link whose every key takes 200 ms (lossy-3) a spike is a key that felt slower than the rest,
/// not every key.
pub const SPIKE_MS: u32 = crate::key_echo::SPIKE_MS;
/// Keys after which a tag's spike line is refreshed only every this many keys.
pub const BASELINE_KEYS: u64 = 64;
/// Upper edges (ms, inclusive) of the buckets; one more bucket holds the rest.
pub const EDGES_MS: [u32; 15] = [8, 16, 25, 33, 50, 67, 100, 150, 200, 300, 500, 750, 1000, 2000, 5000];
/// Upper edges (ms, inclusive) of the gap-between-spikes buckets; one more holds the rest.
pub const GAP_EDGES_MS: [u32; 12] =
    [500, 1000, 2000, 3000, 5000, 8000, 10_500, 15_500, 20_500, 30_500, 60_500, 120_500];
/// Samples per tag the percentiles read (the newest).
pub const RECENT: usize = 1024;
/// The most spikes kept (the newest).
pub const MAX_SPIKES: usize = 64;
/// The most tags (network and route pairs); past it, keys count under the last tag's slot.
pub const MAX_TAGS: usize = 16;
/// Gaps needed before a period is named.
pub const MIN_GAPS: usize = 5;
/// Share of the gaps a period must explain.
pub const MIN_SCORE: f64 = 0.7;
/// Every millisecond value is clamped to this (ten minutes, as `link_stat`'s).
const MAX_MS: u32 = 600_000;

/// The fixed periods on the phone's typing path (value, then where it is set), the names a
/// found period is matched against.
pub const KNOWN_TIMERS: &[(u32, &str)] = &[
    (2_000, "size-lease-v2 refresh (DaemonTerminalSession.shortLeaseRefresh)"),
    (3_000, "WireGuard reachability marker (dial/wireguard.rs)"),
    (4_500, "phone air floor (dial/mod.rs)"),
    (5_000, "hybrid RTT ticker (hybrid.rs)"),
    (10_000, "WireGuard persistent keepalive (dial/wireguard.rs) / keepalive beat (keepalive.rs)"),
    (
        15_000,
        "size-lease-v1 refresh (DaemonTerminalSession.sizeLeaseRefresh) / signaling keepalive (signaling.rs)",
    ),
    (20_000, "relay ping (dial/relay.rs) / chief keepalive (keepalive.rs)"),
    (25_000, "WireGuard reach pin (dial/wireguard.rs)"),
    (60_000, "link_stat period (link_stat.rs)"),
];

/// One tag's numbers.
#[derive(Debug, Clone, Default)]
struct Tag {
    buckets: [u64; EDGES_MS.len() + 1],
    recent: VecDeque<u32>,
    total: u64,
    /// The spike line: `SPIKE_MS` over the median, refreshed each key in warm-up, then every `BASELINE_KEYS`.
    spike_over: u32,
}

impl Tag {
    fn refresh_line(&mut self) {
        let mut sorted: Vec<u32> = self.recent.iter().copied().collect();
        sorted.sort_unstable();
        self.spike_over = rank(&sorted, 50).saturating_add(SPIKE_MS);
    }
}

/// One slow key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Spike {
    /// Ms since the meter started.
    pub t_ms: u64,
    pub ms: u32,
    pub net: String,
    pub path: String,
}

/// A period the gaps between spikes share.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Period {
    pub ms: u32,
    /// Share of the gaps that are a whole multiple (1 to 4) of it.
    pub score: f64,
    pub gaps: usize,
    /// The known timer within 10 % of it, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timer: Option<&'static str>,
}

/// The key-to-paint numbers of one network and route.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TagSummary {
    pub net: String,
    pub path: String,
    /// Every key counted.
    pub n: u64,
    /// Percentiles of the newest [`RECENT`] keys.
    pub p50: u32,
    pub p95: u32,
    pub p99: u32,
    pub max: u32,
    /// Counts per bucket of [`EDGES_MS`] (the last: over the last edge).
    pub buckets: Vec<u64>,
    pub spikes: u64,
    /// The spike line in force (ms): a key slower than this counted as a spike.
    pub spike_over_ms: u32,
}

/// What a debug read prints.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Snapshot {
    pub spike_ms: u32,
    pub edges_ms: Vec<u32>,
    pub tags: Vec<TagSummary>,
    pub spike_count: u64,
    pub spikes: Vec<Spike>,
    /// Ms between consecutive spikes (of the kept ones).
    pub gaps_ms: Vec<u64>,
    pub gap_edges_ms: Vec<u32>,
    pub gap_buckets: Vec<u64>,
    /// None: no period found in the gaps (or too few of them).
    pub period: Option<Period>,
}

/// The meter (pure: the caller passes the time).
#[derive(Debug, Default)]
pub struct Meter {
    tags: BTreeMap<(String, String), Tag>,
    tag_spikes: BTreeMap<(String, String), u64>,
    spikes: VecDeque<Spike>,
    spike_count: u64,
    gap_buckets: [u64; GAP_EDGES_MS.len() + 1],
}

fn bucket(edges: &[u32], value: u64) -> usize {
    edges.iter().position(|edge| value <= u64::from(*edge)).unwrap_or(edges.len())
}

fn rank(sorted: &[u32], p: usize) -> u32 {
    sorted[(sorted.len() * p).div_ceil(100).saturating_sub(1).min(sorted.len() - 1)]
}

impl Meter {
    /// A key painted `ms` after its tap, at `at` since the meter started.
    pub fn record(&mut self, ms: u32, net: &str, path: &str, at: Duration) {
        let ms = ms.min(MAX_MS);
        let mut key = (net.to_owned(), path.to_owned());
        if !self.tags.contains_key(&key) && self.tags.len() >= MAX_TAGS {
            key = ("other".to_owned(), "other".to_owned());
        }
        let tag = self.tags.entry(key.clone()).or_default();
        tag.buckets[bucket(&EDGES_MS, u64::from(ms))] += 1;
        tag.total += 1;
        if tag.recent.len() >= RECENT {
            tag.recent.pop_front();
        }
        tag.recent.push_back(ms);
        // Warm-up: the line follows every key, so a slow link's first keys are not spikes.
        if tag.total <= BASELINE_KEYS || tag.total.is_multiple_of(BASELINE_KEYS) {
            tag.refresh_line();
        }
        let line = tag.spike_over;
        if ms <= line {
            return;
        }
        self.spike_count += 1;
        *self.tag_spikes.entry(key.clone()).or_default() += 1;
        let t_ms = u64::try_from(at.as_millis()).unwrap_or(u64::MAX);
        if let Some(last) = self.spikes.back() {
            self.gap_buckets[bucket(&GAP_EDGES_MS, t_ms.saturating_sub(last.t_ms))] += 1;
        }
        if self.spikes.len() >= MAX_SPIKES {
            self.spikes.pop_front();
        }
        self.spikes.push_back(Spike { t_ms, ms, net: key.0, path: key.1 });
    }

    pub fn snapshot(&self) -> Snapshot {
        let tags = self
            .tags
            .iter()
            .filter(|(_, tag)| !tag.recent.is_empty())
            .map(|((net, path), tag)| {
                let mut sorted: Vec<u32> = tag.recent.iter().copied().collect();
                sorted.sort_unstable();
                TagSummary {
                    net: net.clone(),
                    path: path.clone(),
                    n: tag.total,
                    p50: rank(&sorted, 50),
                    p95: rank(&sorted, 95),
                    p99: rank(&sorted, 99),
                    max: sorted[sorted.len() - 1],
                    buckets: tag.buckets.to_vec(),
                    spikes: self.tag_spikes.get(&(net.clone(), path.clone())).copied().unwrap_or(0),
                    spike_over_ms: tag.spike_over,
                }
            })
            .collect();
        let gaps: Vec<u64> = self
            .spikes
            .iter()
            .zip(self.spikes.iter().skip(1))
            .map(|(a, b)| b.t_ms.saturating_sub(a.t_ms))
            .collect();
        Snapshot {
            spike_ms: SPIKE_MS,
            edges_ms: EDGES_MS.to_vec(),
            tags,
            spike_count: self.spike_count,
            spikes: self.spikes.iter().cloned().collect(),
            period: period(&gaps),
            gaps_ms: gaps,
            gap_edges_ms: GAP_EDGES_MS.to_vec(),
            gap_buckets: self.gap_buckets.to_vec(),
        }
    }
}

/// The longest period (1 s or more) of which at least [`MIN_SCORE`] of `gaps` are a whole
/// multiple (1 to 4, within the larger of 200 ms and 6 % of it), tried at each gap's own length
/// and each of its halves to quarters (a spike need not land on every tick) and at every
/// [`KNOWN_TIMERS`] value. None with fewer than [`MIN_GAPS`] gaps.
pub fn period(gaps: &[u64]) -> Option<Period> {
    if gaps.len() < MIN_GAPS {
        return None;
    }
    let mut candidates: Vec<u64> = KNOWN_TIMERS.iter().map(|(ms, _)| u64::from(*ms)).collect();
    for gap in gaps {
        candidates.extend((1..=4).map(|k| gap / k));
    }
    candidates.retain(|p| *p >= 1000);
    candidates.sort_unstable();
    candidates.dedup();
    let score = |p: u64| {
        let tol = (p * 6 / 100).max(200);
        let fits = gaps
            .iter()
            .filter(|gap| {
                let k = ((**gap + p / 2) / p).clamp(1, 4);
                gap.abs_diff(k * p) <= tol
            })
            .count();
        fits as f64 / gaps.len() as f64
    };
    // The longest that fits: a shorter one fitting too is a sub-multiple of it.
    let found = candidates.into_iter().rev().find(|p| score(*p) >= MIN_SCORE)?;
    // Refine to the mean of the gaps' own periods (a measured 9.96 s, not a first gap's 9.8 s).
    let tol = (found * 6 / 100).max(200);
    let fitted: Vec<f64> = gaps
        .iter()
        .filter_map(|gap| {
            let k = ((*gap + found / 2) / found).clamp(1, 4);
            (gap.abs_diff(k * found) <= tol).then(|| *gap as f64 / k as f64)
        })
        .collect();
    let ms = (fitted.iter().sum::<f64>() / fitted.len() as f64).round() as u32;
    let timer = KNOWN_TIMERS
        .iter()
        .filter(|(t, _)| t.abs_diff(ms) * 10 <= *t)
        .min_by_key(|(t, _)| t.abs_diff(ms))
        .map(|(_, name)| *name);
    Some(Period { ms, score: score(found), gaps: gaps.len(), timer })
}

static METER: Mutex<Option<Meter>> = Mutex::new(None);
static START: OnceLock<Instant> = OnceLock::new();
/// The network the app last reported (`set_network`), and the route of the newest link.
static NET: Mutex<Option<String>> = Mutex::new(None);
static ROUTE: Mutex<Option<String>> = Mutex::new(None);

fn lock<T>(m: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The device's network now: `wifi`, `lte` (any cellular), `wired` or `other`.
pub fn set_network(kind: &str) {
    *lock(&NET) = Some(kind.to_owned());
}

/// The newest link's route (`LinkPath::as_str`), set when a link reports and on each change.
pub fn set_route(path: &str) {
    *lock(&ROUTE) = Some(path.to_owned());
}

/// [`set_route`] with `path`, returned (the link report's path watch passes through it).
pub fn route_changed(path: crate::dial::LinkPath) -> crate::dial::LinkPath {
    set_route(path.as_str());
    path
}

/// A key's echo was painted `ms` after its tap, under the current network and route.
pub fn record(ms: u32) {
    let at = START.get_or_init(Instant::now).elapsed();
    let net = lock(&NET).clone().unwrap_or_else(|| "unknown".to_owned());
    let path = lock(&ROUTE).clone().unwrap_or_else(|| "unknown".to_owned());
    lock(&METER).get_or_insert_with(Meter::default).record(ms, &net, &path, at);
}

/// Every key since launch (or the last [`reset`]), not emptied.
pub fn snapshot() -> Snapshot {
    lock(&METER).as_ref().map(Meter::snapshot).unwrap_or_else(|| Meter::default().snapshot())
}

/// The snapshot as JSON (the debug read).
pub fn snapshot_json() -> String {
    serde_json::to_string(&snapshot()).unwrap_or_else(|_| "{}".to_owned())
}

/// Start over (a debug read's "reset").
pub fn reset() {
    *lock(&METER) = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_and_percentiles_by_tag() {
        let mut m = Meter::default();
        for i in 0..100u32 {
            m.record(10 + i, "lte", "direct", Duration::from_millis(u64::from(i) * 200));
        }
        m.record(40, "wifi", "direct", Duration::from_secs(30));
        let s = m.snapshot();
        assert_eq!(s.tags.len(), 2);
        let lte = s.tags.iter().find(|t| t.net == "lte").unwrap();
        assert_eq!((lte.n, lte.p50, lte.p95, lte.p99, lte.max), (100, 59, 104, 108, 109));
        assert_eq!(lte.buckets.iter().sum::<u64>(), 100);
        // 10..=16 in the 16 ms bucket.
        assert_eq!(lte.buckets[1], 7);
        assert_eq!(lte.spikes, 0);
        assert_eq!(s.period, None);
    }

    #[test]
    fn spikes_every_ten_seconds_name_the_keepalive() {
        let mut m = Meter::default();
        let mut t = 0u64;
        // A key every 120 ms for 2 minutes; the key at each 10 s tick (skipping some) spikes.
        while t < 120_000 {
            let tick = t % 10_000 < 120 && (t / 10_000) % 3 != 1;
            m.record(if tick { 420 } else { 70 }, "lte", "direct", Duration::from_millis(t + (t / 7) % 40));
            t += 120;
        }
        let s = m.snapshot();
        let p = s.period.expect("a period");
        assert!((9_800..=10_200).contains(&p.ms), "{p:?}");
        assert!(p.timer.unwrap().contains("keepalive"), "{p:?}");
        assert!(s.gap_buckets.iter().sum::<u64>() as usize == s.gaps_ms.len());
    }

    #[test]
    fn random_spikes_have_no_period() {
        let mut m = Meter::default();
        // splitmix64: spikes at irregular times.
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut t = 0u64;
        for _ in 0..40 {
            x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = x;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            t += 1_500 + (z ^ (z >> 31)) % 23_000;
            m.record(300, "lte", "turn", Duration::from_millis(t));
        }
        assert_eq!(m.snapshot().period, None, "{:?}", m.snapshot().gaps_ms);
    }

    #[test]
    fn a_slow_link_is_not_a_spike_storm() {
        // lossy-3's shape: every key 150-350 ms; one key every 10 s takes 900.
        let mut m = Meter::default();
        let mut t = 0u64;
        let mut x = 7u64;
        while t < 120_000 {
            x = x.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            let ms = if t % 10_000 < 100 { 900 } else { 150 + ((x >> 33) % 200) as u32 };
            m.record(ms, "lte", "direct", Duration::from_millis(t));
            t += 100;
        }
        let s = m.snapshot();
        let lte = &s.tags[0];
        assert!(lte.spikes < 40, "{} spikes over {} ms", lte.spikes, lte.spike_over_ms);
        assert!((350..=500).contains(&lte.spike_over_ms), "{}", lte.spike_over_ms);
        let p = s.period.expect("the 10 s spikes still show");
        assert!((9_800..=10_200).contains(&p.ms), "{p:?}");
    }

    #[test]
    fn bounded() {
        let mut m = Meter::default();
        for i in 0..20_000u64 {
            m.record(
                if i % 3 == 0 { 400 } else { 30 },
                &format!("n{}", i % 40),
                "direct",
                Duration::from_millis(i * 50),
            );
        }
        let s = m.snapshot();
        assert!(s.tags.len() <= MAX_TAGS + 1);
        assert!(s.spikes.len() <= MAX_SPIKES);
        assert!(s.tags.iter().all(|t| t.n >= 1));
        assert_eq!(s.tags.iter().map(|t| t.n).sum::<u64>(), 20_000);
    }
}
