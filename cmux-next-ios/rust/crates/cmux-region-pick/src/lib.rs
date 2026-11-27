//! The hub's central relay region pick (RFD 0142 O2, after Google Espresso, SIGCOMM 2017).
//!
//! A link session's WebSocket relay is a Durable Object that stays where it is first created. The
//! mobile Worker places it from both ends (`backend/src/placement.ts`): each end's measured netcheck
//! round trip to a region when it sent one, else a great-circle estimate from its geolocation. An
//! estimate cannot see a bad peering path, a carrier that backhauls to another country, or a
//! region whose colos sit far from the metro the estimate assumes.
//!
//! Espresso picks each client prefix's peering edge from the application's own measured
//! performance, aggregated centrally. Here the user's hub (`TeamHub`) does the same for relays: it
//! keeps a learned relay round trip ([`Learned`]) per user network pair (the phone's and the Mac's
//! `asn@colo`) and region, fed by the phone's `link_stat` when its link rides the relay, and asks
//! [`pick`] where the next session of that pair goes.
//!
//! [`pick`] scores each region by what was learned there, else by the placement estimate plus the
//! pair's last mile as learned (the estimate leaves it out; [`offset`]), so a measured region and an
//! estimated one compare on one scale, and a region measured slow lets an unmeasured one that could
//! be faster be tried. It moves off the
//! incumbent (the pair's last pick, else the placement's own pick) only by a margin, and with
//! nothing learned it returns the placement's pick unchanged.
//!
//! Pure: no clock, no storage, no allocation. The Worker loads it as wasm through the small
//! `extern "C"` surface in [`wasm`].

pub mod wasm;

/// Cloudflare's Durable Object location hints, in `placement.ts` `REGIONS` order (indexes cross the
/// wasm boundary).
pub const REGIONS: [&str; 9] = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"];
/// How many regions there are.
pub const N: usize = REGIONS.len();
/// Weight of a new sample in the learned round trip (an exponential moving average).
pub const ALPHA: f64 = 0.25;
/// Samples above this (ms) are ignored, as `placement.ts` `parseNetcheck` ignores netchecks above it.
pub const MAX_MS: f64 = 5000.0;
/// The most [`offset`] adds to an unmeasured region's estimate (ms): about two cellular last miles.
pub const LAST_MILE_PRIOR_MS: f64 = 60.0;
/// The pick leaves the incumbent only for a region at least this much faster (ms)...
pub const MOVE_MIN_MS: f64 = 10.0;
/// ...or this fraction of the incumbent's round trip, whichever is larger (`relay_rank.rs` uses the
/// same margin for TURN relays, cmux#56609).
pub const MOVE_FRACTION: f64 = 0.2;

/// What the hub learned about one region for one network pair.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Learned {
    /// Moving average of the relayed link's median round trip, ms.
    pub ms: f64,
    /// Samples taken (saturating).
    pub n: u32,
}

/// `prev` with one more relay round trip sample, `sample_ms` (a `link_stat` window's p50). A
/// sample that is not a finite number in `0..=MAX_MS` leaves `prev` as it was.
pub fn observe(prev: Option<Learned>, sample_ms: f64) -> Option<Learned> {
    if !sample_ms.is_finite() || !(0.0..=MAX_MS).contains(&sample_ms) {
        return prev;
    }
    Some(match prev {
        Some(p) if p.ms.is_finite() && p.n > 0 => {
            Learned { ms: p.ms + ALPHA * (sample_ms - p.ms), n: p.n.saturating_add(1) }
        }
        _ => Learned { ms: sample_ms, n: 1 },
    })
}

/// How [`pick`] chose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum By {
    /// A region with a learned round trip.
    Measured,
    /// A region scored by its estimate plus the pair's offset (not measured yet).
    Calibrated,
    /// Nothing learned for the pair (or nothing scored): the placement's own pick.
    Fallback,
}

/// Where the next session's relay goes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pick {
    /// An index into [`REGIONS`]; `None` when neither a score nor a fallback exists.
    pub region: Option<usize>,
    pub by: By,
    /// The chosen region's score (ms): learned, or estimate plus offset; `None` for a fallback.
    pub ms: Option<f64>,
}

