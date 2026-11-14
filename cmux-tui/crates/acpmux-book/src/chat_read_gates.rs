use crate::log::{Anchor, Log, MAX_BLOB_READ, MAX_FRAME_BYTES, Options, RawRange};
use crate::testkit::open;
use std::io::Write;
use std::path::Path;
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

fn folded_book(path: &Path, rows: u64) -> Log {
    let (mut log, _) = Log::open(path, Options::default()).unwrap();
    for id in 2..=rows {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    let group = format!("{{\"body\":{{\"out\":[[2,2],[{} ,{}]]}}}}", rows, rows);
    log.append_settled(1, 1, RawRange::NONE, group.as_bytes()).unwrap();
    let mut folds = crate::folds::Folds::open(&path.join("folds.idx"), 0).unwrap();
    folds.append(1, rows).unwrap();
    folds.sync().unwrap();
    log
}

fn fold_sample(path: &Path, rows: u64) -> u64 {
    let mut log = folded_book(path, rows);
    let start = Instant::now();
    let window = log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, &[]).unwrap();
    let mut bytes = Vec::new();
    let mut ranges = Vec::new();
    log.fill(&window.rows, &mut bytes, &mut ranges).unwrap();
    start.elapsed().as_nanos() as u64
}

#[test]
#[ignore]
fn v2_pr03c_fold_window() {
    let root = tempfile::tempdir().unwrap();
    let mut small = Vec::new();
    let mut god = Vec::new();
    for round in 0..5 {
        small.push(fold_sample(&root.path().join(format!("small-{round}")), 10));
        god.push(fold_sample(&root.path().join(format!("god-{round}")), 100_000));
    }
    let small = percentile(&small);
    let god = percentile(&god);
    emit("v2.pr03c.fold_window", small, god);
    println!(
        "v2.pr03c.fold_window small_p95={small} god_p95={god} ratio={:.3}",
        god as f64 / small.max(1) as f64
    );
}

fn blob_sample(bytes: usize) -> u64 {
    let root = tempfile::tempdir().unwrap();
    let mut log = open(root.path()).0;
    let body = vec![b'x'; bytes];
    log.write_blob(1, &body).unwrap();
    let mut out = Vec::new();
    let start = Instant::now();
    let range = log
        .read_blob_range(1, bytes.saturating_sub(MAX_BLOB_READ) as u64, MAX_BLOB_READ, &mut out)
        .unwrap();
    assert_eq!(range.end.saturating_sub(range.start), out.len() as u64);
    start.elapsed().as_nanos() as u64
}

#[test]
#[ignore]
fn v2_pr03c_blob_range() {
    let mut small = Vec::new();
    let mut god = Vec::new();
    for _ in 0..5 {
        small.push(blob_sample(300 * 1024));
        god.push(blob_sample(100 * 1024 * 1024));
    }
    let small = percentile(&small);
    let god = percentile(&god);
    emit("v2.pr03c.blob_range", small, god);
    println!(
        "v2.pr03c.blob_range small_p95={small} god_p95={god} ratio={:.3}",
        god as f64 / small.max(1) as f64
    );
}
