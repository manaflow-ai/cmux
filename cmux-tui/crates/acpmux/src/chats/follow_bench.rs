//! What one appended transcript line costs the chats page's text (Leo 2026-11-12: "even if a chat
//! is long, there should be no percievable difference"), in a god chat (about 1 GB, 90k lines)
//! and a small one, read whole as before (`ChatText::update` with `transcript_turns`, what the
//! text thread called) and followed (`ChatText::follow`); and the text thread's share of a core
//! while 50 chats are written. Manual:
//! `cargo test -p acpmux --lib follow_bench -- --ignored --nocapture --test-threads=1`.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};

use super::text::ChatText;
use super::transcript_turns;

fn chat(id: usize, path: &Path, updated_ms: i64) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness: AdapterKind::ClaudeCode,
            session_id: format!("s{id}"),
            title: None,
            title_source: None,
            cwd: None,
            created_ms: None,
            updated_ms,
            message_count: None,
            source_path: path.to_path_buf(),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

/// Line `k` of turn `t`: a prompt, ten tool calls with about 25 KB of output each, an answer.
fn line(t: usize, k: usize) -> String {
    let at = format!("2026-10-01T01:{:02}:{:02}.000Z", t / 60 % 60, t % 60);
    match k {
        0 => format!(
            r#"{{"type":"user","timestamp":"{at}","message":{{"role":"user","content":"prompt {t}: fix the sidebar row that reads NaN after a deploy"}}}}"#
        ),
        21 => format!(
            r#"{{"type":"assistant","timestamp":"{at}","message":{{"role":"assistant","content":[{{"type":"text","text":"answer {t}: {}"}}],"stop_reason":"end_turn"}}}}"#,
            "the row read the count before the index settled ".repeat(40)
        ),
        k if k % 2 == 1 => format!(
            r#"{{"type":"assistant","timestamp":"{at}","message":{{"content":[{{"type":"tool_use","id":"t{t}-{k}","name":"Bash","input":{{"command":"rg -n count src"}}}}]}}}}"#
        ),
        k => format!(
            r#"{{"type":"user","timestamp":"{at}","message":{{"content":[{{"type":"tool_result","tool_use_id":"t{t}-{}","content":"{}"}}]}}}}"#,
            k - 1,
            "src/chats/window.rs:42: let count = rows.len(); ".repeat(500)
        ),
    }
}

const LINES_PER_TURN: usize = 22;

fn write_turns(path: &Path, turns: usize) -> u64 {
    let mut file = std::io::BufWriter::new(std::fs::File::create(path).expect("create"));
    for t in 0..turns {
        for k in 0..LINES_PER_TURN {
            writeln!(file, "{}", line(t, k)).expect("write");
        }
    }
    file.flush().expect("flush");
    std::fs::metadata(path).expect("meta").len()
}

fn append(path: &Path, text: &str) {
    let mut file = std::fs::OpenOptions::new().append(true).open(path).expect("open");
    writeln!(file, "{text}").expect("append");
}

/// Bytes this process has read (`/proc/self/io`'s `rchar`).
fn rchar() -> u64 {
    std::fs::read_to_string("/proc/self/io")
        .ok()
        .and_then(|io| {
            io.lines().find_map(|l| l.strip_prefix("rchar: ").and_then(|n| n.parse().ok()))
        })
        .unwrap_or(0)
}

