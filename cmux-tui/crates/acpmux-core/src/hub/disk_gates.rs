//! Ignored release measurements for PR 5b storage startup, hydration and pages.
//! Startup crosses an exec boundary so it includes the daemon's open-to-first-window path.

use super::*;
use acpmux_book::index::{DiskSnapshot, IndexLog, ListFilter, ReadSide, SortedSnapshot};
use serde_json::value::RawValue;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::process::Command;
use tempfile::{TempDir, tempdir};

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;
const PAGE_ROWS: usize = 20;
const TAIL_ROWS: usize = 16;

fn summary(id: String, activity: u64, state: &str) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = state.to_owned();
    row.extra = RawValue::from_string("{}".to_owned()).expect("literal JSON");
    row
}

fn fixture(count: usize, filter_fixture: bool, with_tail: bool) -> (TempDir, SummaryIndex) {
    let dir = tempdir().expect("temporary fixture");
    let mut index = SummaryIndex::new();
    for n in 0..count {
        let state = if filter_fixture && n % 100 == 0 { "running" } else { "closed" };
        index =
            index.apply((n + 1) as u64, summary(format!("row-{n:05}"), (count - n) as u64, state));
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &index).expect("write fixture");
    if with_tail {
        // Both sides have exactly the same fixed tail shape and byte count.
        let mut log = IndexLog::open(dir.path().join("index.log")).expect("open tail");
        for n in 0..TAIL_ROWS {
            log.append(summary(format!("tail-{n:02}"), 0, "closed")).expect("append tail");
        }
        log.sync().expect("sync tail");
    }
    (dir, index)
}

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[((values.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
}
fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    rounds.iter().map(|round| p95(&mut round.clone())).min().unwrap_or(1)
}
fn all_p95(rounds: &[Vec<u128>]) -> u128 {
    p95(&mut rounds.iter().flatten().copied().collect::<Vec<_>>())
}

fn round_stats(samples: &[u128]) -> (u128, u128) {
    let best = samples.chunks_exact(SAMPLES).map(|round| p95(&mut round.to_vec())).min().unwrap();
    (best, p95(&mut samples.to_vec()))
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

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| {
            status.lines().find_map(|line| {
                line.strip_prefix("VmRSS:")
                    .and_then(|rest| rest.split_whitespace().next())
                    .and_then(|value| value.parse().ok())
            })
        })
        .unwrap_or(0)
}

fn child_startup() {
    let dir = std::env::var("V2_GATE_DIR").expect("child fixture directory");
    let boot = std::env::var("V2_GATE_BOOT")
        .expect("child boot")
        .parse::<u64>()
        .expect("numeric child boot");
    let (hub, mut writer) =
        Hub::open(std::path::Path::new(&dir), boot, || 19).expect("open disk hub");
    let mut sub = Sub::new("child", "list");
    sub.window = Some(PAGE_ROWS as u16);
    let frame = hub.list_window(&sub).expect("first window");
    let window: Window<Summary> = frame.decode_json().expect("window JSON");
    assert_eq!(window.rows.len(), PAGE_ROWS);
    println!("V2_GATE_WINDOW_READY");
    std::io::stdout().flush().expect("flush startup marker");
    if std::env::var("V2_GATE_MODE").as_deref() == Ok("hydrate") {
        writer.start_hydration();
        while writer.hydration.is_some() {
            writer.process_batch();
        }
        println!("V2_GATE_HOT_ROWS={}", hub.snapshot().len());
    }
    println!("V2_GATE_CHILD_RSS_KB={}", rss_kb());
}

fn exec_child(
    dir: &std::path::Path,
    test_name: &str,
    boot: u64,
    hydrate: bool,
) -> (u128, u64, u64) {
    let start = std::time::Instant::now();
    let mut child = Command::new(std::env::current_exe().expect("test executable"))
        .arg("--exact")
        .arg(test_name)
        .arg("--ignored")
        .arg("--nocapture")
        .env("V2_GATE_CHILD", "1")
        .env("V2_GATE_MODE", if hydrate { "hydrate" } else { "startup" })
        .env("V2_GATE_DIR", dir)
        .env("V2_GATE_BOOT", boot.to_string())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("exec startup child");
    let stdout = child.stdout.take().expect("child stdout");
    let mut lines = BufReader::new(stdout).lines();
    let mut ready = false;
    let mut hot_rows = 0;
    let mut rss = None;
    for line in lines.by_ref() {
        let line = line.expect("child output");
        if line == "V2_GATE_WINDOW_READY" {
            ready = true;
            break;
        }
    }
    let elapsed = start.elapsed().as_nanos().max(1);
    if !ready {
        panic!("startup child ended before window");
    }
    for line in lines {
        let line = line.expect("child output");
        if let Some(value) = line.strip_prefix("V2_GATE_HOT_ROWS=") {
            hot_rows = value.parse().expect("hot rows");
        }
        if let Some(value) = line.strip_prefix("V2_GATE_CHILD_RSS_KB=") {
            rss = Some(value.parse().expect("rss"));
        }
    }
    let status = child.wait().expect("wait startup child");
    assert!(status.success(), "startup child failed: {status}");
    (elapsed, rss.expect("child RSS receipt"), hot_rows)
}

