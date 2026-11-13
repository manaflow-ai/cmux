//! PR 5e: paired five-round release measurements over 20 / 11,000 hot rows.
use super::*;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;

fn emit(name: &str, small: u64, god: u64, all: Option<u64>, unit: &str) {
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

fn p95(samples: &mut [u64]) -> u64 {
    samples.sort_unstable();
    samples.get((samples.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap_or(1)
}

fn stats(samples: &[u64]) -> (u64, u64) {
    let best = samples.chunks_exact(SAMPLES).map(|round| p95(&mut round.to_vec())).min().unwrap();
    (best, p95(&mut samples.to_vec()))
}

// Warm each shape before its round; retain the returned root until after the clock.
// Alternating the order each round avoids assigning all scheduler drift to god.
fn paired<T>(mut small: impl FnMut() -> T, mut god: impl FnMut() -> T) -> (u64, u64, u64) {
    fn round<T>(f: &mut impl FnMut() -> T, samples: &mut Vec<u64>) {
        for _ in 0..32 {
            std::hint::black_box(f());
        }
        for _ in 0..SAMPLES {
            let start = Instant::now();
            let result = std::hint::black_box(f());
            samples.push(start.elapsed().as_nanos() as u64);
            drop(result);
        }
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
    (stats(&a).0, stats(&b).0, stats(&b).1)
}

fn check(name: &str, values: (u64, u64, u64), ratio: f64, all_ratio: f64, max: Option<u64>) {
    let (small, god, all) = values;
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
            .folder_rows(&FolderKey::new("local", "release-gate"))
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
    emit("v2.pr05e.cold_continuation", small, god, None, "bytes");
    // Sparse seeks have the existing 5b block bound; the per-request budget is fixed.
    assert!(god <= 256 * 1024);
}
