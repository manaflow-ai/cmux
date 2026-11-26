//! The phone's keystroke round trips (PROTOCOL.md "Link stats", `echo`, `ack`, `spikes`): what a
//! person typing on a real phone waits for, split by hop, carried on the next `link_stat`.
//!
//! The terminal records two times per batch of typed keys, both from the key's tap:
//! - `ack`: the Mac's answer to the `send` on the input lane, written to the PTY (phone to Mac and
//!   back, through the input stream and the Mac daemon).
//! - `echo`: the first terminal output after the keys (back through the attach stream, bulk class).
//!
//! With the stat's link ping (a datagram, outside both streams) this names the hop of a slow key:
//! - ping slow too: the network path (radio, carrier, relay);
//! - ack slow, ping fast: the input stream or the Mac daemon;
//! - echo slow, ack fast: the Mac's echo or the attach stream behind other output.
//!
//! A key slower than [`SPIKE_MS`] is a spike. The worst [`MAX_SPIKES`] of a window are kept,
//! each with when it happened (so periodic spikes show their period), its ack and its echo.
//!
//! One window for the process: a phone types into one terminal at a time, and the next stat of
//! whichever link is up carries (and empties) it. Bounded: at most [`MAX_SAMPLES`] samples per
//! window (past it, every other sample is dropped, which keeps the percentiles), so a long silence
//! between stats costs nothing and a long burst of typing costs a fixed amount.

use std::sync::Mutex;
use std::time::Instant;

use serde::Serialize;

/// A key slower than this (ms, tap to echo) is a spike.
pub const SPIKE_MS: u32 = 150;
/// The most spikes a window keeps (the slowest).
pub const MAX_SPIKES: usize = 6;
/// The most samples of each kind a window keeps.
pub const MAX_SAMPLES: usize = 2048;
/// Every millisecond value is clamped to this (ten minutes, as `link_stat`'s).
const MAX_MS: u32 = 600_000;

/// One slow key: when, and its two times.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Spike {
    pub at: Instant,
    /// `None`: the Mac's answer had not come when the echo did.
    pub ack_ms: Option<u32>,
    pub echo_ms: u32,
}

/// The keys typed since the last stat.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Window {
    pub echo: Vec<u32>,
    pub ack: Vec<u32>,
    /// Slowest first.
    pub spikes: Vec<Spike>,
    /// Every spike, kept or not.
    pub spike_count: u32,
}

/// Nearest-rank percentiles of one kind of time, with p99 (spikes are the point).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Summary {
    pub n: u32,
    pub p50: u32,
    pub p95: u32,
    pub p99: u32,
    pub max: u32,
}

impl Summary {
    pub fn of(samples: &[u32]) -> Option<Self> {
        if samples.is_empty() {
            return None;
        }
        let mut sorted = samples.to_vec();
        sorted.sort_unstable();
        let rank =
            |p: usize| sorted[(sorted.len() * p).div_ceil(100).saturating_sub(1).min(sorted.len() - 1)];
        Some(Self {
            n: u32::try_from(sorted.len()).unwrap_or(u32::MAX),
            p50: rank(50),
            p95: rank(95),
            p99: rank(99),
            max: sorted[sorted.len() - 1],
        })
    }
}

fn push(samples: &mut Vec<u32>, ms: u32) {
    if samples.len() >= MAX_SAMPLES {
        // Every other one: the shape stays, the size halves.
        let mut keep = false;
        samples.retain(|_| {
            keep = !keep;
            keep
        });
    }
    samples.push(ms.min(MAX_MS));
}

impl Window {
    pub fn ack(&mut self, ms: u32) {
        push(&mut self.ack, ms);
    }

    pub fn echo(&mut self, echo_ms: u32, ack_ms: Option<u32>, at: Instant) {
        push(&mut self.echo, echo_ms);
        if echo_ms <= SPIKE_MS {
            return;
        }
        self.spike_count = self.spike_count.saturating_add(1);
        let spike = Spike { at, ack_ms: ack_ms.map(|ms| ms.min(MAX_MS)), echo_ms: echo_ms.min(MAX_MS) };
        let place = self.spikes.partition_point(|kept| kept.echo_ms >= spike.echo_ms);
        if place < MAX_SPIKES {
            self.spikes.insert(place, spike);
            self.spikes.truncate(MAX_SPIKES);
        }
    }

    pub fn is_empty(&self) -> bool {
        self.echo.is_empty() && self.ack.is_empty()
    }
}

static WINDOW: Mutex<Window> =
    Mutex::new(Window { echo: Vec::new(), ack: Vec::new(), spikes: Vec::new(), spike_count: 0 });

fn window() -> std::sync::MutexGuard<'static, Window> {
    WINDOW.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The Mac answered a `send` `ms` after its first key's tap.
pub fn record_ack(ms: u32) {
    window().ack(ms);
}

/// The first output after a batch came `echo_ms` after its first key's tap; `ack_ms` when the
/// Mac's answer to it had already come.
pub fn record_echo(echo_ms: u32, ack_ms: Option<u32>) {
    window().echo(echo_ms, ack_ms, Instant::now());
}

/// The window since the last call, emptied.
pub fn take() -> Window {
    std::mem::take(&mut *window())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn spikes_keep_the_slowest_in_order_and_count_all() {
        let t0 = Instant::now();
        let mut w = Window::default();
        for (i, ms) in [20, 160, 900, 151, 150, 400, 300, 200, 700, 1000].into_iter().enumerate() {
            w.echo(ms, Some(ms / 2), t0 + Duration::from_secs(i as u64));
        }
        assert_eq!(w.spike_count, 8, "150 is not a spike, 151 is");
        assert_eq!(
            w.spikes.iter().map(|s| s.echo_ms).collect::<Vec<_>>(),
            vec![1000, 900, 700, 400, 300, 200]
        );
        assert_eq!(w.spikes[0].ack_ms, Some(500));
        assert_eq!(w.echo.len(), 10);
    }

    #[test]
    fn a_long_burst_stays_bounded() {
        let mut w = Window::default();
        for i in 0..10_000u32 {
            w.ack(10 + i % 7);
        }
        assert!(w.ack.len() <= MAX_SAMPLES);
        let s = Summary::of(&w.ack).unwrap();
        assert!((10..=16).contains(&s.p50) && s.max <= 16);
    }

    #[test]
    fn summary_is_nearest_rank() {
        assert_eq!(Summary::of(&[]), None);
        let s = Summary::of(&(1..=100).collect::<Vec<_>>()).unwrap();
        assert_eq!((s.n, s.p50, s.p95, s.p99, s.max), (100, 50, 95, 99, 100));
    }
}
