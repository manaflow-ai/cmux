//! God against small, in one harness: a book of 40 rows and a book of 2 million rows (Leo's
//! largest chat) do the same things, and the god book may cost at most 1.2 times the small one
//! (cmuxterm-hq `docs/handbook/perf-regresses-on-degenerate-sessions.md`).
//!
//! What it measures, and the bars (agent-service-v2.md, PR 1):
//!
//! - **append**: bytes written and time per `append_settled`. The last 20,000 appends of the
//!   2M-row book against 500 books of 40 rows (20,000 appends), the same row sizes in both.
//!   Bars: bytes god/small <= 1.2, p95 god/small <= 1.2.
//! - **first window**: `open` + `window(End)` + `fill` from a book that is not open (its files
//!   are in the page cache), 20 rows after its last checkpoint. Bars: under 5 ms for the
//!   protocol's window (400 rows or 256 KB) at both sizes; for the same reply at both sizes (40
//!   rows) p95 god/small <= 1.2.
//! - **page**: a 256 KB page is one read, at 200 places in the god book and at every segment
//!   end.
//! - **memory**: the peak resident memory of a new process that opens the god book and reads
//!   its first window: under 8 MB (Linux).
//!
//! Open, including torn-tail repair, is gated at 1.2x with the same checkpoint suffix.
//!
//! Run (Linux, release; about a minute and 700 MB of disk under `ACPMUX_BOOK_BENCH_DIR` or the
//! temp dir):
//! `cargo test -p acpmux-book --release --lib god_vs_small -- --ignored --nocapture`
//! The kill-at-every-byte tests are in `recover_tests.rs` and run with the ordinary suite.

use crate::log::{Anchor, Edge, Log, MAX_PAGE_BYTES, RawRange, StateWriter, section};
use crate::testkit::{open, text};
use std::fmt::Write as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Instant;

const GOD_ROWS: u64 = 2_000_000;
const SMALL_ROWS: u64 = 40;
/// The appends timed at each size.
const TIMED_ROWS: u64 = 20_000;
const CHECKPOINT_EVERY: u64 = 256;
/// Both books end this many rows after their last checkpoint, so an open replays the same.
const ROWS_AFTER_CHECKPOINT: u64 = 20;
const WINDOW_BYTES: usize = 256 * 1024;
const ROUNDS: usize = 5;

fn nanos(start: Instant) -> u64 {
    start.elapsed().as_nanos() as u64
}

fn percentile(sorted: &[u64], q: f64) -> u64 {
    sorted[((sorted.len() as f64 * q) as usize).min(sorted.len() - 1)]
}

struct Dist {
    p50: u64,
    p95: u64,
    /// The lowest p95 of `ROUNDS` equal groups of the samples, in the order they were taken:
    /// what the 1.2x bars compare, so one noisy stretch of a shared CI machine fails nothing.
    best_p95: u64,
}

fn dist(samples: &[u64]) -> Dist {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let best_p95 = samples
        .chunks(samples.len().div_ceil(ROUNDS))
        .map(|group| {
            let mut group = group.to_vec();
            group.sort_unstable();
            percentile(&group, 0.95)
        })
        .min()
        .unwrap();
    Dist { p50: percentile(&sorted, 0.5), p95: percentile(&sorted, 0.95), best_p95 }
}

/// Append, rather than replace, so one runner can collect several crate-local gates.
fn emit_measure(name: &str, small: u64, god: u64, unit: &str) {
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(
            file,
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"{unit}\"}}"
        )
        .unwrap();
    }
}

/// Use exactly the same distribution in the exported receipt and the asserted gate.
fn gate_p95(small: &Dist, god: &Dist) -> (u64, u64) {
    if small.best_p95 < 100_000 && god.best_p95 < 100_000 {
        (small.best_p95, god.best_p95)
    } else {
        (small.p95, god.p95)
    }
}

fn emit_timing(name: &str, small: &Dist, god: &Dist) {
    let (small, god) = gate_p95(small, god);
    emit_measure(name, small, god, "ns");
}

fn micros(nanos: u64) -> String {
    format!("{:.1} µs", nanos as f64 / 1000.0)
}

#[derive(Default)]
struct Report {
    table: String,
    failed: Vec<String>,
}

