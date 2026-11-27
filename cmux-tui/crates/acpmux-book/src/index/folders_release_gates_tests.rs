use super::*;
use crate::gate_rounds::{self, all_p95, best_p95};
use std::fs::OpenOptions;
use std::hint::black_box;
use std::io::Write;
use std::process::Command;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;
const HELD_VERSIONS: usize = 1_000;

fn timed<F: FnMut() -> u128>(mut sample: F) -> Vec<Vec<u128>> {
    (0..ROUNDS).map(|_| (0..SAMPLES).map(|_| sample()).collect()).collect()
}

/// The row's rounds through [`gate_rounds::report`], then its line: each side's best round
/// and every god sample's p95.
fn gate_rounds_row(name: &str, small: &[Vec<u128>], god: &[Vec<u128>]) {
    gate_rounds::report(name, &[("small", small), ("god", god)]);
    gate(name, best_p95(small), best_p95(god), all_p95(god), "ns");
}

fn gate(name: &str, small: u128, god: u128, god_all: u128, unit: &str) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"{unit}\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn fixture_entries(count: usize) -> Vec<FolderEntry> {
    (0..count)
        .map(|n| {
            FolderEntry::new(
                "local",
                format!("/folder-{n:04}"),
                Some(RowKey::new("local", format!("chat-{n:05}"))),
                (count - n) as u64,
                1,
            )
        })
        .collect()
}

fn build_view(entries: &[FolderEntry]) -> Folders {
    entries
        .iter()
        .cloned()
        .try_fold(Folders::new(), |folders, entry| folders.apply(entry).map(|(folders, _)| folders))
        .expect("fixture entry")
}

fn fixture(count: usize) -> Folders {
    build_view(&fixture_entries(count))
}

fn apply_newest(folders: &Folders, entry: FolderEntry) -> u128 {
    let started = Instant::now();
    let next = folders.apply(entry).expect("newest update").0;
    black_box(next);
    started.elapsed().as_nanos().max(1)
}

fn apply_move(folders: &Folders, remove: FolderEntry, insert: FolderEntry) -> u128 {
    let started = Instant::now();
    let (next, _) = folders.apply(remove).expect("old folder removal");
    let next = next.apply(insert).expect("new folder insert").0;
    black_box(next);
    started.elapsed().as_nanos().max(1)
}

fn page_window(folders: &Folders) -> u128 {
    let started = Instant::now();
    let first = folders.window(3, MAX_FOLDER_PAGE_BYTES).expect("first window");
    black_box(first);
    started.elapsed().as_nanos().max(1)
}

fn deep_page(folders: &Folders, cursor: &FolderCursor) -> u128 {
    let started = Instant::now();
    let page = folders.page_after(Some(cursor), 3, MAX_FOLDER_PAGE_BYTES).expect("deep page");
    black_box(page);
    started.elapsed().as_nanos().max(1)
}

fn resident_kib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    status.lines().find(|line| line.starts_with("VmRSS:"))?.split_whitespace().nth(1)?.parse().ok()
}

