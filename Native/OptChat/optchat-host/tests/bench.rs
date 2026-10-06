//! Start time, memory and append latency of the store at 10k, 100k and 1M
//! synthetic messages (README "State and storage"). Ignored by default:
//!
//! ```bash
//! OPTCHAT_BENCH_SIZES=10000,100000,1000000 OPTCHAT_BENCH_DIR=/tmp/optchat-bench \
//!   cargo test --release --test bench -- --ignored --nocapture
//! ```
//!
//! It uses only `OptChat`'s public API, so the same file measures the JSONL
//! line store (before 2026-10-06) and the SQLite store. Each size gets a
//! home in the old JSONL layout with every tree node built; each
//! measurement runs in a fresh child process (its own RSS). The first open
//! of the SQLite store imports the files (the migration), timed apart; the
//! numbers below are the open after it, page cache warm in both cases.

use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Instant;

use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, Kind, ModelError, OptChat, Reply, SystemClock,
};

const CHILD: &str = "OPTCHAT_BENCH_CHILD";
const APPENDS: usize = 200;

struct Never;

impl CompactModel for Never {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Err(ModelError::new("bench: no model calls"))
    }
}

fn open(dir: &Path) -> OptChat {
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    OptChat::open_with(dir, config, Arc::new(Never), Arc::new(SystemClock)).expect("open")
}

fn status_kb(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix(field))
        .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap_or(0)
}

/// Old-format day files: `t` messages over 100 days, and every node of the
/// tree built (about 2t nodes), so the view is settled at open.
fn generate(dir: &Path, t: u64) {
    use std::io::Write;
    std::fs::create_dir_all(dir.join("main")).unwrap();
    std::fs::create_dir_all(dir.join("tree")).unwrap();
    let per_day = t.div_ceil(100).max(1);
    let day = |i: u64| {
        format!(
            "2026-{:02}-{:02}",
            1 + (i / per_day) / 28 % 12,
            1 + (i / per_day) % 28
        )
    };
    let mut main: Option<(String, std::io::BufWriter<std::fs::File>)> = None;
    for i in 0..t {
        let d = day(i);
        if main.as_ref().is_none_or(|(cur, _)| *cur != d) {
            let f = std::fs::File::create(dir.join(format!("main/{d}.jsonl"))).unwrap();
            main = Some((d.clone(), std::io::BufWriter::new(f)));
        }
        let kind = ["user", "talk", "tool", "echo"][(i % 4) as usize];
        let text = format!("message {i}: {}", "lorem ipsum dolor sit amet ".repeat(7));
        let line = serde_json::json!({"i": i, "kind": kind, "text": text,
            "size": kind.len() + 2 + text.len(), "date": format!("{d}T12:00:00.000+00:00")});
        writeln!(main.as_mut().unwrap().1, "{line}").unwrap();
    }
    drop(main);
    let mut tree =
        std::io::BufWriter::new(std::fs::File::create(dir.join("tree/2026-12-28.jsonl")).unwrap());
    let mut l = 0u32;
    while (1u64 << l) <= t {
        for i in 0..(t >> l) {
            let text = format!("summary {l}+{i}: {}", "consectetur adipiscing ".repeat(5));
            let line = serde_json::json!({"l": l, "i": i, "text": text, "size": text.len()});
            writeln!(tree, "{line}").unwrap();
        }
        l += 1;
    }
}

/// In the child: open, then append `APPENDS` short messages one by one.
fn child(dir: &Path) {
    let rss0 = status_kb("VmRSS:");
    let started = Instant::now();
    let chat = open(dir);
    let open_ms = started.elapsed().as_secs_f64() * 1000.0;
    let rss_open = status_kb("VmRSS:");
    let messages = chat.status().messages;
    let mut lat = Vec::with_capacity(APPENDS);
    for k in 0..APPENDS {
        let t = Instant::now();
        chat.append(Kind::User, &format!("bench append {k}"))
            .unwrap();
        lat.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    lat.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean = lat.iter().sum::<f64>() / lat.len() as f64;
    println!(
        "BENCH {}",
        serde_json::json!({
            "messages": messages, "open_ms": open_ms,
            "rss_open_kb": rss_open, "rss_delta_kb": rss_open.saturating_sub(rss0),
            "hwm_kb": status_kb("VmHWM:"),
            "append_mean_ms": mean, "append_p50_ms": lat[lat.len() / 2],
            "append_p99_ms": lat[lat.len() * 99 / 100],
        })
    );
    chat.shutdown();
}

fn run_child(dir: &Path) -> String {
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "bench",
            "--ignored",
            "--nocapture",
            "--test-threads",
            "1",
        ])
        .env(CHILD, dir)
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.lines()
        .find_map(|l| l.find("BENCH ").map(|k| &l[k + 6..]))
        .map(str::to_owned)
        .unwrap_or_else(|| format!("failed: {}", String::from_utf8_lossy(&out.stderr)))
}

