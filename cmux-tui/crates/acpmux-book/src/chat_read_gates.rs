//! Book reads at fixed reply size, in five alternating steady-state rounds.
use crate::log::{Anchor, MAX_BLOB_READ, MAX_FRAME_BYTES};
use crate::testkit::{BlobFixture, blob_fixture, folded_book, ids};
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;
const WARMUP: usize = 32;

#[derive(Clone, Copy)]
struct Measures {
    small: u64,
    god: u64,
    small_all: u64,
    god_all: u64,
}

impl Measures {
    fn ratio(self) -> f64 {
        self.god as f64 / self.small.max(1) as f64
    }

    fn report(self, name: &str, mode: &str) {
        println!(
            "{name} mode={mode} small_p95={} god_p95={} ratio={:.3} small_p95_all={} god_p95_all={} ratio_all={:.3}",
            self.small,
            self.god,
            self.ratio(),
            self.small_all,
            self.god_all,
            self.god_all as f64 / self.small.max(1) as f64,
        );
    }

    fn check(self, name: &str, mode: &str) {
        assert!(
            self.god as f64 <= self.small as f64 * 1.2,
            "{name} {mode}: best p95 ratio exceeds 1.2"
        );
        // The registry compares the pooled god p95 with the same best small p95.
        assert!(
            self.god_all as f64 <= self.small as f64 * 2.0,
            "{name} {mode}: pooled p95 ratio exceeds 2"
        );
    }
}

fn emit(name: &str, measures: Measures) {
    let Measures { small, god, god_all, .. } = measures;
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"ns\"}}"
    );
    println!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(file, "{line}").unwrap();
    }
}

fn percentile(samples: &[u64]) -> u64 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted.get((sorted.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap()
}

fn paired(
    name: &str,
    mode: &str,
    mut small: impl FnMut() -> u64,
    mut god: impl FnMut() -> u64,
) -> Measures {
    fn round(sample: &mut impl FnMut() -> u64, into: &mut Vec<u64>) -> u64 {
        for _ in 0..WARMUP {
            std::hint::black_box(sample());
        }
        let start = into.len();
        for _ in 0..SAMPLES {
            into.push(sample());
        }
        percentile(into.get(start..).unwrap())
    }
    let (mut small_samples, mut god_samples) = (Vec::new(), Vec::new());
    let (mut small_best, mut god_best) = (u64::MAX, u64::MAX);
    for number in 1..=ROUNDS {
        // Each god round follows its small twin, rather than paying all of one side first.
        let small_round = round(&mut small, &mut small_samples);
        let god_round = round(&mut god, &mut god_samples);
        small_best = small_best.min(small_round);
        god_best = god_best.min(god_round);
        println!("{name} mode={mode} round={number} small_p95={small_round} god_p95={god_round}");
    }
    let measures = Measures {
        small: small_best,
        god: god_best,
        small_all: percentile(&small_samples),
        god_all: percentile(&god_samples),
    };
    measures.report(name, mode);
    measures
}

fn fold_sample(
    log: &mut crate::log::Log,
    folds: &crate::folds::Folds,
    bytes: &mut Vec<u8>,
    ranges: &mut Vec<std::ops::Range<usize>>,
) -> u64 {
    let entries_before = log.stats().walk_entries;
    let start = Instant::now();
    let window = log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, Some(folds), &[]).unwrap();
    log.fill(&window.rows, bytes, ranges).unwrap();
    std::hint::black_box((&window, &bytes, &ranges));
    let elapsed = start.elapsed().as_nanos() as u64;
    // Check outside the clock that both shapes answered the same visible rows and text.
    assert_eq!(ids(&window.rows), [1, 2, 3]);
    assert_eq!(log.stats().walk_entries - entries_before, 3);
    assert!(window.refused.is_empty());
    assert!(!window.has_before && !window.has_after);
    assert_eq!(ranges.len(), 3);
    for (range, expected) in
        ranges.iter().zip([br#"{"body":{"out":[[2,3]]}}"#.as_slice(), b"{}", b"{}"])
    {
        assert_eq!(bytes.get(range.clone()).unwrap(), expected);
    }
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_fold_window() {
    let root = tempfile::tempdir().unwrap();
    let (mut small_log, small_folds) = folded_book(&root.path().join("small"), 10);
    let (mut god_log, god_folds) = folded_book(&root.path().join("god"), 100_000);
    let (mut small_bytes, mut small_ranges) = (Vec::new(), Vec::new());
    let (mut god_bytes, mut god_ranges) = (Vec::new(), Vec::new());
    let name = "v2.pr03c.fold_window";
    let measures = paired(
        name,
        "fold",
        || fold_sample(&mut small_log, &small_folds, &mut small_bytes, &mut small_ranges),
        || fold_sample(&mut god_log, &god_folds, &mut god_bytes, &mut god_ranges),
    );
    emit(name, measures);
    measures.check(name, "fold");
}

fn blob_sample(fixture: &mut BlobFixture, open: bool, bytes: &mut Vec<u8>) -> u64 {
    let start = Instant::now();
    let (range_start, range_end, total) = if open {
        let range = fixture
            .blobs
            .read_open_range(&fixture.body, fixture.offset, MAX_BLOB_READ, bytes)
            .unwrap();
        (range.start, range.end, range.total)
    } else {
        let range = fixture.log.read_blob_range(1, fixture.offset, MAX_BLOB_READ, bytes).unwrap();
        (range.start, range.end, range.total)
    };
    std::hint::black_box(&bytes);
    let elapsed = start.elapsed().as_nanos() as u64;
    assert_eq!(bytes.len(), MAX_BLOB_READ);
    assert_eq!(range_start, fixture.offset);
    assert_eq!(range_end, total);
    assert_eq!(total, fixture.body.len());
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_blob_range() {
    let root = tempfile::tempdir().unwrap();
    let mut small = blob_fixture(&root.path().join("small"), 300 * 1024);
    let mut god = blob_fixture(&root.path().join("god"), 100 * 1024 * 1024);
    let (mut small_bytes, mut god_bytes) =
        (Vec::with_capacity(MAX_BLOB_READ), Vec::with_capacity(MAX_BLOB_READ));
    let name = "v2.pr03c.blob_range";
    let mut results = Vec::new();
    for (mode, open) in [("settled", false), ("open", true)] {
        let measures = paired(
            name,
            mode,
            || blob_sample(&mut small, open, &mut small_bytes),
            || blob_sample(&mut god, open, &mut god_bytes),
        );
        assert_eq!(small_bytes, god_bytes);
        assert_eq!(small_bytes.get(MAX_BLOB_READ - 2..).unwrap(), b"\"}");
        assert!(small_bytes.get(..MAX_BLOB_READ - 2).unwrap().iter().all(|byte| *byte == b'x'));
        results.push((mode, measures));
    }
    // One registry row covers both modes; report the worse pair, and gate each mode itself.
    let worst = results
        .iter()
        .map(|(_, measure)| *measure)
        .max_by(|a, b| a.ratio().total_cmp(&b.ratio()))
        .unwrap();
    emit(name, worst);
    for (mode, measures) in results {
        measures.check(name, mode);
    }
}
