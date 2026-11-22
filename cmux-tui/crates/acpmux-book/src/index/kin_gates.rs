//! PR 5e: paired five-round release measurements over 20 / 11,000 hot rows.
use super::*;
use crate::gate_rounds::{self, all_p95, best_p95};
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;

fn emit(name: &str, small: u128, god: u128, all: Option<u128>, unit: &str) {
    let line = all.map_or_else(
        || format!("{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"{unit}\"}}"),
        |all| format!("{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{all},\"unit\":\"{unit}\"}}"),
    );
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(file, "{line}").unwrap();
    }
}

/// Each side's rounds of samples, small then god.
type Rounds = (Vec<Vec<u128>>, Vec<Vec<u128>>);

// Warm each shape before its round; retain the returned root until after the clock.
// Alternating the order each round avoids assigning all scheduler drift to god.
fn paired<T>(mut small: impl FnMut() -> T, mut god: impl FnMut() -> T) -> Rounds {
    fn round<T>(f: &mut impl FnMut() -> T, rounds: &mut Vec<Vec<u128>>) {
        for _ in 0..32 {
            std::hint::black_box(f());
        }
        let mut samples = Vec::with_capacity(SAMPLES);
        for _ in 0..SAMPLES {
            let start = Instant::now();
            let result = std::hint::black_box(f());
            samples.push(start.elapsed().as_nanos());
            drop(result);
        }
        rounds.push(samples);
    }
    let (mut a, mut b) = (Vec::new(), Vec::new());
    for n in 0..ROUNDS {
        if n % 2 == 0 {
            round(&mut small, &mut a);
            round(&mut god, &mut b);
        } else {
            round(&mut god, &mut b);
            round(&mut small, &mut a);
        }
    }
    (a, b)
}

fn check(name: &str, rounds: Rounds, ratio: f64, all_ratio: f64, max: Option<u128>) {
    let (small, god) = rounds;
    gate_rounds::report(name, &[("small", &small), ("god", &god)]);
    let (small, god, all) = (best_p95(&small), best_p95(&god), all_p95(&god));
    emit(name, small, god, Some(all), "ns");
    assert!(god as f64 <= small as f64 * ratio, "{name}: best {god}/{small}");
    assert!(all as f64 <= small as f64 * all_ratio, "{name}: all {all}/{small}");
    if let Some(max) = max {
        assert!(god <= max, "{name}: {god} > {max}");
    }
}

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id.into());
    row.last_activity = activity;
    row
}

fn fixture(unrelated: usize, siblings: usize, folder_rows: usize, deep: bool) -> SummaryIndex {
    let root = row("family-root", 1);
    let mut index = SummaryIndex::new().apply(1, root.clone());
    let mut seq = 2;
    for n in 0..siblings {
        let mut child = row(format!("child-{n:05}"), n as u64 + 2);
        child.parent = Some(if deep && n > 0 {
            RowKey::new("local", format!("child-{:05}", (n - 1) / 4))
        } else {
            root.key()
        });
        index = index.apply(seq, child);
        seq += 1;
    }
    for n in 0..folder_rows {
        let mut folder = row(format!("folder-{n:05}"), n as u64 + 2);
        folder.folder = Some("release-gate".to_owned());
        index = index.apply(seq, folder);
        seq += 1;
    }
    for n in 0..unrelated {
        let mut other = row(format!("unrelated-{n:05}"), n as u64 + 100_000);
        other.parent = Some(RowKey::new("local", format!("other-parent-{n:05}")));
        other.folder = Some(format!("other-folder-{n:05}"));
        index = index.apply(seq, other);
        seq += 1;
    }
    index
}

#[test]
#[ignore = "release gate"]
fn kin_table_change_gate() {
    let small = fixture(20, 1, 1, false);
    let god = fixture(11_000, 1, 1, false);
    let old = small.get_row(&RowKey::new("local", "unrelated-00000")).unwrap();
    let mut parent = old.as_ref().clone();
    parent.parent = Some(RowKey::new("local", "other-parent-00001"));
    check(
        "v2.pr05e.kin_table_change",
        paired(
            || small.kin().replace(Some(&old), Some(&parent)),
            || god.kin().replace(Some(&old), Some(&parent)),
        ),
        3.7,
        6.2,
        Some(10_000),
    );
    let mut folder = old.as_ref().clone();
    folder.folder = Some("other-folder-00001".to_owned());
    check(
        "v2.pr05e.folder_change",
        paired(
            || small.kin().replace(Some(&old), Some(&folder)),
            || god.kin().replace(Some(&old), Some(&folder)),
        ),
        3.7,
        6.2,
        Some(10_000),
    );
    let mut title = old.as_ref().clone();
    title.title = "changed title".to_owned();
    let writes = AtomicUsize::new(0);
    let unchanged = god.kin().replace_counted(Some(&old), Some(&title), &writes);
    assert_eq!(writes.load(AtomicOrdering::Relaxed), 1);
    assert_eq!(
        unchanged
            .folder_rows(&FolderKey::new("local", "other-folder-00000"))
            .and_then(|rows| rows.values().next())
            .map(|row| row.title.as_str()),
        Some("changed title")
    );
}

