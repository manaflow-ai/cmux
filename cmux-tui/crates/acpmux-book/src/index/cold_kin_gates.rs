//! Release gates for table-backed cold family reads (v2 row 5i).
use super::*;
use crate::gate_rounds::{self, best_p95};
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 20;
const LARGE_ROWS: usize = 11_000;
const SMALL_ROWS: usize = 20;

fn emit(name: &str, small: u128, god: u128, unit: &str) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"{unit}\"}}\n"
    );
    eprint!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = OpenOptions::new().create(true).append(true).open(path).unwrap();
        file.write_all(line.as_bytes()).unwrap();
    }
}

fn wall_rounds(
    mut small: impl FnMut() -> u128,
    mut god: impl FnMut() -> u128,
) -> (Vec<Vec<u128>>, Vec<Vec<u128>>) {
    let (mut a, mut b) = (Vec::with_capacity(ROUNDS), Vec::with_capacity(ROUNDS));
    for round in 0..ROUNDS {
        let mut av = Vec::with_capacity(SAMPLES);
        let mut bv = Vec::with_capacity(SAMPLES);
        for _ in 0..SAMPLES {
            let (x, y) = if round % 2 == 0 {
                (small(), god())
            } else {
                let y = god();
                let x = small();
                (x, y)
            };
            av.push(x);
            bv.push(y);
        }
        a.push(av);
        b.push(bv);
    }
    (a, b)
}

fn bytes_rounds(
    mut small: impl FnMut() -> usize,
    mut god: impl FnMut() -> usize,
) -> (Vec<Vec<u128>>, Vec<Vec<u128>>) {
    let (mut a, mut b) = (Vec::with_capacity(ROUNDS), Vec::with_capacity(ROUNDS));
    for round in 0..ROUNDS {
        let mut av = Vec::with_capacity(SAMPLES);
        let mut bv = Vec::with_capacity(SAMPLES);
        for _ in 0..SAMPLES {
            if round % 2 == 0 {
                av.push(small() as u128);
                bv.push(god() as u128);
            } else {
                bv.push(god() as u128);
                av.push(small() as u128);
            }
        }
        a.push(av);
        b.push(bv);
    }
    (a, b)
}

fn check(name: &str, rounds: (Vec<Vec<u128>>, Vec<Vec<u128>>), ratio: f64, unit: &str) {
    let (small, god) = rounds;
    gate_rounds::report(name, &[("small", &small), ("god", &god)]);
    let small_p95 = best_p95(&small);
    let god_p95 = best_p95(&god);
    emit(name, small_p95, god_p95, unit);
    assert!(god_p95 as f64 <= small_p95 as f64 * ratio, "{name}: {god_p95}/{small_p95}");
}

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id.into());
    row.last_activity = activity;
    row.state = "closed".to_owned();
    row
}

fn prepared(rows: usize, with_table: bool) -> (tempfile::TempDir, SummaryIndex, RowKey, RowKey) {
    assert!(rows >= 12);
    let directory = tempfile::tempdir().unwrap();
    let snapshot = directory.path().join("index.snap");
    let table = directory.path().join("index.snap.kin");
    let root = row("gate-family", 1);
    let root_key = root.key();
    let mut index = SummaryIndex::new().apply(1, root);
    let mut parent = row("gate-cold-parent", 2);
    parent.parent = Some(root_key.clone());
    let parent_key = parent.key();
    index = index.apply(2, parent);
    for n in 0..2 {
        let mut child = row(format!("gate-cold-grand-{n}"), 3 + n as u64);
        child.parent = Some(parent_key.clone());
        index = index.apply(3 + n as u64, child);
    }
    for n in 0..5 {
        let mut child = row(format!("gate-cold-direct-{n}"), 5 + n as u64);
        child.parent = Some(root_key.clone());
        index = index.apply(5 + n as u64, child);
    }
    let unread = row("gate-unread-root", 1);
    let unread_key = unread.key();
    index = index.apply(10, unread);
    let mut hot = row("gate-unread-child", 200);
    hot.parent = Some(unread_key.clone());
    index = index.apply(11, hot.clone());
    for n in 0..rows - 11 {
        let mut other = row(format!("gate-other-{n:05}"), 100 + n as u64);
        other.parent = Some(RowKey::new("local", "other-root"));
        index = index.apply(12 + n as u64, other);
    }
    assert_eq!(index.len(), rows);
    if with_table {
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
        .unwrap();
    } else {
        SortedSnapshot::write(&snapshot, &index).unwrap();
    }
    let disk = DiskSnapshot::open(snapshot).unwrap().unwrap();
    let mut restored = SummaryIndex::from_disk(Some(disk), 1);
    restored.raise_cold_before(100);
    restored = restored.apply(12, hot);
    (directory, restored, root_key, unread_key)
}
fn cold_filter(root: &RowKey) -> ListFilter {
    let mut f = ListFilter::family(root.clone());
    f.cold = true;
    f
}

