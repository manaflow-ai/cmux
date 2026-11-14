use crate::log::{Anchor, MAX_BLOB_READ, MAX_FRAME_BYTES};
use crate::testkit::{BlobFixture, blob_fixture, folded_book};
use std::io::Write;
use std::time::Instant;

fn emit(name: &str, small: u64, god: u64) {
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(
            file,
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"ns\"}}"
        )
        .unwrap();
    }
}

fn percentile(samples: &[u64]) -> u64 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted[(sorted.len().saturating_mul(95) / 100).min(sorted.len().saturating_sub(1))]
}

fn fold_sample(
    log: &mut crate::log::Log,
    bytes: &mut Vec<u8>,
    ranges: &mut Vec<std::ops::Range<usize>>,
) -> u64 {
    let start = Instant::now();
    let window = log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, &[]).unwrap();
    log.fill(&window.rows, bytes, ranges).unwrap();
    start.elapsed().as_nanos() as u64
}

#[test]
#[ignore]
fn v2_pr03c_fold_window() {
    let root = tempfile::tempdir().unwrap();
    let mut small_log = folded_book(&root.path().join("small"), 10);
    let mut god_log = folded_book(&root.path().join("god"), 100_000);
    let mut small_bytes = Vec::new();
    let mut small_ranges = Vec::new();
    let mut god_bytes = Vec::new();
    let mut god_ranges = Vec::new();
    let _ = fold_sample(&mut small_log, &mut small_bytes, &mut small_ranges);
    let _ = fold_sample(&mut god_log, &mut god_bytes, &mut god_ranges);
    let mut small = Vec::new();
    let mut god = Vec::new();
    for _ in 0..5 {
        small.push(fold_sample(&mut small_log, &mut small_bytes, &mut small_ranges));
        god.push(fold_sample(&mut god_log, &mut god_bytes, &mut god_ranges));
    }
    let small = percentile(&small);
    let god = percentile(&god);
    emit("v2.pr03c.fold_window", small, god);
    println!(
        "v2.pr03c.fold_window small_p95={small} god_p95={god} ratio={:.3}",
        god as f64 / small.max(1) as f64
    );
}

fn blob_sample(fixture: &mut BlobFixture, settled: &mut Vec<u8>, open: &mut Vec<u8>) -> u64 {
    let start = Instant::now();
    let range = fixture.log.read_blob_range(1, fixture.offset, MAX_BLOB_READ, settled).unwrap();
    assert_eq!(range.end.saturating_sub(range.start), settled.len() as u64);
    let total = fixture
        .blobs
        .read_open_range(&fixture.body, "text", fixture.offset, MAX_BLOB_READ, open)
        .unwrap();
    assert_eq!(total.saturating_sub(fixture.offset), open.len() as u64);
    start.elapsed().as_nanos() as u64
}

#[test]
#[ignore]
fn v2_pr03c_blob_range() {
    let root = tempfile::tempdir().unwrap();
    let mut small_fixture = blob_fixture(&root.path().join("small"), 300 * 1024);
    let mut god_fixture = blob_fixture(&root.path().join("god"), 100 * 1024 * 1024);
    let mut small_settled = Vec::with_capacity(MAX_BLOB_READ);
    let mut small_open = Vec::with_capacity(MAX_BLOB_READ);
    let mut god_settled = Vec::with_capacity(MAX_BLOB_READ);
    let mut god_open = Vec::with_capacity(MAX_BLOB_READ);
    let _ = blob_sample(&mut small_fixture, &mut small_settled, &mut small_open);
    let _ = blob_sample(&mut god_fixture, &mut god_settled, &mut god_open);
    let mut small = Vec::new();
    let mut god = Vec::new();
    for _ in 0..5 {
        small.push(blob_sample(&mut small_fixture, &mut small_settled, &mut small_open));
        god.push(blob_sample(&mut god_fixture, &mut god_settled, &mut god_open));
    }
    let small = percentile(&small);
    let god = percentile(&god);
    emit("v2.pr03c.blob_range", small, god);
    println!(
        "v2.pr03c.blob_range small_p95={small} god_p95={god} ratio={:.3}",
        god as f64 / small.max(1) as f64
    );
}