#[test]
#[ignore = "release gate"]
fn sibling_insert_gate() {
    let small = fixture(0, 5, 0, false);
    let god = fixture(0, 5_000, 0, false);
    let mut child = row("sibling-insert", 99);
    child.parent = Some(RowKey::new("local", "family-root"));
    // Tree rule: 1.2 * ln(5000)/ln(5), all-sample 2 * that height ratio.
    let height = 5_000_f64.ln() / 5_f64.ln();
    check(
        "v2.pr05e.sibling_insert",
        paired(
            || small.kin().replace(None, Some(&child)),
            || god.kin().replace(None, Some(&child)),
        ),
        1.2 * height,
        2.0 * height,
        Some(10_000),
    );
}

fn page_gate(name: &str, family: bool, anchored: bool) {
    let small = fixture(20, if family { 50 } else { 0 }, if family { 0 } else { 50 }, true);
    let god = fixture(11_000, if family { 50 } else { 0 }, if family { 0 } else { 50 }, true);
    let filter = if family {
        ListFilter::family(RowKey::new("local", "family-root"))
    } else {
        ListFilter::folder(FolderKey::new("local", "release-gate"))
    };
    let anchor = anchored
        .then(|| SortKey::of(&small.get_row(&RowKey::new("local", "child-00005")).unwrap()));
    let read = |index: &SummaryIndex| {
        index
            .read_page(anchor.as_ref(), ReadSide::After, false, 50, 256 * 1024, Some(&filter))
            .unwrap()
    };
    let a = read(&small);
    let b = read(&god);
    assert_eq!(
        a.rows.iter().map(|r| r.key()).collect::<Vec<_>>(),
        b.rows.iter().map(|r| r.key()).collect::<Vec<_>>()
    );
    assert_eq!(a.parent_steps, b.parent_steps);
    assert!(a.rows_read <= 51 && b.rows_read <= 51);
    let lookup_bound = if family { 51 + 64 + 1 } else { 1 };
    assert!(a.lookups <= lookup_bound && b.lookups <= lookup_bound);
    assert_eq!((a.bytes_read, b.bytes_read), (0, 0));
    check(name, paired(|| read(&small), || read(&god)), 1.2, 2.0, None);
}

#[test]
#[ignore = "release gate"]
fn family_page_gate() {
    page_gate("v2.pr05e.family_page", true, false);
}
#[test]
#[ignore = "release gate"]
fn family_page_after_gate() {
    page_gate("v2.pr05e.family_page_after", true, true);
}
#[test]
#[ignore = "release gate"]
fn folder_page_gate() {
    page_gate("v2.pr05e.folder_page", false, false);
}

#[test]
#[ignore = "release gate"]
fn random_replay_gate() {
    kin_lifecycle_tests::randomized_hot_lifecycle();
    emit("v2.pr05e.random_replay", 10_000, 10_000, None, "checks");
}

#[test]
#[ignore = "release gate"]
fn cold_continuation_gate() {
    fn scan(unrelated: usize) -> u64 {
        let source = fixture(unrelated, 0, 50, false);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("kin-gate.snap");
        SortedSnapshot::write(&path, &source).unwrap();
        let disk = DiskSnapshot::open(&path).unwrap().unwrap();
        let cold = SummaryIndex::from_disk(Some(disk), 1);
        let filter = ListFilter {
            folder: Some(FolderKey::new("local", "release-gate")),
            cold: true,
            ..Default::default()
        };
        let (mut anchor, mut found, mut max_bytes) = (None, 0, 0);
        for _ in 0..source.len() + 1 {
            let page = cold
                .read_page(anchor.as_ref(), ReadSide::After, false, 50, 4096, Some(&filter))
                .unwrap();
            assert!(page.bytes_read <= 256 * 1024);
            max_bytes = max_bytes.max(page.bytes_read as u64);
            found += page.rows.len();
            if !page.has_after {
                assert_eq!(found, 50);
                return max_bytes;
            }
            assert_ne!(anchor, page.after_key);
            anchor = page.after_key;
        }
        panic!("cold scan did not finish");
    }
    let small = scan(20);
    let god = scan(11_000);
    emit("v2.pr05e.cold_continuation", small.into(), god.into(), None, "bytes");
    // Sparse seeks have the existing 5b block bound; the per-request budget is fixed.
    assert!(god <= 256 * 1024);
}

