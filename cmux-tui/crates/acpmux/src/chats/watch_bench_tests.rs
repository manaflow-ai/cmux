//! Bench (ignored; macOS; run on a fleet Mac, never on the person's): the watch of a Claude Code
//! projects root with 170 agents at work, each writing about twice a second (its transcript, its
//! subagents' transcripts and its tools' results), for notify's stream (latency 0, the old
//! watch) and the own stream at each latency. The writers run in a child process, so this
//! process's CPU and context switches are the watch's own: the stream's deliveries, the filter
//! and the coalescing thread (the index's work is not in it). Also how long a new session takes
//! from its first write to the index pass that holds it, with no writers and under the load.
//!
//! `cargo test -p acpmux --lib -- --ignored --nocapture --test-threads 1 chats::watch::bench::latency_table`

use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

const WRITERS: usize = 170;
const WRITES_PER_SECOND_EACH: u32 = 2;
const PROJECTS: usize = 40;
const IDLE_TRANSCRIPTS: usize = 2000;
const WARM: Duration = Duration::from_secs(3);
const WINDOW: Duration = Duration::from_secs(12);
const WINDOWS: usize = 2;
/// Each mode runs once per round, the rounds interleaved, so a busy spell of the host does not
/// fall on one mode only.
const ROUNDS: usize = 2;
const PROBES: usize = 3;
const ROOT_VAR: &str = "ACPMUX_BENCH_WRITE_ROOT";
const SECS_VAR: &str = "ACPMUX_BENCH_WRITE_SECS";

fn usage() -> (Duration, u64) {
    // SAFETY: getrusage fills the zeroed struct for this process.
    let ru = unsafe {
        let mut ru: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut ru);
        ru
    };
    let time = |tv: libc::timeval| {
        Duration::from_secs(tv.tv_sec as u64) + Duration::from_micros(tv.tv_usec as u64)
    };
    (time(ru.ru_utime) + time(ru.ru_stime), (ru.ru_nvcsw + ru.ru_nivcsw) as u64)
}

fn session_of(root: &Path, i: usize) -> PathBuf {
    root.join(format!("-work-p{}", i % PROJECTS))
        .join(format!("00000000-0000-4000-8000-{i:012}.jsonl"))
}

fn line(path: &Path, text: &str) {
    use std::io::Write as _;
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{text}");
    }
}

fn user_line(i: usize) -> String {
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"s{i}","timestamp":"2026-11-12T01:00:00.000Z","message":{{"role":"user","content":"chat {i}"}}}}"#,
        i % PROJECTS
    )
}

/// The tree: the 170 live sessions with their subagent and tool-result folders, and idle
/// transcripts as a real projects root holds them.
fn tree(root: &Path) {
    for i in 0..WRITERS + IDLE_TRANSCRIPTS {
        let session = session_of(root, i);
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        line(&session, &user_line(i));
        if i < WRITERS {
            let folder = session.with_extension("");
            std::fs::create_dir_all(folder.join("subagents")).unwrap();
            std::fs::create_dir_all(folder.join("tool-results")).unwrap();
        }
    }
}