fn resident_probe(count: usize) -> Option<(u64, u64, usize)> {
    let output = Command::new(std::env::current_exe().ok()?)
        .args([
            "index::folders::release_gates::resident_probe_entry",
            "--exact",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("FOLDERS_RSS_COUNT", count.to_string())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line =
        stdout.lines().find_map(|line| line.split_once("folders_rss ").map(|(_, rest)| rest))?;
    let mut values = line.split_whitespace();
    let view = values.next()?.strip_prefix("view_kib=")?.parse().ok()?;
    let held = values.next()?.strip_prefix("held_kib=")?.parse().ok()?;
    let encoded = values.next()?.strip_prefix("encoded_bytes=")?.parse().ok()?;
    Some((view, held, encoded))
}

#[test]
fn resident_probe_entry() {
    let Ok(count) = std::env::var("FOLDERS_RSS_COUNT")
        .and_then(|value| value.parse::<usize>().map_err(|_| std::env::VarError::NotPresent))
    else {
        return;
    };
    let entries = fixture_entries(count);
    let before = resident_kib().unwrap_or_default();
    let view = build_view(&entries);
    black_box(&view);
    let after = resident_kib().unwrap_or_default();
    let view_rise = after.saturating_sub(before);
    let mut held = Vec::with_capacity(HELD_VERSIONS);
    held.push(view.clone());
    let held_before = resident_kib().unwrap_or_default();
    for n in 0..HELD_VERSIONS {
        let entry = FolderEntry::new(
            "local",
            format!("/held-{n:04}"),
            Some(RowKey::new("local", format!("held-chat-{n:04}"))),
            20_000 + n as u64,
            1,
        );
        let next = held.last().expect("held view").apply(entry).expect("held update").0;
        held.push(next);
    }
    black_box(&held);
    let held_after = resident_kib().unwrap_or_default();
    let held_rise = held_after.saturating_sub(held_before);
    let encoded: usize = view.iter().map(|row| row.encoded_len() + 1).sum();
    println!("folders_rss view_kib={view_rise} held_kib={held_rise} encoded_bytes={encoded}");
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_apply_newest() {
    let small = fixture(5);
    let god = fixture(2_000);
    let small_entry = FolderEntry::new(
        "local",
        "/folder-0000",
        Some(RowKey::new("local", "chat-newest")),
        10_000,
        1,
    );
    let god_entry = small_entry.clone();
    let small_rounds = timed(|| apply_newest(&small, small_entry.clone()));
    let god_rounds = timed(|| apply_newest(&god, god_entry.clone()));
    gate_rounds_row("v2.pr05f.apply_newest", &small_rounds, &god_rounds);
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_apply_move() {
    let small = fixture(5);
    let god = fixture(2_000);
    let remove = FolderEntry::new("local", "/folder-0000", None, 0, 0);
    let insert = FolderEntry::new(
        "local",
        "/folder-moved",
        Some(RowKey::new("local", "chat-0000")),
        10_000,
        1,
    );
    let small_rounds = timed(|| apply_move(&small, remove.clone(), insert.clone()));
    let god_rounds = timed(|| apply_move(&god, remove.clone(), insert.clone()));
    gate_rounds_row("v2.pr05f.apply_move", &small_rounds, &god_rounds);
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_first_window() {
    let small = fixture(5);
    let god = fixture(2_000);
    let small_rounds = timed(|| page_window(&small));
    let god_rounds = timed(|| page_window(&god));
    gate_rounds_row("v2.pr05f.first_window", &small_rounds, &god_rounds);
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_deep_page() {
    let small = fixture(5);
    let god = fixture(2_000);
    let cursor =
        god.iter().nth(1_000).map(|row| FolderCursor::new(row.at, row.key())).expect("deep cursor");
    let small_cursor =
        small.iter().next().map(|row| FolderCursor::new(row.at, row.key())).expect("small cursor");
    let small_rounds = timed(|| deep_page(&small, &small_cursor));
    let god_rounds = timed(|| deep_page(&god, &cursor));
    gate_rounds_row("v2.pr05f.deep_page", &small_rounds, &god_rounds);
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_equal_entry() {
    let small = fixture(5);
    let god = fixture(2_000);
    let equal_small =
        FolderEntry::new("local", "/folder-0000", Some(RowKey::new("local", "chat-00000")), 5, 1);
    let equal_god = FolderEntry::new(
        "local",
        "/folder-0000",
        Some(RowKey::new("local", "chat-00000")),
        2_000,
        1,
    );
    assert!(small.apply(equal_small).expect("equal small").1.is_none());
    assert!(god.apply(equal_god).expect("equal god").1.is_none());
    gate("v2.pr05f.equal_entry", 0, 0, 0, "ops");
}

#[test]
#[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
fn pr05f_resident_rss() {
    let (small_rise, _, _) = resident_probe(5).expect("small resident probe");
    let (god_rise, held_rise, encoded) = resident_probe(2_000).expect("god resident probe");
    assert!(encoded < 1_024 * 1_024, "published folder rows exceed 1 MB: {encoded}");
    assert!(god_rise <= 1_024, "folders view resident rise {god_rise} KiB exceeds 1 MB");
    let view_kib = god_rise.max(1);
    let per_version_rise = held_rise / HELD_VERSIONS as u64;
    assert!(
        per_version_rise <= view_kib.saturating_mul(2) / 100 + 1,
        "each held version resident rise {per_version_rise} KiB exceeds 2% of view rise {view_kib} KiB"
    );
    eprintln!(
        "PR5f resident small_rise_kib={small_rise} god_rise_kib={god_rise} held_rise_kib={held_rise} encoded_bytes={encoded}"
    );
}