#[test]
#[ignore = "release gate"]
fn kin_table_write_gate() {
    use super::snapshot::KinWriteStats;
    use std::io::Read;

    const ROWS: usize = 11_000;
    const ENTRIES: u64 = (ROWS - 1) as u64;
    const WRITE_SAMPLES: usize = 20;

    fn fixture() -> SummaryIndex {
        let mut root = row("kin-root", 1);
        root.state = "closed".to_owned();
        let root_key = root.key();
        let mut index = SummaryIndex::new().apply(1, root);
        for n in 0..ROWS - 1 {
            let mut child = row(format!("kin-child-{n:05}"), 2 + n as u64);
            child.state = "closed".to_owned();
            child.parent = Some(root_key.clone());
            index = index.apply(n as u64 + 2, child);
        }
        index
    }

    fn write_once(index: &SummaryIndex, with_table: bool) -> (u128, KinWriteStats) {
        let directory = tempfile::tempdir().unwrap();
        let snapshot = directory.path().join("index.snap");
        let table = directory.path().join("index.snap.kin");
        let start = Instant::now();
        let stats = if with_table {
            SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
                path: &snapshot,
                seq: index.seq(),
                log_offset: 0,
                log_name: None,
                covered_generation: 0,
                meta: SnapshotMeta::default(),
                rows: index.merged_rows(),
                table_path: Some(&table),
            })
            .unwrap()
        } else {
            SortedSnapshot::write_stream_generation(
                &snapshot,
                index.seq(),
                0,
                None,
                0,
                SnapshotMeta::default(),
                index.merged_rows(),
            )
            .unwrap();
            KinWriteStats::default()
        };
        let elapsed = start.elapsed().as_nanos();
        let written = DiskSnapshot::open(&snapshot).unwrap().unwrap();
        assert_eq!(written.len(), ROWS as u64, "snapshot row count");
        if with_table {
            let mut header = [0u8; 4096];
            std::fs::File::open(&table).unwrap().read_exact(&mut header).unwrap();
            let entries = u64::from_le_bytes(header[40..48].try_into().unwrap());
            assert_eq!(entries, ENTRIES, "sidecar closure count");
            let bytes = std::fs::metadata(&table).unwrap().len();
            assert!(bytes <= entries * 64 + 3 * 4096);
        }
        (elapsed, stats)
    }

    let index = fixture();
    assert_eq!(index.len(), ROWS);
    let mut small = Vec::new();
    let mut god = Vec::new();
    for round in 0..ROUNDS {
        let (first, second) = if round % 2 == 0 { (false, true) } else { (true, false) };
        let mut baseline_samples = Vec::with_capacity(WRITE_SAMPLES);
        let mut table_samples = Vec::with_capacity(WRITE_SAMPLES);
        let mut stream_samples = Vec::with_capacity(WRITE_SAMPLES);
        let mut closure_samples = Vec::with_capacity(WRITE_SAMPLES);
        let mut pages_samples = Vec::with_capacity(WRITE_SAMPLES);
        for _ in 0..WRITE_SAMPLES {
            let (first_ns, first_stats) = write_once(&index, first);
            let (second_ns, second_stats) = write_once(&index, second);
            let stats = if first {
                table_samples.push(first_ns);
                baseline_samples.push(second_ns);
                first_stats
            } else {
                baseline_samples.push(first_ns);
                table_samples.push(second_ns);
                second_stats
            };
            stream_samples.push(stats.stream_ns);
            closure_samples.push(stats.closure_ns);
            pages_samples.push(stats.pages_ns);
        }
        eprintln!(
            "GATE_WRITE_PHASE row=v2.pr05i.table_write round={} stream_p95={} closure_p95={} pages_p95={} unit=ns",
            round + 1,
            gate_rounds::p95(&stream_samples),
            gate_rounds::p95(&closure_samples),
            gate_rounds::p95(&pages_samples),
        );
        small.push(baseline_samples);
        god.push(table_samples);
    }
    let small_p95 = best_p95(&small);
    let god_p95 = best_p95(&god);
    gate_rounds::report("v2.pr05i.table_write", &[("small", &small), ("god", &god)]);
    emit("v2.pr05i.table_write", small_p95, god_p95, None, "ns");
    assert!(god_p95 as f64 <= small_p95 as f64 * 1.5);
}