/// CPU time of this thread.
fn thread_cpu() -> Duration {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid timespec for the call to write.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

fn pass(text: &ChatText, chats: &[IndexedChat], follow: bool) {
    let read = |entry: &ChatEntry| transcript_turns(entry).ok();
    if follow { text.follow(chats, &read) } else { text.update(chats, &read) }
}

struct Costs {
    cpu: Vec<Duration>,
    bytes: Vec<u64>,
}

impl Costs {
    fn p(&self, q: f64) -> Duration {
        let mut cpu = self.cpu.clone();
        cpu.sort();
        cpu[((cpu.len() as f64 - 1.0) * q).round() as usize]
    }

    fn bytes(&self) -> u64 {
        self.bytes.iter().sum::<u64>() / self.bytes.len() as u64
    }
}

/// Appends `n` lines one at a time, each followed by a pass, and what each pass cost.
fn per_line(path: &Path, follow: bool, n: usize, base_turn: usize) -> Costs {
    let text = ChatText::new(path.with_extension("text.json"));
    let mut stamp = 1;
    pass(&text, &[chat(0, path, stamp)], follow);
    let mut costs = Costs { cpu: Vec::new(), bytes: Vec::new() };
    for i in 0..n {
        let (t, k) = (base_turn + i / LINES_PER_TURN, i % LINES_PER_TURN);
        append(path, &line(t, k));
        stamp += 1;
        let (cpu, bytes) = (thread_cpu(), rchar());
        pass(&text, &[chat(0, path, stamp)], follow);
        costs.cpu.push(thread_cpu() - cpu);
        costs.bytes.push(rchar() - bytes);
    }
    costs
}

struct Fixture {
    _dir: tempfile::TempDir,
    god: PathBuf,
    small: PathBuf,
    god_turns: usize,
}

/// God: about 1 GB in about 4,100 turns (90k lines); small: 10 turns, about 2.5 MB.
fn fixture() -> Fixture {
    let dir = tempfile::tempdir().expect("dir");
    let god = dir.path().join("god.jsonl");
    let small = dir.path().join("small.jsonl");
    let god_turns = 4_100;
    let started = Instant::now();
    let god_len = write_turns(&god, god_turns);
    let small_len = write_turns(&small, 10);
    println!(
        "fixture: god {:.2} GB ({} lines), small {:.1} MB, written in {:.1?}",
        god_len as f64 / 1e9,
        god_turns * LINES_PER_TURN,
        small_len as f64 / 1e6,
        started.elapsed()
    );
    Fixture { _dir: dir, god, small, god_turns }
}

#[test]
#[ignore = "manual: writes a 1 GB transcript"]
fn follow_bench_per_appended_line_god_and_small() {
    let fx = fixture();
    for (mode, follow, n) in [("whole read (before)", false, 44), ("followed (after)", true, 440)] {
        let god = per_line(&fx.god, follow, n, fx.god_turns);
        let small = per_line(&fx.small, follow, n, 10);
        println!(
            "{mode}: per appended line, {n} lines: god p50 {:.1?} p95 {:.1?} {} B read; small p50 {:.1?} p95 {:.1?} {} B read; god/small p95 {:.2}x, bytes {:.2}x",
            god.p(0.5),
            god.p(0.95),
            god.bytes(),
            small.p(0.5),
            small.p(0.95),
            small.bytes(),
            god.p(0.95).as_secs_f64() / small.p(0.95).as_secs_f64(),
            god.bytes() as f64 / small.bytes().max(1) as f64,
        );
    }
}

#[test]
#[ignore = "manual: writes a 1 GB transcript"]
fn follow_bench_idle_daemon_50_chats_written() {
    let fx = fixture();
    // One god chat and 49 small ones, each written at 10 lines a second: a pass every 2 s (the
    // text thread's settle) reads 20 new lines of each.
    let mut paths = vec![fx.god.clone()];
    for id in 1..50 {
        let path = fx.small.with_file_name(format!("small-{id}.jsonl"));
        std::fs::copy(&fx.small, &path).expect("copy");
        paths.push(path);
    }
    let settle = Duration::from_secs(2);
    for (mode, follow, cycles) in
        [("whole read (before)", false, 2), ("followed (after)", true, 10)]
    {
        let text = ChatText::new(fx.god.with_extension(format!("{follow}.json")));
        let mut stamp = 1;
        let chats = |stamp| -> Vec<IndexedChat> {
            paths.iter().enumerate().map(|(id, path)| chat(id, path, stamp)).collect()
        };
        pass(&text, &chats(stamp), follow);
        let mut shares = Vec::new();
        for cycle in 0..cycles {
            for path in &paths {
                for k in 0..20 {
                    append(path, &line(fx.god_turns + cycle, (k + 1) % LINES_PER_TURN));
                }
            }
            stamp += 1;
            let cpu = thread_cpu();
            pass(&text, &chats(stamp), follow);
            shares.push((thread_cpu() - cpu).as_secs_f64() / settle.as_secs_f64());
        }
        let mean = shares.iter().sum::<f64>() / shares.len() as f64;
        let max = shares.iter().cloned().fold(0.0, f64::max);
        println!(
            "{mode}: 50 chats, 20 lines each per 2 s: text thread {:.1}% of a core (max {:.1}%)",
            mean * 100.0,
            max * 100.0
        );
    }
}