impl Report {
    fn row(
        &mut self,
        what: &str,
        small: &str,
        god: &str,
        ratio: Option<f64>,
        bar: &str,
        ok: Option<bool>,
    ) {
        let ratio = ratio.map_or("-".to_string(), |ratio| format!("{ratio:.2}x"));
        let verdict = match ok {
            Some(true) => "ok",
            Some(false) => "OVER",
            None => "-",
        };
        writeln!(self.table, "| {what} | {small} | {god} | {ratio} | {bar} | {verdict} |").unwrap();
        if ok == Some(false) {
            self.failed.push(format!("{what}: small {small}, god {god}, bar {bar}"));
        }
    }

    /// A row of two timings whose p95s must be within 1.2x.
    fn timed(&mut self, what: &str, small: &Dist, god: &Dist, gate: bool) {
        self.row(
            &format!("{what}, p50"),
            &micros(small.p50),
            &micros(god.p50),
            Some(god.p50 as f64 / small.p50 as f64),
            "-",
            None,
        );
        self.row(
            &format!("{what}, p95"),
            &micros(small.p95),
            &micros(god.p95),
            Some(god.p95 as f64 / small.p95 as f64),
            if gate { "pooled god <= 2x small" } else { "-" },
            gate.then_some(god.p95 <= small.p95.saturating_mul(2)),
        );
        // The noise allowance is only for sub-100-us paths.
        let (small_p95, god_p95) = gate_p95(small, god);
        let ratio = god_p95 as f64 / small_p95 as f64;
        self.row(
            &format!("{what}, p95 (best of {ROUNDS} rounds)"),
            &micros(small_p95),
            &micros(god_p95),
            Some(ratio),
            if gate { "god <= 1.2x small" } else { "-" },
            gate.then_some(ratio <= 1.2),
        );
    }
}

/// What a real checkpoint carries: an open row, a raw cursor, a summary.
fn actor_state(id: u64) -> StateWriter {
    let mut state = StateWriter::new();
    state
        .push(section::OPEN_ROWS, &text(id + 1))
        .push(
            section::RAW_CURSOR,
            format!("events/000123.ndjson\0{}\0{}", 9_000_000 + id, id * 900).as_bytes(),
        )
        .push(section::SUMMARY, &[b's'; 300])
        .push(section::TRANSLATOR, &1u32.to_le_bytes());
    state
}

#[derive(Default)]
struct Appends {
    /// Nanoseconds per `append_settled`.
    times: Vec<u64>,
    bytes: Vec<u64>,
    /// Nanoseconds per `write_checkpoint`.
    checkpoints: Vec<u64>,
    checkpoint_bytes: u64,
}

/// Appends rows `from..=to`, timing each, with a checkpoint every 256 rows and one
/// `ROWS_AFTER_CHECKPOINT` rows before `end`.
fn timed_appends(log: &mut Log, from: u64, to: u64, end: u64, into: &mut Appends) {
    let raw_file = log.append_raw_file(b"bench/raw.ndjson").unwrap();
    for id in from..=to {
        let text = text(id);
        let before = log.stats().bytes_written;
        let start = Instant::now();
        log.append_settled(id, 1, RawRange { file: raw_file, off: id, len: 1 }, &text).unwrap();
        let elapsed = nanos(start);
        // Both sides exclude the same position in each 40-row group. The first append to
        // a new book pays mapping/allocation only on small; it has a separate cold gate.
        if id % SMALL_ROWS != 1 {
            into.times.push(elapsed);
            into.bytes.push(log.stats().bytes_written - before);
        }
        if id.is_multiple_of(CHECKPOINT_EVERY) || id + ROWS_AFTER_CHECKPOINT == end {
            let state = actor_state(id);
            let before = log.stats().bytes_written;
            let start = Instant::now();
            log.write_checkpoint(state.as_bytes(), &[]).unwrap();
            into.checkpoints.push(nanos(start));
            into.checkpoint_bytes += log.stats().bytes_written - before;
        }
    }
}

struct FirstWindow {
    nanos: u64,
    rows: usize,
    bytes: usize,
    reads: u32,
}

/// Opens the book, reads its last `rows` rows, and closes it.
fn first_window(dir: &Path, rows: usize) -> FirstWindow {
    let start = Instant::now();
    let (mut log, _) = open(dir);
    let window = log.window(Anchor::End, rows, WINDOW_BYTES);
    let (mut buf, mut at) = (Vec::new(), Vec::new());
    let reads = log.fill(&window.rows, &mut buf, &mut at).unwrap();
    let nanos = nanos(start);
    FirstWindow { nanos, rows: at.len(), bytes: at.iter().map(|range| range.len()).sum(), reads }
}

