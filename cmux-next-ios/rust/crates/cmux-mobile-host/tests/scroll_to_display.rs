//! Mac scroll to iPhone display, with the Mac idle and with the Mac's CPU busy, and the gate on it
//! (Leo, 2026-11-22: "the scroll occurs or whatever on f***ing mac / then it delays on my actual
//! iphone display").
//!
//! One trial streams a scrolling full-screen terminal (40 rows of 100 columns, every redraw moves
//! the text up a row, 60 redraws a second, the way a pager or Claude Code's transcript scrolls)
//! from a Mac link to a phone link over cmux-fault's `good-wifi` shaper. Each redraw is stamped as
//! hostd's splice stamps it (`paint_latency::stamp_line`, then `send_marked`). The phone side does
//! the phone's receive work in Rust: it splits the line, parses its JSON and decodes its base64,
//! then counts it shown. hostd's own join (`paint_latency::summarize`) gives (a) Mac read to
//! socket, (b) the wire and (c) the phone's receive to decoded, and the total, p50/p95. Both ends
//! share this machine's clock, so the clock offset is 0 and the wire has no estimate error. The
//! phone's real present comes from the simulator (TerminalPaintTally, tuipan's paint p50/p95);
//! a display test gates nothing, so this Linux number is the one the gate reads.
//!
//! The Mac and the phone are two runtimes on disjoint cores (Linux `sched_setaffinity`): the phone
//! and the shaper (the network) get the last core, the Mac's runtime (4 workers, like hostd's
//! link tasks) the rest. Two arms, each [`TRIALS`] trials of [`LINES`] redraws, side by side:
//! - `idle`: nothing else runs.
//! - `loaded`: [`LOAD_PER_CORE`] busy threads per Mac core spin for the whole arm, on the Mac's
//!   cores only, started and stopped (joined) by the bench and never past [`LOAD_BOUND`]: a Mac
//!   running a build, its cores oversubscribed, while the phone stays idle.
//!
//! The gate: each arm's p95 total (the median of its trials' p95) must stay at or under its
//! `total_p95_ms * (1 + margin_ratio) + margin_ms` in `scroll_to_display_baseline.json`, measured
//! with this same test on Linux CI; the margins and the runs they come from are written there.
//!
//! `cargo test --release -p cmux-mobile-host --test scroll_to_display -- --ignored --nocapture`
//! (`SCROLL_GATE=off` prints the rows and skips the comparison.)

use std::hint::black_box;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use base64::Engine as _;
use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::paint_latency;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::frame::epoch_us;
use cmux_mobile_link::link::{Link, LinkConfig, Role};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;

/// Redraws per trial (5 s at 60 Hz).
const LINES: u64 = 300;
/// Trials per arm; an arm's number is the median of its trials.
const TRIALS: usize = 7;
const EVERY: Duration = Duration::from_micros(16_667);
const ROWS: usize = 40;
const COLS: usize = 100;
/// Busy threads per Mac core in the loaded arm: a Mac running a build has more runnable threads
/// than cores (cargo and swiftc start a job per core, each with threads of its own). One per core
/// moved nothing here (Linux's wakeup preemption lets the link's short tasks in at once).
const LOAD_PER_CORE: usize = 2;
/// [`LOAD_PER_CORE`], or `SCROLL_LOAD_PER_CORE` for a one-off measurement.
fn load_per_core() -> usize {
    std::env::var("SCROLL_LOAD_PER_CORE").ok().and_then(|v| v.parse().ok()).unwrap_or(LOAD_PER_CORE)
}
/// The busy arm never outlives this, even if a trial hangs.
const LOAD_BOUND: Duration = Duration::from_secs(300);

/// The Mac's cores and the phone's: the last core for the phone and the network, the rest for the
/// Mac. One core (or not Linux): no split, both get every core.
fn cores() -> (Vec<usize>, Vec<usize>) {
    let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    if n < 2 || !cfg!(target_os = "linux") {
        return ((0..n).collect(), (0..n).collect());
    }
    ((0..n - 1).collect(), vec![n - 1])
}

/// Pins the calling thread to `cpus` (Linux only; elsewhere a no-op).
fn pin(cpus: &[usize]) {
    #[cfg(target_os = "linux")]
    // SAFETY: a zeroed cpu_set_t is a valid empty set; CPU_SET writes inside it, and
    // sched_setaffinity(0) reads it for the calling thread.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        for &cpu in cpus {
            libc::CPU_SET(cpu, &mut set);
        }
        let rc = libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
        assert_eq!(rc, 0, "sched_setaffinity({cpus:?})");
    }
    #[cfg(not(target_os = "linux"))]
    let _ = cpus;
}

fn runtime(name: &str, workers: usize, cpus: Vec<usize>) -> Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .thread_name(name)
        .on_thread_start(move || pin(&cpus))
        .enable_all()
        .build()
        .unwrap()
}