/// What an unmeasured region adds to its estimate: the least gap between learned and estimated
/// round trips over the pair's measured regions (the part every region shares, mostly the two last
/// miles), capped at [`LAST_MILE_PRIOR_MS`]. Zero when nothing is measured.
///
/// The least gap, not the mean, and the cap make the guess optimistic: a region the pair measured
/// slow (a detour the estimate cannot see) does not raise the others with it, so an unmeasured
/// region that could be faster gets one session to show it, the way Espresso keeps measuring
/// alternate paths. A region measured once is scored by what it showed from then on.
pub fn offset(estimate: &[Option<f64>; N], learned: &[Option<Learned>; N]) -> f64 {
    let mut least = f64::INFINITY;
    for (e, l) in estimate.iter().zip(learned) {
        if let (Some(e), Some(l)) = (e, l)
            && e.is_finite()
            && l.ms.is_finite()
            && l.n > 0
        {
            least = least.min(l.ms - e);
        }
    }
    if least.is_finite() { least.clamp(0.0, LAST_MILE_PRIOR_MS) } else { 0.0 }
}

/// Each region's score (ms) and whether it was learned.
pub fn scores(estimate: &[Option<f64>; N], learned: &[Option<Learned>; N]) -> [Option<(f64, bool)>; N] {
    let off = offset(estimate, learned);
    let mut out = [None; N];
    for (r, slot) in out.iter_mut().enumerate() {
        *slot = match (learned[r], estimate[r]) {
            (Some(l), _) if l.n > 0 && l.ms.is_finite() => Some((l.ms, true)),
            (_, Some(e)) if e.is_finite() => Some(((e + off).max(0.0), false)),
            _ => None,
        };
    }
    out
}

/// The relay region for a network pair's next session.
///
/// - `estimate[r]`: the placement's estimated round trip through region r (joiner leg plus peer
///   leg; `placement.ts` `costTo`), `None` when an end's location is unknown.
/// - `learned[r]`: what the hub learned through r for this pair.
/// - `current`: the region the pair's last session got from this pick, if any.
/// - `fallback`: the placement's own pick (`relayPlacement`), returned unchanged when nothing is
///   learned.
pub fn pick(
    estimate: &[Option<f64>; N],
    learned: &[Option<Learned>; N],
    current: Option<usize>,
    fallback: Option<usize>,
) -> Pick {
    let fallback = fallback.filter(|r| *r < N);
    let current = current.filter(|r| *r < N);
    let none = Pick { region: fallback, by: By::Fallback, ms: None };
    if !learned.iter().any(|l| l.is_some_and(|l| l.n > 0 && l.ms.is_finite())) {
        return none;
    }
    let scored = scores(estimate, learned);
    // Least score; on a tie a learned region beats an estimated one, then the list's order.
    let mut best: Option<(usize, f64, bool)> = None;
    for (r, s) in scored.iter().enumerate() {
        let Some((ms, measured)) = *s else { continue };
        let better = match best {
            None => true,
            Some((_, b, bm)) => ms < b || (ms == b && measured && !bm),
        };
        if better {
            best = Some((r, ms, measured));
        }
    }
    let Some((mut r, mut ms, mut measured)) = best else { return none };
    // Hysteresis: the incumbent keeps the pair unless the best is clearly faster.
    if let Some(inc) = current.or(fallback)
        && inc != r
        && let Some((inc_ms, inc_measured)) = scored[inc]
        && inc_ms - ms < MOVE_MIN_MS.max(MOVE_FRACTION * inc_ms)
    {
        (r, ms, measured) = (inc, inc_ms, inc_measured);
    }
    Pick { region: Some(r), by: if measured { By::Measured } else { By::Calibrated }, ms: Some(ms) }
}

/// The index of `name` in [`REGIONS`].
pub fn region_index(name: &str) -> Option<usize> {
    REGIONS.iter().position(|r| *r == name)
}

#[cfg(test)]
mod tests;
