//! How long a link's own writer sits on a frame: from the frame entering the
//! outbox to the `flush` that handed it to the transport finishing. The
//! number that separates "the network is slow" from "we are slow" on a remote
//! terminal (ping RTT is a datagram, outside both streams, so it cannot see a
//! writer that is behind).
//!
//! A fixed log-linear histogram, so the cost per frame is one bucket
//! increment and the memory is constant however busy the link is.
//! Percentiles are the upper bound of the bucket they fall in (at most 1/8
//! high), capped at the exact max.
//!
//! Reading note `docs/reading/2026-11-26-discord-voice-to-the-edge.md` (hq):
//! a recv branch that was always ready starved a flush timer in the same
//! task, and the number that showed it was queue wait before flush (about
//! 1 ms normally, hundreds of ms in a spike). Our writer is its own task, so
//! that shape cannot happen here today; this histogram is what would show it
//! if it ever did.

use serde::Serialize;

/// Sub-buckets per power of two: values within one bucket differ by at most 1/8.
const SUB: u32 = 8;
/// Exact buckets below `SUB` µs, then `SUB` per octave up to 2^40 µs (12 days).
const OCTAVES: u32 = 40;
const BUCKETS: usize = (SUB + (OCTAVES - SUB.trailing_zeros()) * SUB) as usize + 1;

/// The bucket of `us`.
fn bucket(us: u64) -> usize {
    if us < u64::from(SUB) {
        return us as usize;
    }
    let octave = 63 - us.leading_zeros(); // floor(log2(us)) >= log2(SUB)
    let shift = octave - SUB.trailing_zeros();
    let sub = (us >> shift) as u32 - SUB; // 0..SUB
    let index = SUB + (octave - SUB.trailing_zeros()) * SUB + sub;
    (index as usize).min(BUCKETS - 1)
}

/// The largest value in bucket `index`.
fn upper(index: usize) -> u64 {
    let index = index as u32;
    if index < SUB {
        return u64::from(index);
    }
    let octave = (index - SUB) / SUB + SUB.trailing_zeros();
    let sub = (index - SUB) % SUB;
    let shift = octave - SUB.trailing_zeros();
    ((u64::from(SUB + sub) + 1) << shift) - 1
}

/// Outbox waits (µs) since the last [`OutboxWait::take`].
#[derive(Clone, PartialEq, Eq)]
pub struct OutboxWait {
    counts: [u64; BUCKETS],
    n: u64,
    max_us: u64,
}

impl Default for OutboxWait {
    fn default() -> Self {
        Self { counts: [0; BUCKETS], n: 0, max_us: 0 }
    }
}

impl std::fmt::Debug for OutboxWait {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "OutboxWait({:?})", self.summary())
    }
}

impl OutboxWait {
    /// One frame's wait.
    pub fn record(&mut self, us: u64) {
        self.counts[bucket(us)] += 1;
        self.n += 1;
        self.max_us = self.max_us.max(us);
    }

    pub fn n(&self) -> u64 {
        self.n
    }

    /// Nearest-rank percentile `p` (0..=100) in µs, `None` with no samples.
    pub fn percentile(&self, p: u32) -> Option<u64> {
        if self.n == 0 {
            return None;
        }
        let rank = (self.n * u64::from(p.min(100))).div_ceil(100).max(1);
        let mut seen = 0;
        for (index, count) in self.counts.iter().enumerate() {
            seen += count;
            if seen >= rank {
                return Some(upper(index).min(self.max_us));
            }
        }
        Some(self.max_us)
    }

    /// The window's numbers, `None` with no samples.
    pub fn summary(&self) -> Option<OutboxWaitSummary> {
        let clamp = |us: u64| u32::try_from(us).unwrap_or(u32::MAX).min(MAX_US);
        Some(OutboxWaitSummary {
            n: u32::try_from(self.n).unwrap_or(u32::MAX).min(100_000_000),
            p50: clamp(self.percentile(50)?),
            p95: clamp(self.percentile(95)?),
            p99: clamp(self.percentile(99)?),
            max: clamp(self.max_us),
        })
    }

    /// Add another window's waits (the two streams of one link).
    pub fn merge(&mut self, other: &Self) {
        for (mine, theirs) in self.counts.iter_mut().zip(other.counts.iter()) {
            *mine += theirs;
        }
        self.n += other.n;
        self.max_us = self.max_us.max(other.max_us);
    }

    /// This window, leaving an empty one.
    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }
}

/// The most a summary value says: 600 s, as `link_stat`'s ms fields.
pub const MAX_US: u32 = 600_000_000;

/// `link_stat` `outboxUs`: nearest-rank percentiles of outbox wait, µs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct OutboxWaitSummary {
    pub n: u32,
    pub p50: u32,
    pub p95: u32,
    pub p99: u32,
    pub max: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_cover_every_value_and_stay_within_an_eighth() {
        let mut last = 0;
        for us in (0..5_000u64).chain([1 << 20, (1 << 20) + 1, 999_999, 600_000_000, u64::MAX / 2, u64::MAX]) {
            let index = bucket(us);
            assert!(index >= last || us > 5_000, "monotonic at {us}");
            last = index;
            let top = upper(index);
            if index < BUCKETS - 1 {
                assert!(top >= us, "{us} in bucket {index} topped at {top}");
                assert!(top - us <= us / 8 + 1, "{us} -> {top} is over an eighth high");
            }
        }
    }

    #[test]
    fn percentiles_are_nearest_rank_and_capped_at_the_max() {
        let mut wait = OutboxWait::default();
        assert_eq!(wait.summary(), None);
        for us in 1..=100u64 {
            wait.record(us * 100); // 100 µs .. 10 ms
        }
        let s = wait.summary().unwrap();
        assert_eq!(s.n, 100);
        assert!((5_000..=5_000 + 5_000 / 8).contains(&s.p50), "{s:?}");
        assert!((9_900..=10_000).contains(&s.p99), "{s:?}");
        assert_eq!(s.max, 10_000);
        let one = {
            let mut w = OutboxWait::default();
            w.record(1_234);
            w.summary().unwrap()
        };
        assert_eq!((one.p50, one.p99, one.max), (1_234, 1_234, 1_234));
    }

    #[test]
    fn take_empties_and_merge_adds() {
        let mut a = OutboxWait::default();
        a.record(10);
        let mut b = OutboxWait::default();
        b.record(2_000_000);
        a.merge(&b);
        assert_eq!((a.n(), a.summary().unwrap().max), (2, 2_000_000));
        let taken = a.take();
        assert_eq!((taken.n(), a.n()), (2, 0));
        let mut huge = OutboxWait::default();
        huge.record(u64::MAX);
        assert_eq!(huge.summary().unwrap().max, MAX_US);
    }
}