/// The screen after `i` rows of scrolling: every row repainted, its text one row further on.
fn scrolled_screen(i: u64) -> Vec<u8> {
    let mut raw = Vec::with_capacity(ROWS * (COLS + 24));
    for r in 0..ROWS {
        let line = i as usize + r;
        raw.extend_from_slice(format!("\x1b[{};1H\x1b[2K\x1b[38;5;{}m", r + 1, 16 + line % 216).as_bytes());
        let text =
            format!("{line:>6} │ scrolling the transcript, one row per redraw, the way a pager repaints ");
        raw.extend(text.bytes().cycle().take(COLS - 8));
        raw.extend_from_slice(b"\x1b[0m");
    }
    let data = base64::engine::general_purpose::STANDARD.encode(raw);
    format!("{{\"data\":\"{data}\",\"event\":\"output\",\"surface\":1}}\n").into_bytes()
}

/// [`LOAD_PER_CORE`] busy threads per Mac core, pinned to the Mac's cores, until dropped (or
/// [`LOAD_BOUND`]); drop joins them.
struct CpuLoad {
    stop: Arc<AtomicBool>,
    threads: Vec<std::thread::JoinHandle<u64>>,
}

impl CpuLoad {
    fn start(mac_cpus: &[usize]) -> CpuLoad {
        let stop = Arc::new(AtomicBool::new(false));
        let started = std::time::Instant::now();
        let threads = (0..mac_cpus.len() * load_per_core())
            .map(|_| {
                let stop = Arc::clone(&stop);
                let cpus = mac_cpus.to_vec();
                std::thread::spawn(move || {
                    pin(&cpus);
                    let mut x = 0x9e37_79b9_7f4a_7c15_u64;
                    while !stop.load(Ordering::Relaxed) && started.elapsed() < LOAD_BOUND {
                        for _ in 0..10_000 {
                            x = black_box(x.rotate_left(5) ^ x.wrapping_mul(0x2545_f491_4f6c_dd1d));
                        }
                    }
                    x
                })
            })
            .collect();
        CpuLoad { stop, threads }
    }
}

impl Drop for CpuLoad {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

/// One trial: [`LINES`] redraws Mac to phone; hostd's join of them (offset 0).
fn trial(mac_rt: &Runtime, phone_rt: &Runtime, label: &str) -> paint_latency::Summary {
    let listener = mac_rt.block_on(TcpListener::bind("127.0.0.1:0")).unwrap();
    let mac_addr = listener.local_addr().unwrap();
    let mac = mac_rt.spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        stream.set_nodelay(true).unwrap();
        let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
        let terminal = mac.accept().await.expect("terminal channel");
        let (sender, _receiver) = terminal.channel.split();
        let mut tick = tokio::time::interval(EVERY);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
        for i in 0..LINES {
            tick.tick().await;
            // The daemon's line, read by hostd now: stamped as the splice stamps it.
            let (line, mark) = paint_latency::stamp_line(scrolled_screen(i));
            assert!(mark.is_some());
            sender.send_marked(Bytes::from(line), mark).await.unwrap();
        }
        (mac, sender)
    });

    let phone = phone_rt.spawn(async move {
        let profile = ProfileFile::builtin().get("good-wifi").cloned().expect("good-wifi profile");
        let shaper = Shaper::start(mac_addr, profile, 7, &Trace::new()).await.unwrap();
        let stream = TcpStream::connect(shaper.addr()).await.unwrap();
        stream.set_nodelay(true).unwrap();
        let phone = Link::new(stream, Role::Phone, LinkConfig::default(), None);
        let mut terminal = phone.open("terminal", serde_json::json!({})).await.unwrap();
        let mut samples = Vec::with_capacity(LINES as usize);
        let mut pending = Vec::new();
        let mut shown = 0usize;
        while samples.len() < LINES as usize {
            let Some(ChannelEvent::Data(bytes)) =
                tokio::time::timeout(Duration::from_secs(60), terminal.recv())
                    .await
                    .expect("a redraw in 60 s")
            else {
                panic!("terminal closed")
            };
            let rx = epoch_us() as f64 / 1000.0;
            pending.extend_from_slice(&bytes);
            while let Some(end) = pending.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = pending.drain(..=end).collect();
                let seq = paint_latency::trailing_seq(&line).expect("a stamped line");
                // The phone's receive work: the event's JSON, then the screen bytes it carries.
                let event: serde_json::Value = serde_json::from_slice(&line).expect("an event line");
                let screen = base64::engine::general_purpose::STANDARD
                    .decode(event["data"].as_str().expect("data"))
                    .expect("base64");
                shown += black_box(screen.len());
                let painted = epoch_us() as f64 / 1000.0;
                samples.push([seq as f64, rx, painted]);
            }
        }
        assert!(shown > 0);
        (samples, phone, shaper)
    });
    let (samples, _phone, _shaper) = phone_rt.block_on(phone).unwrap();
    let (_mac, _sender) = mac_rt
        .block_on(async { tokio::time::timeout(Duration::from_secs(60), mac).await })
        .expect("the Mac side ends")
        .unwrap();
    let report = serde_json::json!({"program": "scroll", "load": label, "samples": samples,
        "clock": [[0.0, 0.0, 0.0, 0.0]]});
    let report: paint_latency::Report = serde_json::from_value(report).unwrap();
    let summary = paint_latency::summarize(report, "phone-1", 0, paint_latency::lookup);
    assert_eq!(summary.joined, LINES as usize, "{label}: every stamp joined");
    summary
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
struct Arm {
    total_p50_ms: f64,
    total_p95_ms: f64,
    mac_p95_ms: f64,
    wire_p95_ms: f64,
    phone_p95_ms: f64,
    /// Every trial's p95 total, for the noise.
    trials_p95_ms: [f64; TRIALS],
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    let round = |v: f64| (v * 100.0).round() / 100.0;
    round(values[values.len() / 2])
}

