//! Ignored release measurement for a peer's `all` page (decision 266): the serving side's
//! read of this machine's rows, newest and deep, with 11,028 closed rows beside 20 live
//! against 20 closed. On both sides a third machine's run of rows sits just before the last
//! 20 closed rows, so the deep page skips it on both. 11,028 is 20 past a multiple of 256,
//! the snapshot's records per checkpoint, as the small side's 20 is: each snapshot piece's
//! seek then decodes the same records from its checkpoint on both sides, which the gate
//! asserts outside the clock.

use super::*;
use crate::wire::{ListKey, ListView, Page, PageResult};
use acpmux_book::gate_rounds;
use acpmux_book::index::{DiskSnapshot, SortedSnapshot};
use serde_json::Value;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 10;
const SAMPLES: usize = 200;
const LIVE: u64 = 20;
const ROWS: usize = 20;
const THIRD: u64 = 500;
/// The large side's closed rows: 11,000 and more, and the same place in a checkpoint's block
/// as the small side's (see the module comment).
const GOD_CLOSED: u64 = 11_028;

fn row(origin: &str, id: String, activity: u64, closed: bool) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.to_owned();
    summary.state = if closed { "closed" } else { "running" }.to_owned();
    summary.title = "a row of fixed width".to_owned();
    summary.last_activity = activity;
    summary
}

/// One side: 20 live rows of this machine, `closed` closed rows of this machine, newest
/// first, with a third machine's run of 500 just before the last 20 closed. The pages: the
/// newest, and the deepest full one, which starts after the local row before the run.
struct Side {
    hub: Hub,
    /// The sorted snapshot `disk` reads, for the seek probe.
    path: PathBuf,
    /// The same rows read from a sorted snapshot on disk: every page reads snapshot pieces.
    disk: Hub,
    _dir: tempfile::TempDir,
    newest: Page,
    deep: Page,
}

fn fixture(closed: u64) -> Side {
    let mut index = SummaryIndex::new();
    let mut seq = 0;
    let mut at = 1_000_000_000;
    let mut add = |index: SummaryIndex, summary: Summary| {
        seq += 1;
        index.apply(seq, summary)
    };
    let key = |at: u64, n: u64| ListKey {
        last_activity: at,
        chat_id: format!("b-{n:06}"),
        origin: "local".into(),
        past: false,
    };
    let mut last_local = None;
    for n in 0..LIVE {
        at -= 1;
        index = add(index, row("local", format!("b-{n:06}"), at, false));
        last_local = Some(key(at, n));
    }
    let mut deep = None;
    for n in 0..closed {
        if n + ROWS as u64 == closed {
            deep = last_local.clone();
            for m in 0..THIRD {
                at -= 1;
                index = add(index, row("c-machine", format!("c-{m:06}"), at, false));
            }
        }
        at -= 1;
        index = add(index, row("local", format!("b-{:06}", LIVE + n), at, true));
        last_local = Some(key(at, LIVE + n));
    }
    let row_bytes = index.get("b-000000").expect("a local row").encoded_len() + 1;
    let dir = tempfile::tempdir().expect("a snapshot dir");
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &index).expect("the snapshot is written");
    let on_disk =
        SummaryIndex::from_disk(DiskSnapshot::open(&path).expect("the snapshot opens"), 1);
    let (hub, _writer) = Hub::new(index);
    let (disk, _writer) = Hub::new(on_disk);
    let mut newest = Page::new("serve-gate", "list", PageSide::After, 0);
    newest.after = None;
    newest.view = Some(ListView::All);
    newest.max_bytes = u32::try_from(8192 + newest.sid.len() + ROWS * row_bytes).unwrap();
    let mut deep_page = newest.clone();
    deep_page.after = Some(Position::List(deep.expect("closed rows past one page")));
    Side { hub, disk, path, _dir: dir, newest, deep: deep_page }
}

/// The page's rows, the pieces it read and their snapshot bytes.
fn rows(hub: &Hub, page: &Page) -> (Vec<Value>, usize, usize) {
    PEER_PIECES.with(|read| read.set((0, 0)));
    PEER_ANCHORS.with(|read| read.borrow_mut().clear());
    let frame = hub.peer_page(page).expect("a peer's all page");
    let (pieces, bytes) = PEER_PIECES.with(|read| read.get());
    let result: PageResult<Value> = frame.decode_json().expect("a page");
    (result.rows, pieces, bytes)
}