fn make_disk_index(dir: &std::path::Path, index: &SummaryIndex) -> SummaryIndex {
    SortedSnapshot::write(dir.join("index.snap"), index).expect("write page fixture");
    SummaryIndex::from_disk(
        DiskSnapshot::open(dir.join("index.snap")).expect("open snapshot"),
        index.edition(),
    )
}
fn measure_page(index: &SummaryIndex, key: &SortKey, filter: Option<&ListFilter>) -> (u128, usize) {
    let start = std::time::Instant::now();
    let page = index
        .read_page(Some(key), ReadSide::After, false, PAGE_ROWS, 256 * 1024, filter)
        .expect("bounded page");
    (start.elapsed().as_nanos().max(1), page.bytes_read)
}

#[test]
#[ignore = "PR5b release gate; run cmux-ci test -- cargo test -p acpmux-core --release disk_gates -- --ignored --nocapture"]
fn pr05b_startup_pages_and_hot_index_gate() {
    if std::env::var_os("V2_GATE_CHILD").is_some() {
        child_startup();
        return;
    }
    let (small_dir, _) = fixture(20, false, true);
    let (god_dir, _) = fixture(11_000, false, true);
    let child_name =
        module_path!().split_once("::").map_or(module_path!(), |(_, rest)| rest).to_owned()
            + "::pr05b_startup_pages_and_hot_index_gate";
    let mut small_start = Vec::with_capacity(ROUNDS);
    let mut god_start = Vec::with_capacity(ROUNDS);
    let mut small_rss = Vec::with_capacity(ROUNDS * SAMPLES);
    let mut god_rss = Vec::with_capacity(ROUNDS * SAMPLES);
    for round in 0..ROUNDS {
        small_start.push(Vec::with_capacity(SAMPLES));
        god_start.push(Vec::with_capacity(SAMPLES));
        for sample in 0..SAMPLES {
            let (small_ns, small_kb, _) = exec_child(
                small_dir.path(),
                &child_name,
                10_000 + (round * SAMPLES + sample) as u64,
                false,
            );
            let (god_ns, god_kb, _) = exec_child(
                god_dir.path(),
                &child_name,
                20_000 + (round * SAMPLES + sample) as u64,
                false,
            );
            small_start.last_mut().unwrap().push(small_ns);
            god_start.last_mut().unwrap().push(god_ns);
            small_rss.push(small_kb as u128);
            god_rss.push(god_kb as u128);
        }
    }
    let small_start_p95 = best_p95(&small_start);
    let god_start_p95 = best_p95(&god_start);
    let god_start_all = all_p95(&god_start);
    gate("v2.pr05b.start_first_window", small_start_p95, god_start_p95, god_start_all, "ns");
    let mut failures = Vec::new();
    if god_start_p95 > small_start_p95.saturating_mul(12) / 10 {
        failures.push(format!("startup best ratio: small={small_start_p95} god={god_start_p95}"));
    }
    if god_start_all > small_start_p95.saturating_mul(2) {
        failures.push(format!("startup all ratio: small={small_start_p95} god={god_start_all}"));
    }
    if god_start_p95 > 200_000_000 {
        failures.push(format!("startup god p95 exceeds 200ms: {god_start_p95}"));
    }
    let small_rss_p95 = p95(&mut small_rss);
    let god_rss_p95 = p95(&mut god_rss);
    gate("v2.pr05b.start_rss", small_rss_p95, god_rss_p95, god_rss_p95, "kB");
    if god_rss_p95 > small_rss_p95.saturating_mul(12) / 10 {
        failures.push(format!("startup RSS ratio: small={small_rss_p95} god={god_rss_p95}"));
    }

    let (small_page_dir, small_index) = fixture(20, true, false);
    let (god_page_dir, god_index) = fixture(11_000, true, false);
    let small_disk = make_disk_index(small_page_dir.path(), &small_index);
    let god_disk = make_disk_index(god_page_dir.path(), &god_index);
    let small_keys = [
        SortKey::of(&small_index.get("row-00000").unwrap()),
        SortKey::of(&small_index.get("row-00010").unwrap()),
        SortKey::of(&small_index.get("row-00019").unwrap()),
    ];
    let god_keys = [
        SortKey::of(&god_index.get("row-00000").unwrap()),
        SortKey::of(&god_index.get("row-05642").unwrap()),
        SortKey::of(&god_index.get("row-10999").unwrap()),
    ];
    let mut small_page: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    let mut god_page: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    let mut small_bytes: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    let mut god_bytes: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    for _ in 0..ROUNDS {
        for _ in 0..SAMPLES {
            for (position, (small_key, god_key)) in
                small_keys.iter().zip(god_keys.iter()).enumerate()
            {
                let (s_ns, s_read) = measure_page(&small_disk, small_key, None);
                let (g_ns, g_read) = measure_page(&god_disk, god_key, None);
                small_page[position].push(s_ns);
                god_page[position].push(g_ns);
                small_bytes[position].push(s_read as u128);
                god_bytes[position].push(g_read as u128);
            }
        }
    }
    for (position, label) in ["first", "middle", "last"].iter().enumerate() {
        let (small_time, _) = round_stats(&small_page[position]);
        let (god_time, god_all) = round_stats(&god_page[position]);
        let small_read = p95(&mut small_bytes[position]);
        let god_read = p95(&mut god_bytes[position]);
        gate(&format!("v2.pr05b.page_{label}"), small_time, god_time, god_all, "ns");
        gate(&format!("v2.pr05b.page_{label}_bytes"), small_read, god_read, god_read, "bytes");
        if god_time > small_time.saturating_mul(12) / 10 || god_all > small_time.saturating_mul(2) {
            failures.push(format!("page {label} time ratio: small={small_time} god={god_time}"));
        }
        if god_read > small_read.saturating_mul(12) / 10 {
            failures.push(format!("page {label} byte ratio: small={small_read} god={god_read}"));
        }
    }

    let filter = ListFilter { workspace: None, origin: None, state: Some("running".to_owned()) };
    let mut small_filter: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    let mut god_filter: [Vec<u128>; 3] =
        std::array::from_fn(|_| Vec::with_capacity(ROUNDS * SAMPLES));
    for _ in 0..ROUNDS {
        for _ in 0..SAMPLES {
            for (position, (small_key, god_key)) in
                small_keys.iter().zip(god_keys.iter()).enumerate()
            {
                small_filter[position].push(measure_page(&small_disk, small_key, Some(&filter)).0);
                god_filter[position].push(measure_page(&god_disk, god_key, Some(&filter)).0);
            }
        }
    }
    for (position, label) in ["first", "middle", "last"].iter().enumerate() {
        let (small_time, _) = round_stats(&small_filter[position]);
        let (god_time, god_all) = round_stats(&god_filter[position]);
        gate(&format!("v2.pr05b.page_{label}_filter"), small_time, god_time, god_all, "ns");
        if god_time > small_time.saturating_mul(12) / 10 || god_all > small_time.saturating_mul(2) {
            failures
                .push(format!("filtered page {label} ratio: small={small_time} god={god_time}"));
        }
    }

    let (clean_small_dir, _) = fixture(20, false, false);
    let (clean_god_dir, _) = fixture(11_000, false, false);
    let mut clean_small_rss = Vec::with_capacity(ROUNDS);
    let mut clean_god_rss = Vec::with_capacity(ROUNDS);
    for round in 0..ROUNDS {
        let (_, small_kb, small_hot) =
            exec_child(&clean_small_dir.path(), &child_name, 30_000 + round as u64, true);
        let (_, god_kb, god_hot) =
            exec_child(&clean_god_dir.path(), &child_name, 40_000 + round as u64, true);
        clean_small_rss.push(small_kb as u128);
        clean_god_rss.push(god_kb as u128);
        if small_hot != 0 {
            failures.push(format!("small cold hydration entered hot index: {small_hot}"));
        }
        if god_hot != 0 {
            failures.push(format!("god cold hydration entered hot index: {god_hot}"));
        }
    }
    let small_hot_rss = p95(&mut clean_small_rss);
    let god_hot_rss = p95(&mut clean_god_rss);
    gate("v2.pr05b.hot_rss", small_hot_rss, god_hot_rss, god_hot_rss, "kB");
    if god_hot_rss > small_hot_rss.saturating_mul(12) / 10 {
        failures.push(format!("cold hydration RSS ratio: small={small_hot_rss} god={god_hot_rss}"));
    }
    assert!(failures.is_empty(), "PR5b gate failures (all rows were emitted): {failures:?}");
}