/// The child: 170 writers at 2 writes a second each, paced as one stream (340 a second): each
/// writer's transcript, then a subagent's transcript or a tool's result.
#[test]
#[ignore = "the bench's writer process"]
fn writer() {
    let (Some(root), Some(secs)) = (std::env::var_os(ROOT_VAR), std::env::var(SECS_VAR).ok())
    else {
        return;
    };
    let root = PathBuf::from(root);
    let until = Instant::now() + Duration::from_secs(secs.parse().unwrap_or(60));
    let interval = Duration::from_secs(1) / (WRITERS as u32 * WRITES_PER_SECOND_EACH);
    let started = Instant::now();
    let filler = "x".repeat(300);
    for k in 0u64.. {
        let now = Instant::now();
        if now >= until {
            break;
        }
        let i = (k % WRITERS as u64) as usize;
        let round = k / WRITERS as u64;
        let session = session_of(&root, i);
        let folder = session.with_extension("");
        match round % 4 {
            0 | 2 => line(&session, &format!(r#"{{"type":"assistant","n":{k},"t":"{filler}"}}"#)),
            1 => line(&folder.join(format!("subagents/agent-a{i}.jsonl")), &filler),
            _ => {
                let _ = std::fs::write(
                    folder.join(format!("tool-results/toolu_{}.txt", k % 5)),
                    &filler,
                );
            }
        }
        if k % 100 == 0 {
            let _ = std::fs::write(count_file(&root), (k + 1).to_string());
        }
        let next = started + interval.mul_f64((k + 1) as f64);
        std::thread::sleep(next.saturating_duration_since(Instant::now()));
    }
}

/// Where the writer keeps its count of writes, outside the watched root.
fn count_file(root: &Path) -> PathBuf {
    root.with_extension("writes")
}

fn writes(root: &Path) -> u64 {
    std::fs::read_to_string(count_file(root)).ok().and_then(|t| t.trim().parse().ok()).unwrap_or(0)
}

#[derive(Clone, Copy, Debug)]
enum Mode {
    /// No watch: what this process costs on its own while the writers run.
    Nothing,
    /// notify's FSEvents watcher: latency 0 (the old watch).
    Notify,
    Stream(Duration),
}

/// One watch of `root` as the daemon runs it, with a sink that counts instead of an index.
struct Running {
    stop: Sender<Message>,
    thread: Option<std::thread::JoinHandle<()>>,
    deliveries: Arc<AtomicU64>,
    /// The changed paths FSEvents delivered (notify: one per event).
    events: Arc<AtomicU64>,
    passes: Arc<AtomicU64>,
    seen: Arc<Mutex<Vec<(PathBuf, Instant)>>>,
    _watch: Box<dyn Send>,
}

impl Running {
    fn start(root: &Path, mode: Mode) -> Self {
        let (tx, rx) = std::sync::mpsc::channel();
        let filter = Arc::new(Filter {
            roots: vec![WatchedRoot { path: root.to_path_buf(), kind: AdapterKind::ClaudeCode }],
        });
        let deliveries = Arc::new(AtomicU64::new(0));
        let events = Arc::new(AtomicU64::new(0));
        let watch: Box<dyn Send> = match mode {
            Mode::Nothing => Box::new(()),
            Mode::Notify => {
                use notify::Watcher as _;
                let (filter, tx, count) = (filter.clone(), tx.clone(), deliveries.clone());
                let paths = events.clone();
                let mut watcher = notify::recommended_watcher(move |event| {
                    count.fetch_add(1, Ordering::Relaxed);
                    paths.fetch_add(1, Ordering::Relaxed);
                    if let Some(message) = filter.handed_from_notify(event) {
                        let _ = tx.send(message);
                    }
                })
                .unwrap();
                watcher.watch(root, notify::RecursiveMode::Recursive).unwrap();
                Box::new(watcher)
            }
            Mode::Stream(latency) => {
                let (filter, tx, count) = (filter.clone(), tx.clone(), deliveries.clone());
                let changed = events.clone();
                let stream = crate::chats::fsevents::Stream::start(
                    root,
                    latency,
                    Box::new(move |paths, rescan| {
                        count.fetch_add(1, Ordering::Relaxed);
                        changed.fetch_add(paths.len() as u64, Ordering::Relaxed);
                        if let Some(message) = filter.handed_from_delivery(paths, rescan) {
                            let _ = tx.send(message);
                        }
                    }),
                )
                .unwrap();
                Box::new(stream)
            }
        };
        let passes = Arc::new(AtomicU64::new(0));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let (thread_passes, thread_seen) = (passes.clone(), seen.clone());
        let thread = std::thread::spawn(move || {
            coalesce(&mut Channel(rx), |burst| {
                thread_passes.fetch_add(1, Ordering::Relaxed);
                let now = Instant::now();
                thread_seen.lock().unwrap().extend(burst.paths.into_iter().map(|p| (p, now)));
                true
            });
        });
        Self { stop: tx, thread: Some(thread), deliveries, events, passes, seen, _watch: watch }
    }

    /// A new project folder and session; the time until an index pass holds it (None: 5 s).
    fn probe(&self, root: &Path, name: &str) -> Option<Duration> {
        let session =
            root.join(format!("-probe-{name}")).join("0199c0de-0000-4000-8000-00000000beef.jsonl");
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        let started = Instant::now();
        line(&session, &user_line(0));
        while started.elapsed() < Duration::from_secs(5) {
            if let Some((_, at)) = self.seen.lock().unwrap().iter().find(|(p, _)| *p == session) {
                return Some(at.saturating_duration_since(started));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        None
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.stop.send(Message::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn median<T: Copy + Ord>(mut values: Vec<T>) -> T {
    values.sort();
    values[values.len() / 2]
}

#[test]
#[ignore = "a bench: run on a fleet Mac"]
fn latency_table() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap().join("projects");
    tree(&root);
    let modes = [
        Mode::Nothing,
        Mode::Notify,
        Mode::Stream(Duration::ZERO),
        Mode::Stream(Duration::from_millis(250)),
        Mode::Stream(Duration::from_millis(500)),
        Mode::Stream(Duration::from_secs(1)),
        Mode::Stream(Duration::from_secs(2)),
    ];
    // With no writers: a new session's way to the index.
    let mut quiet = Vec::new();
    for (m, mode) in modes.iter().enumerate() {
        let running = Running::start(&root, *mode);
        std::thread::sleep(Duration::from_millis(500));
        let probes: Vec<Option<Duration>> = if matches!(mode, Mode::Nothing) {
            Vec::new()
        } else {
            (0..PROBES).map(|p| running.probe(&root, &format!("quiet-{m}-{p}"))).collect()
        };
        quiet.push(probes);
        std::thread::sleep(Duration::from_millis(500));
    }
    let per_mode = WARM + WINDOW * WINDOWS as u32 + Duration::from_secs(8);
    let total = per_mode.as_secs() * (modes.len() * ROUNDS) as u64 + 10;
    let mut writer = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["chats::watch::bench::writer", "--exact", "--ignored", "--test-threads", "1"])
        .env(ROOT_VAR, &root)
        .env(SECS_VAR, total.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(root.with_extension("writer-log")).unwrap())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_secs(2));
    #[derive(Default)]
    struct Row {
        cpu: Vec<Duration>,
        switches: Vec<u64>,
        deliveries: f64,
        events: f64,
        passes: f64,
        writes: f64,
        loaded: Vec<Option<Duration>>,
    }
    let mut rows: Vec<Row> = modes.iter().map(|_| Row::default()).collect();
    for _ in 0..ROUNDS {
        for (m, mode) in modes.iter().enumerate() {
            let running = Running::start(&root, *mode);
            std::thread::sleep(WARM);
            let counts = |r: &Running| {
                (
                    r.deliveries.load(Ordering::Relaxed),
                    r.events.load(Ordering::Relaxed),
                    r.passes.load(Ordering::Relaxed),
                )
            };
            let before = counts(&running);
            let written = writes(&root);
            let mut mark = usage();
            for _ in 0..WINDOWS {
                std::thread::sleep(WINDOW);
                let now = usage();
                rows[m].cpu.push(now.0.saturating_sub(mark.0));
                rows[m].switches.push(now.1.saturating_sub(mark.1));
                mark = now;
            }
            let after = counts(&running);
            rows[m].writes += (writes(&root) - written) as f64
                / (WINDOW * (WINDOWS * ROUNDS) as u32).as_secs_f64();
            let secs = (WINDOW * (WINDOWS * ROUNDS) as u32).as_secs_f64();
            rows[m].deliveries += (after.0 - before.0) as f64 / secs;
            rows[m].events += (after.1 - before.1) as f64 / secs;
            rows[m].passes += (after.2 - before.2) as f64 / secs;
            if !matches!(mode, Mode::Nothing) {
                let name = format!("load-{m}-{}", rows[m].loaded.len());
                rows[m].loaded.push(running.probe(&root, &name));
            }
        }
    }
    println!(
        "{WRITERS} writers x {WRITES_PER_SECOND_EACH}/s into a Claude Code projects root ({} transcripts); per {WINDOW:?} window, this process (the watch only), {ROUNDS} interleaved rounds:",
        WRITERS + IDLE_TRANSCRIPTS
    );
    println!(
        "mode | writes/s | CPU per window (median) | switches per window (median) | deliveries/s | paths/s | passes/s | new session to pass: quiet | under load"
    );
    for (m, mode) in modes.iter().enumerate() {
        let row = &rows[m];
        println!(
            "{mode:?} | {:.0} | {:?} ({:?}) | {:?} ({}) | {:.1} | {:.1} | {:.1} | {:?} | {:?}",
            row.writes,
            row.cpu,
            median(row.cpu.clone()),
            row.switches,
            median(row.switches.clone()),
            row.deliveries,
            row.events,
            row.passes,
            quiet[m],
            row.loaded,
        );
    }
    println!(
        "writer still running at the end: {:?}; its stderr: {:?}",
        writer.try_wait().map(|s| s.is_none()),
        std::fs::read_to_string(root.with_extension("writer-log")).unwrap_or_default()
    );
    let _ = writer.kill();
    let _ = writer.wait();
}