fn assert_family(page: &IndexPage) {
    let mut keys: Vec<_> = page.rows.iter().map(|row| row.chat_id.as_str()).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "gate-cold-direct-0",
            "gate-cold-direct-1",
            "gate-cold-direct-2",
            "gate-cold-direct-3",
            "gate-cold-direct-4",
            "gate-cold-grand-0",
            "gate-cold-grand-1",
            "gate-cold-parent",
        ]
    );
    assert!(!page.has_after);
    // All eight kin, including both grandchildren, finish this walk in one
    // table-served page. The client follows only deeper for a closure walk;
    // this page therefore requires zero per-cold-row asks (decision 392).
    assert!(page.closure);
    assert!(page.deeper.is_empty());
}

fn sample_bytes(index: &SummaryIndex, root: &RowKey) -> usize {
    let before = super::snapshot::read_probe();
    let page = index
        .read_page(None, ReadSide::After, false, 8, 256 * 1024, Some(&cold_filter(root)))
        .unwrap();
    let after = super::snapshot::read_probe();
    assert_family(&page);
    assert_eq!(after.1 - before.1, 1);
    assert_eq!(after.2, before.2);
    let physical = after.0 - before.0;
    assert_eq!(physical, page.bytes_read);
    assert!(physical <= PAGE_BYTES);
    physical
}

fn sample_wall(index: &SummaryIndex, root: &RowKey) -> u128 {
    let before = super::snapshot::read_probe();
    let started = Instant::now();
    let page = index
        .read_page(None, ReadSide::After, false, 8, 256 * 1024, Some(&cold_filter(root)))
        .unwrap();
    let elapsed = started.elapsed().as_nanos();
    let after = super::snapshot::read_probe();
    assert_family(&page);
    assert_eq!(after.1 - before.1, 1);
    assert_eq!(after.2, before.2);
    elapsed
}

fn sample_unread(index: &SummaryIndex, root: &RowKey) -> u128 {
    let before = super::snapshot::read_probe();
    let started = Instant::now();
    let page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            400,
            256 * 1024,
            Some(&ListFilter::family(root.clone())),
        )
        .unwrap();
    let elapsed = started.elapsed().as_nanos();
    let after = super::snapshot::read_probe();
    assert!(!page.cold_unread);
    assert_eq!(after.0 - before.0, 8192);
    assert_eq!(after.1 - before.1, 1);
    assert_eq!(after.2, before.2);
    elapsed
}

#[test]
#[ignore = "release gate"]
fn cold_family_bytes_gate() {
    let (sd, s, sr, _) = prepared(SMALL_ROWS, true);
    let (gd, g, gr, _) = prepared(LARGE_ROWS, true);
    let r = bytes_rounds(|| sample_bytes(&s, &sr), || sample_bytes(&g, &gr));
    std::hint::black_box((sd, gd));
    check("v2.pr05i.cold_family_bytes", r, 1.2, "bytes");
}
#[test]
#[ignore = "release gate"]
fn cold_family_gate() {
    let (sd, s, sr, _) = prepared(SMALL_ROWS, true);
    let (gd, g, gr, _) = prepared(LARGE_ROWS, true);
    let r = wall_rounds(|| sample_wall(&s, &sr), || sample_wall(&g, &gr));
    std::hint::black_box((sd, gd));
    check("v2.pr05i.cold_family", r, 1.2, "ns");
}
#[test]
#[ignore = "release gate"]
fn cold_unread_gate() {
    let (sd, s, _, sr) = prepared(SMALL_ROWS, true);
    let (gd, g, _, gr) = prepared(LARGE_ROWS, true);
    let r = wall_rounds(|| sample_unread(&s, &sr), || sample_unread(&g, &gr));
    std::hint::black_box((sd, gd));
    check("v2.pr05i.cold_unread", r, 1.2, "ns");
}