#[test]
#[ignore]
fn bench() {
    if let Ok(dir) = std::env::var(CHILD) {
        return child(Path::new(&dir));
    }
    let root = std::env::var("OPTCHAT_BENCH_DIR").unwrap_or_else(|_| "/tmp/optchat-bench".into());
    let sizes = std::env::var("OPTCHAT_BENCH_SIZES").unwrap_or_else(|_| "10000,100000".into());
    for t in sizes.split(',').map(|s| s.trim().parse::<u64>().unwrap()) {
        let dir = Path::new(&root).join(format!("home-{t}"));
        let _ = std::fs::remove_dir_all(&dir);
        generate(&dir, t);
        // First open: the line store's load, or the SQLite store's import.
        let first = run_child(&dir);
        println!("SIZE {t} first-open {first}");
        let second = run_child(&dir);
        println!("SIZE {t} open {second}");
        let disk: u64 = walk_bytes(&dir);
        let db = ["memory.sqlite3", "memory.sqlite3-wal"]
            .iter()
            .map(|f| std::fs::metadata(dir.join(f)).map_or(0, |m| m.len()))
            .sum::<u64>();
        println!("SIZE {t} disk_bytes {disk} db_bytes {db}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

fn walk_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| {
                    let p = e.path();
                    if p.is_dir() {
                        walk_bytes(&p)
                    } else {
                        e.metadata().map_or(0, |m| m.len())
                    }
                })
                .sum()
        })
        .unwrap_or(0)
}

/// Whether the one writer connection behind the chat's mutex makes readers
/// wait: four threads append (each a commit) while a reader renders the
/// view and zooms, as the turn and the memory tools do.
#[test]
#[ignore]
fn contention() {
    let dir = tempfile::tempdir().unwrap();
    let chat = std::sync::Arc::new(open(dir.path()));
    for n in 0..2_000 {
        chat.append(Kind::User, &format!("seed {n}")).unwrap();
    }
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writers: Vec<_> = (0..4)
        .map(|w| {
            let chat = chat.clone();
            std::thread::spawn(move || {
                let mut lat = Vec::new();
                for k in 0..250 {
                    let t = Instant::now();
                    chat.append(Kind::Talk, &format!("w{w} {k}")).unwrap();
                    lat.push(t.elapsed().as_secs_f64() * 1000.0);
                }
                lat
            })
        })
        .collect();
    let reader = {
        let (chat, stop) = (chat.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut lat = Vec::new();
            while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                let t = Instant::now();
                let _ = chat.render_view();
                let _ = chat.zoom(0, 1);
                lat.push(t.elapsed().as_secs_f64() * 1000.0);
            }
            lat
        })
    };
    let mut writes: Vec<f64> = writers
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let mut reads = reader.join().unwrap();
    // The same reads with no writer, for the baseline.
    let mut idle = Vec::new();
    for _ in 0..reads.len().min(2_000) {
        let t = Instant::now();
        let _ = chat.render_view();
        let _ = chat.zoom(0, 1);
        idle.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let q = |v: &mut Vec<f64>, p: usize| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[(v.len() * p / 100).min(v.len() - 1)]
    };
    println!(
        "CONTENTION {}",
        serde_json::json!({
            "append_p50_ms": q(&mut writes, 50), "append_p99_ms": q(&mut writes, 99),
            "read_busy_p50_ms": q(&mut reads, 50), "read_busy_p99_ms": q(&mut reads, 99),
            "read_idle_p50_ms": q(&mut idle, 50), "read_idle_p99_ms": q(&mut idle, 99),
            "reads": reads.len(),
        })
    );
}