fn arm(mac_rt: &Runtime, phone_rt: &Runtime, label: &str) -> Arm {
    let runs: Vec<_> = (0..TRIALS).map(|_| trial(mac_rt, phone_rt, label)).collect();
    let pick = |f: &dyn Fn(&paint_latency::Summary) -> f64| median(runs.iter().map(f).collect());
    let mut trials_p95_ms = [0.0; TRIALS];
    for (slot, run) in trials_p95_ms.iter_mut().zip(&runs) {
        *slot = run.total.unwrap().p95_ms;
    }
    Arm {
        total_p50_ms: pick(&|s| s.total.unwrap().p50_ms),
        total_p95_ms: pick(&|s| s.total.unwrap().p95_ms),
        mac_p95_ms: pick(&|s| s.mac.unwrap().p95_ms),
        wire_p95_ms: pick(&|s| s.wire.unwrap().p95_ms),
        phone_p95_ms: pick(&|s| s.phone_paint.unwrap().p95_ms),
        trials_p95_ms,
    }
}

/// The machine's CPU, for reading rows from unlike runners apart.
fn cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|info| {
            info.lines()
                .find(|l| l.starts_with("model name"))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_owned())
        })
        .unwrap_or_default()
}

#[derive(Debug, serde::Deserialize)]
struct Baseline {
    idle: BaselineArm,
    loaded: BaselineArm,
}

/// An arm's p95 total and its margin: the limit is `total_p95_ms * (1 + margin_ratio) + margin_ms`.
#[derive(Debug, serde::Deserialize)]
struct BaselineArm {
    total_p95_ms: f64,
    margin_ratio: f64,
    margin_ms: f64,
}

#[test]
#[ignore = "a measurement and its gate (about a minute): --release --ignored --nocapture"]
fn mac_scroll_to_phone_display_idle_and_loaded_stays_under_its_baseline() {
    let (mac_cpus, phone_cpus) = cores();
    pin(&phone_cpus);
    let mac_rt = runtime("mac", 4, mac_cpus.clone());
    let phone_rt = runtime("phone", 2, phone_cpus.clone());
    let idle = arm(&mac_rt, &phone_rt, "idle");
    let loaded = {
        let _load = CpuLoad::start(&mac_cpus);
        arm(&mac_rt, &phone_rt, "loaded")
    };
    let busy = mac_cpus.len() * load_per_core();
    for (name, a) in [("idle", &idle), ("loaded", &loaded)] {
        println!(
            "SCROLL-ROW {name}: total p50 {} p95 {} | a mac p95 {} | b wire p95 {} | c phone p95 {} | trial p95s {:?} | mac cores {} phone cores {} busy threads {}",
            a.total_p50_ms,
            a.total_p95_ms,
            a.mac_p95_ms,
            a.wire_p95_ms,
            a.phone_p95_ms,
            a.trials_p95_ms,
            mac_cpus.len(),
            phone_cpus.len(),
            if name == "loaded" { busy } else { 0 }
        );
    }
    println!(
        "SCROLL-JSON {}",
        serde_json::json!({"idle": idle, "loaded": loaded, "mac_cores": mac_cpus.len(), "busy_threads": busy,
            "cpu": cpu_model()})
    );

    if std::env::var("SCROLL_GATE").as_deref() == Ok("off") {
        return;
    }
    let baseline: Baseline = serde_json::from_str(include_str!("scroll_to_display_baseline.json")).unwrap();
    let mut over = Vec::new();
    for (name, measured, base) in [("idle", &idle, &baseline.idle), ("loaded", &loaded, &baseline.loaded)] {
        let limit = base.total_p95_ms * (1.0 + base.margin_ratio) + base.margin_ms;
        let ok = measured.total_p95_ms <= limit;
        println!(
            "SCROLL-GATE {name}: p95 {} ms, baseline {} ms, limit {limit:.2} ms: {}",
            measured.total_p95_ms,
            base.total_p95_ms,
            if ok { "ok" } else { "REGRESSED" }
        );
        if !ok {
            over.push(format!("{name} p95 {} ms > {limit:.2} ms", measured.total_p95_ms));
        }
    }
    assert!(
        over.is_empty(),
        "Mac scroll to phone display regressed past scroll_to_display_baseline.json: {}",
        over.join("; ")
    );
}