fn status_kb(field: &str) -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|line| line.starts_with(field))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// The child side of the memory probe: a new process that opens the book named by
/// `ACPMUX_BOOK_RSS_DIR` and reads its first window (`-`: opens nothing, the floor of this
/// binary), then prints its peak and current resident memory while it still holds everything.
#[test]
fn rss_probe_entry() {
    let Ok(dir) = std::env::var("ACPMUX_BOOK_RSS_DIR") else {
        return;
    };
    let print = |rows: usize| {
        if let (Some(peak), Some(now)) = (status_kb("VmHWM:"), status_kb("VmRSS:")) {
            println!("rss_probe peak_kb={peak} now_kb={now} rows={rows}");
        }
    };
    if dir == "-" {
        return print(0);
    }
    let (mut log, _) = open(Path::new(&dir));
    let window = log.window(Anchor::End, 400, WINDOW_BYTES);
    let (mut buf, mut at) = (Vec::new(), Vec::new());
    log.fill(&window.rows, &mut buf, &mut at).unwrap();
    print(at.len());
}

/// Peak resident kB of a new process that opens `dir` and reads its first window; `None` where
/// there is no `/proc`.
fn rss_of(dir: &str) -> Option<u64> {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["rss_probe_entry", "--nocapture", "--test-threads=1"])
        .env("ACPMUX_BOOK_RSS_DIR", dir)
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().find_map(|line| line.split_once("rss_probe peak_kb="))?.1;
    line.split_whitespace().next()?.parse().ok()
}

/// Tears the last record of the book in `dir` (appends one row and cuts 5 bytes off it), then
/// times the open that repairs it.
fn torn_open(dir: &Path) -> u64 {
    {
        let (mut log, _) = open(dir);
        let id = log.max_row() + 1;
        log.append_settled(id, 1, RawRange { file: 1, off: id, len: 1 }, &text(id)).unwrap();
    }
    let last =
        std::fs::read_dir(dir.join("rows")).unwrap().map(|entry| entry.unwrap().path()).max();
    let last = last.unwrap();
    let file = std::fs::OpenOptions::new().write(true).open(&last).unwrap();
    file.set_len(file.metadata().unwrap().len() - 5).unwrap();
    drop(file);
    let start = Instant::now();
    let (log, recovered) = open(dir);
    let nanos = nanos(start);
    assert!(recovered.truncated > 0 && log.max_row() > 0);
    nanos
}