fn sample(hub: &Hub, page: &Page) -> u128 {
    let started = Instant::now();
    let frame = hub.peer_page(page).expect("a peer's all page");
    let elapsed = started.elapsed().as_nanos();
    std::hint::black_box(frame);
    elapsed
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08b_serve_page() {
    // Leaked so a part's closure may hand out the sides' hubs; the test ends with the process.
    let small: &'static Side = Box::leak(Box::new(fixture(ROWS as u64)));
    let god: &'static Side = Box::leak(Box::new(fixture(GOD_CLOSED)));
    // What each side holds and answers, checked outside the clock.
    let mut scans = Vec::new();
    for (name, side, closed) in [("small", small, ROWS as u64), ("god", god, GOD_CLOSED)] {
        let index = side.hub.snapshot();
        assert_eq!(index.len() as u64, LIVE + closed + THIRD, "{name}: rows held");
        let third = (0..THIRD)
            .filter(|m| index.get_row(&RowKey::new("c-machine", format!("c-{m:06}"))).is_none())
            .count();
        assert_eq!(third, 0, "{name}: every third-machine row is held");
        for (part, hub, page) in [
            ("newest", &side.hub, &side.newest),
            ("deep", &side.hub, &side.deep),
            ("snapshot_deep", &side.disk, &side.deep),
        ] {
            let (rows, pieces, bytes) = rows(hub, page);
            assert_eq!(rows.len(), ROWS, "{name} {part}: a full page");
            // From the snapshot the run is one budget piece and two full ones (decision 291).
            if part == "snapshot_deep" {
                assert_eq!(pieces, 3, "{name} {part}: pieces read");
                // Each side's snapshot bytes for the request, beside the clock's numbers.
                eprintln!("SERVE_PAGE_BYTES side={name} part={part} pieces={pieces} bytes={bytes}");
                // The records each piece's seek decodes from its checkpoint to its key.
                let snapshot = DiskSnapshot::open(&side.path)
                    .expect("the snapshot opens")
                    .expect("a snapshot on disk");
                let mut scan = Vec::new();
                for (n, (anchor, piece_bytes)) in
                    PEER_ANCHORS.with(|read| read.borrow().clone()).into_iter().enumerate()
                {
                    let (scanned, at) = anchor.map_or((0, 0), |key| {
                        let (offset, ordinal) = snapshot.seek(&key, false).expect("a seek");
                        let (_, from) = snapshot.checkpoint_before(offset).expect("a checkpoint");
                        (ordinal - from, ordinal)
                    });
                    eprintln!(
                        "SERVE_PAGE_SEEK side={name} piece={n} ordinal={at} scanned={scanned} bytes={piece_bytes}"
                    );
                    scan.push(scanned);
                }
                scans.push(scan);
            }
            assert!(
                rows.iter()
                    .all(|row| row["chatId"].as_str().is_some_and(|id| id.starts_with("b-"))),
                "{name} {part}: this machine's rows only"
            );
        }
    }
    // The seeks decode the same records on both sides, so the sides differ in list length only.
    assert_eq!(
        scans[0], scans[1],
        "snapshot_deep: records each piece's seek decodes, small and god"
    );
    let mut parts = Vec::new();
    for part in ["newest", "deep", "snapshot_deep"] {
        let pick = |side: &'static Side| -> (&'static Hub, Page) {
            match part {
                "newest" => (&side.hub, side.newest.clone()),
                "deep" => (&side.hub, side.deep.clone()),
                _ => (&side.disk, side.deep.clone()),
            }
        };
        let ((small_hub, small_page), (god_hub, god_page)) = (pick(small), pick(god));
        let (mut small_rounds, mut god_rounds) = (Vec::new(), Vec::new());
        for _ in 0..ROUNDS {
            // Rounds alternate so a noisy stretch of the machine hits both sides.
            small_rounds.push((0..SAMPLES).map(|_| sample(small_hub, &small_page)).collect());
            god_rounds.push((0..SAMPLES).map(|_| sample(god_hub, &god_page)).collect());
        }
        let row = format!("v2.pr08b.serve_page.{part}");
        gate_rounds::report(&row, &[("small", &small_rounds), ("god", &god_rounds)]);
        let small_p95 = gate_rounds::best_p95(&small_rounds);
        let god_p95 = gate_rounds::best_p95(&god_rounds);
        parts.push((part, small_p95, god_p95));
    }
    // The line carries the worse part's own pair; the gate judges its ratio.
    let ratio = |(_, small, god): &(&str, u128, u128)| *god as f64 / (*small).max(1) as f64;
    let worst =
        parts.iter().copied().max_by(|a, b| ratio(a).total_cmp(&ratio(b))).expect("three parts");
    let [(_, newest_small, newest_god), (_, deep_small, deep_god), (_, disk_small, disk_god)] =
        parts[..]
    else {
        unreachable!("three parts")
    };
    let line = format!(
        "{{\"name\":\"v2.pr08b.serve_page\",\"small_p95\":{},\"god_p95\":{},\"worst\":\"{}\",\"newest_small\":{newest_small},\"newest_god\":{newest_god},\"deep_small\":{deep_small},\"deep_god\":{deep_god},\"snapshot_deep_small\":{disk_small},\"snapshot_deep_god\":{disk_god},\"rows\":{ROWS},\"unit\":\"ns\"}}",
        worst.1, worst.2, worst.0,
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}
