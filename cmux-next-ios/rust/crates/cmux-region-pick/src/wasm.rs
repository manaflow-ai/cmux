//! The surface the mobile Worker calls (`backend/src/region-pick.ts`), as plain `extern "C"`
//! exports over one shared `f64` buffer, so the wasm needs no bindgen glue and no allocator calls.
//!
//! Buffer layout ([`IO_LEN`] `f64`s, read by [`rp_pick`]):
//!
//! | index | meaning |
//! |---|---|
//! | `0..9` | estimate per region, ms (NaN: unknown) |
//! | `9..18` | learned ms per region (NaN: nothing learned) |
//! | `18..27` | learned sample count per region |
//! | `27` | current region index (-1: none) |
//! | `28` | fallback region index (-1: none) |
//! | `29` | out: picked region index (-1: none) |
//! | `30` | out: how ([`BY_MEASURED`], [`BY_CALIBRATED`], [`BY_FALLBACK`]) |
//! | `31` | out: the pick's score, ms (NaN for a fallback) |
//!
//! The layout is versioned by [`rp_abi`]: a TS loader that finds another number refuses the wasm
//! and keeps today's placement.

use crate::{By, Learned, N, Pick, observe, pick};

/// The buffer's length in `f64`s.
pub const IO_LEN: usize = 32;
/// The layout's version; bump it with any change to the table above.
pub const ABI: u32 = 1;
pub const BY_MEASURED: f64 = 0.0;
pub const BY_CALIBRATED: f64 = 1.0;
pub const BY_FALLBACK: f64 = 2.0;

const LEARNED_MS: usize = N;
const LEARNED_N: usize = 2 * N;
const CURRENT: usize = 3 * N;
const FALLBACK: usize = CURRENT + 1;
const OUT_REGION: usize = FALLBACK + 1;
const OUT_BY: usize = OUT_REGION + 1;
const OUT_MS: usize = OUT_BY + 1;
const _: () = assert!(OUT_MS + 1 == IO_LEN);

fn index(v: f64) -> Option<usize> {
    (v.is_finite() && v >= 0.0 && v < N as f64 && v.fract() == 0.0).then_some(v as usize)
}

/// Reads the inputs from `io`, picks, writes the outputs back.
pub fn run(io: &mut [f64; IO_LEN]) {
    let mut estimate = [None; N];
    let mut learned = [None; N];
    for r in 0..N {
        let e = io[r];
        estimate[r] = e.is_finite().then_some(e);
        let (ms, n) = (io[LEARNED_MS + r], io[LEARNED_N + r]);
        learned[r] = (ms.is_finite() && n.is_finite() && n >= 1.0)
            .then(|| Learned { ms, n: n.min(u32::MAX as f64) as u32 });
    }
    let Pick { region, by, ms } = pick(&estimate, &learned, index(io[CURRENT]), index(io[FALLBACK]));
    io[OUT_REGION] = region.map_or(-1.0, |r| r as f64);
    io[OUT_BY] = match by {
        By::Measured => BY_MEASURED,
        By::Calibrated => BY_CALIBRATED,
        By::Fallback => BY_FALLBACK,
    };
    io[OUT_MS] = ms.unwrap_or(f64::NAN);
}

/// [`observe`] over plain numbers: the new learned ms, or NaN when the sample is refused (the
/// caller keeps its row as it was). `prev_n` below 1 means nothing learned yet; on a number the
/// caller stores it with `prev_n + 1` samples.
pub fn observe_ms(prev_ms: f64, prev_n: f64, sample: f64) -> f64 {
    let prev = (prev_ms.is_finite() && prev_n >= 1.0)
        .then(|| Learned { ms: prev_ms, n: prev_n.min(u32::MAX as f64) as u32 });
    match observe(prev, sample) {
        Some(l) if Some(l) != prev => l.ms,
        _ => f64::NAN,
    }
}

#[cfg(target_arch = "wasm32")]
mod exports {
    use super::{ABI, IO_LEN, observe_ms, run};
    use core::cell::UnsafeCell;

    struct Io(UnsafeCell<[f64; IO_LEN]>);
    // SAFETY: a wasm32-unknown-unknown instance runs on one thread.
    unsafe impl Sync for Io {}
    static IO: Io = Io(UnsafeCell::new([0.0; IO_LEN]));

    /// The layout version ([`ABI`]).
    #[unsafe(no_mangle)]
    pub extern "C" fn rp_abi() -> u32 {
        ABI
    }

    /// Where the buffer is, as a byte offset into the instance's memory.
    #[unsafe(no_mangle)]
    pub extern "C" fn rp_io() -> *mut f64 {
        IO.0.get().cast()
    }

    /// Picks from the buffer's inputs into its outputs.
    #[unsafe(no_mangle)]
    pub extern "C" fn rp_pick() {
        // SAFETY: one thread, and no reference to the buffer outlives this call.
        run(unsafe { &mut *IO.0.get() });
    }

    /// See [`observe_ms`].
    #[unsafe(no_mangle)]
    pub extern "C" fn rp_observe_ms(prev_ms: f64, prev_n: f64, sample: f64) -> f64 {
        observe_ms(prev_ms, prev_n, sample)
    }
}
