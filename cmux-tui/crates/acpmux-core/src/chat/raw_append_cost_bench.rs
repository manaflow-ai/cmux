//! What one raw append costs as the chat grows (Leo: "even if a chat is long, there should be no
//! percievable difference"): `RawWriter::append` on a 20-line chat and on a god chat of 80,000
//! lines of 12 KiB (about 1 GB, written for real, with its index).
//! Manual: `cargo test -p acpmux-core --lib raw_append_cost -- --ignored --nocapture
//! --test-threads=1`. Each home prints `RAW-OPEN-COST home=<home> ms=<x>` and
//! `RAW-APPEND-COST home=<home> n=<N> p50_us=<x> p95_us=<y>`.
//! It uses only API that predates cmux#44397's review items, so it runs before and after them.

use super::*;
use std::time::Instant;

const LINE_BYTES: usize = 12 * 1024;
const APPENDS: usize = 2_000;

fn percentile(sorted: &[u128], pct: usize) -> u128 {
    let at = (sorted.len().saturating_sub(1)).saturating_mul(pct) / 100;
    sorted.get(at).copied().unwrap_or_default()
}

/// Build one home with `lines` lines, reopen it (timed), then time `APPENDS` appends.
/// Returns the p95 in microseconds.
fn measure(home: &str, lines: usize) -> io::Result<u128> {
    let dir = tempfile::tempdir()?;
    let raw = dir.path().join("events.ndjson");
    let index = dir.path().join("events.idx");
    let line = vec![b'x'; LINE_BYTES];
    {
        let mut writer = RawWriter::open_with_index(&raw, Some(&index), 0)?;
        for _ in 0..lines {
            writer.append(&line, false)?;
        }
        writer.sync()?;
    }
    let started = Instant::now();
    let mut writer = RawWriter::open_with_index(&raw, Some(&index), lines as u64)?;
    let open_ms = started.elapsed().as_secs_f64() * 1e3;
    println!("RAW-OPEN-COST home={home} ms={open_ms:.2}");
    let mut took = Vec::with_capacity(APPENDS);
    for _ in 0..APPENDS {
        let started = Instant::now();
        std::hint::black_box(writer.append(&line, false)?);
        took.push(started.elapsed().as_micros());
    }
    took.sort_unstable();
    let p50 = percentile(&took, 50);
    let p95 = percentile(&took, 95);
    println!("RAW-APPEND-COST home={home} n={APPENDS} p50_us={p50} p95_us={p95}");
    Ok(p95)
}

#[test]
#[ignore = "manual per-append cost measurement; writes about 1 GB"]
fn raw_append_cost() -> io::Result<()> {
    let small = measure("small", 20)?;
    let god = measure("god", 80_000)?;
    assert!(
        god * 10 <= small * 12 + 250,
        "god p95 {god} us is over 1.2 x small p95 {small} us + 25 us"
    );
    Ok(())
}