#[test]
#[ignore = "the god-vs-small bench: 2M rows, about a minute and 700 MB of disk; run it by name in release"]
fn god_vs_small() {
    let root: PathBuf =
        std::env::var_os("ACPMUX_BOOK_BENCH_DIR").map_or_else(std::env::temp_dir, PathBuf::from);
    std::fs::create_dir_all(&root).unwrap();
    let home = tempfile::Builder::new().prefix("acpmux-book-bench-").tempdir_in(root).unwrap();
    let small_dir = home.path().join("small");
    let god_dir = home.path().join("god");
    let mut report = Report::default();

    // ---- append: 500 books of 40 rows ----
    let mut small = Appends::default();
    for book in 0..TIMED_ROWS / SMALL_ROWS {
        let dir = if book == 0 { small_dir.clone() } else { home.path().join(format!("s{book}")) };
        let (mut log, _) = open(&dir);
        timed_appends(&mut log, 1, SMALL_ROWS, SMALL_ROWS, &mut small);
        drop(log);
        if book != 0 {
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }

    // ---- append: one book of 2M rows; its last 20,000 appends are the ones timed ----
    let build = Instant::now();
    let (mut log, _) = open(&god_dir);
    let raw_file = log.append_raw_file(b"bench/raw.ndjson").unwrap();
    let untimed = GOD_ROWS - TIMED_ROWS;
    for id in 1..=untimed {
        log.append_settled(id, 1, RawRange { file: raw_file, off: id, len: 1 }, &text(id)).unwrap();
        if id.is_multiple_of(CHECKPOINT_EVERY) {
            log.write_checkpoint(actor_state(id).as_bytes(), &[]).unwrap();
        }
    }
    let mut god = Appends::default();
    timed_appends(&mut log, untimed + 1, GOD_ROWS, GOD_ROWS, &mut god);
    let build_seconds = build.elapsed().as_secs_f64();
    let god_stats = log.stats();
    assert_eq!((log.last_seq(), log.max_row()), (GOD_ROWS, GOD_ROWS));
    drop(log);
    let segments = std::fs::read_dir(god_dir.join("rows")).unwrap().count();
    let god_disk: u64 = std::fs::read_dir(god_dir.join("rows"))
        .unwrap()
        .map(|entry| entry.unwrap().metadata().unwrap().len())
        .sum();

    let (small_written, god_written) = (dist(&small.bytes).p95, dist(&god.bytes).p95);
    let byte_ratio = god_written as f64 / small_written as f64;
    report.row(
        "append: bytes written per row, p95",
        &format!("{small_written} B"),
        &format!("{god_written} B"),
        Some(byte_ratio),
        "god <= 1.2x small",
        Some(byte_ratio <= 1.2),
    );
    let (small_append, god_append) = (dist(&small.times), dist(&god.times));
    report.timed("append: time per row", &small_append, &god_append, true);
    emit_timing("v2.pr01.append_time", &small_append, &god_append);
    emit_measure("v2.pr01.append_bytes", small_written, god_written, "bytes");
    report.row(
        "checkpoint: bytes",
        &format!("{} B", small.checkpoint_bytes / small.checkpoints.len() as u64),
        &format!("{} B", god.checkpoint_bytes / god.checkpoints.len() as u64),
        None,
        "under 64 KB",
        Some(god.checkpoint_bytes / (god.checkpoints.len() as u64) < 64 * 1024),
    );

    // ---- first window: open + window(End) + fill, the two sizes taken in turn ----
    for (rows, gate) in [(400usize, false), (40, true)] {
        let (mut small_times, mut god_times) = (Vec::new(), Vec::new());
        let (mut small_shape, mut god_shape) = ((0, 0, 0), (0, 0, 0));
        for _ in 0..ROUNDS * 200 {
            let window = first_window(&small_dir, rows);
            small_times.push(window.nanos);
            small_shape = (window.rows, window.bytes, window.reads);
            let window = first_window(&god_dir, rows);
            god_times.push(window.nanos);
            god_shape = (window.rows, window.bytes, window.reads);
        }
        let (small_dist, god_dist) = (dist(&small_times), dist(&god_times));
        let what = format!("first window ({rows} rows asked): open + window + fill");
        report.row(
            &format!("{what}: reply"),
            &format!("{} rows, {} B, {} read", small_shape.0, small_shape.1, small_shape.2),
            &format!("{} rows, {} B, {} read", god_shape.0, god_shape.1, god_shape.2),
            None,
            "-",
            None,
        );
        if gate {
            report.timed(&what, &small_dist, &god_dist, true);
            emit_timing("v2.pr01.first_window", &small_dist, &god_dist);
        }
        if rows == 400 {
            let worst = small_dist.p95.max(god_dist.p95);
            report.row(
                &format!("{what}, p95 against 5 ms"),
                &micros(small_dist.p95),
                &micros(god_dist.p95),
                None,
                "under 5 ms",
                Some(worst < 5_000_000),
            );
        }
    }

    // ---- open alone: the same checkpoint interval at each book length ----
    let (mut small_open, mut god_open) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS * 200 {
        for (dir, samples) in [(&small_dir, &mut small_open), (&god_dir, &mut god_open)] {
            let start = Instant::now();
            let (log, recovered) = open(dir);
            samples.push(nanos(start));
            assert_eq!(recovered.replayed, ROWS_AFTER_CHECKPOINT);
            drop(log);
        }
    }
    let (small_open, god_open) = (dist(&small_open), dist(&god_open));
    report.timed("open: one checkpoint interval", &small_open, &god_open, true);

    // Both sides pay first map/allocation in a new book, with exactly the same payload.
    let (mut small_cold, mut god_cold) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS * 100 {
        for samples in [&mut small_cold, &mut god_cold] {
            let dir = tempfile::tempdir_in(home.path()).unwrap();
            let (mut log, _) = open(dir.path());
            let file = log.append_raw_file(b"bench/raw.ndjson").unwrap();
            let text = text(1);
            let start = Instant::now();
            log.append_settled(1, 1, RawRange { file, off: 0, len: 1 }, &text).unwrap();
            samples.push(nanos(start));
        }
    }
    let (small_cold, god_cold) = (dist(&small_cold), dist(&god_cold));
    report.timed("cold first append", &small_cold, &god_cold, true);
    emit_timing("v2.pr01b.cold_first_append", &small_cold, &god_cold);

    // ---- page: a 256 KB page is one read ----
    let (mut log, _) = open(&god_dir);
    let (mut buf, mut at) = (Vec::new(), Vec::new());
    let (mut page_rows, mut page_bytes, mut most_reads) = (0usize, 0usize, 0u32);
    for anchor in (1..=200u64).map(|step| step * (GOD_ROWS / 200)) {
        let page = log.page(Edge::Before(anchor), MAX_PAGE_BYTES);
        let reads = log.fill(&page.rows, &mut buf, &mut at).unwrap();
        most_reads = most_reads.max(reads);
        page_rows += page.rows.len();
        page_bytes += at.iter().map(|range| range.len()).sum::<usize>();
    }
    // The first row of every segment after the first: a page that reaches back over a segment's
    // end stops there, so it is still one read.
    let mut at_segment_ends = 0;
    for seg in 2..=segments as u32 {
        let (mut low, mut high) = (1u64, GOD_ROWS);
        while low < high {
            let middle = (low + high) / 2;
            if log.row(middle).unwrap().seg < seg { low = middle + 1 } else { high = middle }
        }
        for anchor in [low + 1, low + 50, low + 2000] {
            let page = log.page(Edge::Before(anchor), MAX_PAGE_BYTES);
            assert!(!page.rows.is_empty());
            most_reads = most_reads.max(log.fill(&page.rows, &mut buf, &mut at).unwrap());
            at_segment_ends += 1;
        }
    }
    let small_page = {
        let (mut small_log, _) = open(&small_dir);
        let page = small_log.page(Edge::Before(SMALL_ROWS + 1), MAX_PAGE_BYTES);
        let reads = small_log.fill(&page.rows, &mut buf, &mut at).unwrap();
        (page.rows.len(), at.iter().map(|range| range.len()).sum::<usize>(), reads)
    };
    report.row(
        "page (256 KB asked): reads per page",
        &format!("{} ({} rows, {} B)", small_page.2, small_page.0, small_page.1),
        &format!(
            "{most_reads} at most, over 200 places and {at_segment_ends} at segment ends ({} rows, {} B a page)",
            page_rows / 200,
            page_bytes / 200
        ),
        None,
        "one read",
        Some(most_reads == 1 && small_page.2 == 1),
    );
    drop(log);

    // ---- memory: a new process opens the book and reads its first window ----
    let (floor, small_rss, god_rss) =
        (rss_of("-"), rss_of(&small_dir.to_string_lossy()), rss_of(&god_dir.to_string_lossy()));
    match (floor, small_rss, god_rss) {
        (Some(floor), Some(small_rss), Some(god_rss)) => {
            report.row(
                "peak resident memory: open + first window (400 rows), a new process",
                &format!("{small_rss} kB"),
                &format!("{god_rss} kB"),
                Some(god_rss as f64 / small_rss as f64),
                "god under 8 MB",
                Some(god_rss < 8 * 1024),
            );
            report.row(
                "of which the book (over the same process opening nothing)",
                &format!("{} kB", small_rss.saturating_sub(floor)),
                &format!("{} kB", god_rss.saturating_sub(floor)),
                None,
                "-",
                None,
            );
        }
        _ => report.row(
            "peak resident memory",
            "n/a",
            "n/a (no /proc here)",
            None,
            "god under 8 MB",
            None,
        ),
    }

    // ---- an open that repairs a torn tail ----
    let (mut small_torn, mut god_torn) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS * 20 {
        small_torn.push(torn_open(&small_dir));
        god_torn.push(torn_open(&god_dir));
    }
    let (small_torn, god_torn) = (dist(&small_torn), dist(&god_torn));
    report.timed("open that cuts off a torn record", &small_torn, &god_torn, true);
    emit_timing("v2.pr01b.torn_open", &small_torn, &god_torn);

    let header = format!(
        "acpmux-book god vs small: {GOD_ROWS} rows against {SMALL_ROWS}. God book: {segments} segments, {:.0} MB of \
         segments, rows.idx {:.0} MB mapped, built in {build_seconds:.1} s ({:.0} rows/s with a checkpoint every 256 \
         rows).\n\n| What | small ({SMALL_ROWS} rows) | god ({GOD_ROWS} rows) | god/small | bar | |\n|---|---|---|---|---|---|\n",
        god_disk as f64 / 1e6,
        god_stats.index_mapped_bytes as f64 / 1e6,
        GOD_ROWS as f64 / build_seconds,
    );
    let text = format!("{header}{}", report.table);
    println!("\n{text}");
    if let Some(out) = std::env::var_os("FAST_CHECKS_OUT") {
        let _ = std::fs::write(Path::new(&out).join("acpmux-book-god-vs-small.md"), &text);
    }
    assert!(report.failed.is_empty(), "over the bar:\n{}", report.failed.join("\n"));
}
