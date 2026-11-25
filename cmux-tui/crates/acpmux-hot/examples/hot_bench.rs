//! The prototype's numbers: per-call cost against native, and what a swap and a rollback take
//! while another thread keeps calling. `bench.sh` builds the guest variants and runs this.
//!
//! `hot_bench GOOD.wasm V2.wasm TRAP.wasm SPIN.wasm LIVE.wasm OUT.json`; LIVE must sit in a
//! private folder of a git checkout (`trust.rs`), and is overwritten.

use acpmux_hot::{HotModule, Options};
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// The `Agent` that acpmux's `parse.rs` names as `super::Agent`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // Gemini and Grok: parse.rs names them; the WIT world reads only the first two.
pub enum Agent {
    Claude,
    Codex,
    Gemini,
    Grok,
}

#[allow(dead_code)]
#[path = "../../acpmux/src/agent_login/parse.rs"]
mod parse;

#[allow(dead_code)]
#[path = "../../acpmux/src/write_journal/classify.rs"]
mod classify;

const MARKER: &str = "acpmux-hot-v2-marker";

fn main() {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [good, v2, trap, spin, live, out] = args.as_slice() else {
        eprintln!("usage: hot_bench GOOD V2 TRAP SPIN LIVE OUT.json");
        std::process::exit(2);
    };
    let mut report = serde_free::Obj::default();
    report.str("host", &host());
    report.str("profile", if cfg!(debug_assertions) { "debug" } else { "release" });
    report.num("good_wasm_bytes", std::fs::metadata(good).map_or(0, |m| m.len()) as f64);

    for (name, fuel) in [("fuel", Options::default().fuel_per_call), ("no_fuel", None)] {
        place(good, live);
        let slot = HotModule::new(live, Options { fuel_per_call: fuel, ..Options::default() })
            .expect("slot");
        let swap = slot.reload().expect("load").expect("loaded");
        report.num(&format!("{name}.first_load.compile_ms"), ms(swap.compile));
        report.num(&format!("{name}.first_load.probe_ms"), ms(swap.probe));
        report.num(&format!("{name}.first_load.publish_us"), swap.publish.as_secs_f64() * 1e6);
        let cold = Instant::now();
        assert_eq!(slot.is_pure_read("ls"), Some(true));
        report.num(&format!("{name}.first_call_on_thread_us"), cold.elapsed().as_secs_f64() * 1e6);
        for case in cases() {
            let (native, wasm) = per_call(&slot, &case);
            report.num(&format!("{name}.{}.native_ns.p50", case.name), native.p50);
            report.num(&format!("{name}.{}.native_ns.p99", case.name), native.p99);
            report.num(&format!("{name}.{}.wasm_ns.p50", case.name), wasm.p50);
            report.num(&format!("{name}.{}.wasm_ns.p99", case.name), wasm.p99);
            report.num(&format!("{name}.{}.wasm_ns.max", case.name), wasm.max);
            eprintln!(
                "{name:8} {:24} native p50 {:>9.0} ns p99 {:>9.0} | wasm p50 {:>9.0} ns p99 {:>9.0} max {:>9.0}",
                case.name, native.p50, native.p99, wasm.p50, wasm.p99, wasm.max
            );
        }
    }

    swaps(good, v2, trap, spin, live, &mut report);
    let failed = regressions(good, v2, trap, spin, live, &mut report);
    std::fs::write(out, report.finish()).expect("write report");
    assert!(failed.is_empty(), "regressions failed: {failed:?}");
}

/// Swaps under load: a caller thread asks the marker in a loop while the file changes under it.
fn swaps(
    good: &Path,
    v2: &Path,
    trap: &Path,
    spin: &Path,
    live: &Path,
    report: &mut serde_free::Obj,
) {
    place(good, live);
    let slot = HotModule::new(live, Options::default()).expect("slot");
    let _watcher = slot.watch(Duration::from_millis(5)).expect("watcher");
    wait_until(|| slot.live().is_some(), "first load");

    let stop = Arc::new(AtomicBool::new(false));
    let v2_seen_ns = Arc::new(AtomicU64::new(0));
    let worst_ns = Arc::new(AtomicU64::new(0));
    let calls = Arc::new(AtomicU64::new(0));
    let fallbacks = Arc::new(AtomicU64::new(0));
    let epoch = Instant::now();
    let caller = {
        let (slot, stop, v2_seen_ns, worst_ns, calls, fallbacks) = (
            slot.clone(),
            stop.clone(),
            v2_seen_ns.clone(),
            worst_ns.clone(),
            calls.clone(),
            fallbacks.clone(),
        );
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                let t = Instant::now();
                let answer = slot.is_pure_read(MARKER);
                let took = t.elapsed().as_nanos() as u64;
                worst_ns.fetch_max(took, Ordering::Relaxed);
                calls.fetch_add(1, Ordering::Relaxed);
                match answer {
                    Some(true) if v2_seen_ns.load(Ordering::Relaxed) == 0 => {
                        v2_seen_ns.store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                    }
                    None => {
                        fallbacks.fetch_add(1, Ordering::Relaxed);
                    }
                    _ => {}
                }
            }
        })
    };
    std::thread::sleep(Duration::from_millis(50));
    worst_ns.store(0, Ordering::Relaxed);

    // 1. good -> v2: file written to the first call v2 answers.
    let written = epoch.elapsed();
    place(v2, live);
    wait_until(|| v2_seen_ns.load(Ordering::Relaxed) != 0, "v2 answering");
    let seen = Duration::from_nanos(v2_seen_ns.load(Ordering::Relaxed));
    report.num("swap.write_to_first_v2_answer_ms", ms(seen - written));
    report.num("swap.worst_call_during_swap_us", worst_ns.load(Ordering::Relaxed) as f64 / 1e3);
    report.num("swap.fallbacks_during_swap", fallbacks.load(Ordering::Relaxed) as f64);

    // 2. v2 -> trap: the first call traps, answers None (native), and the slot rolls back to v2.
    let before = slot.stats();
    let v2_sha = slot.live();
    let trap_written = Instant::now();
    place(trap, live);
    wait_until(|| slot.stats().rollbacks > before.rollbacks, "trap rollback");
    report.num("trap.write_to_rollback_ms", ms(trap_written.elapsed()));
    wait_until(|| slot.live() == v2_sha, "v2 live again");
    report.num("trap.fallback_calls", (slot.stats().fallbacks - before.fallbacks) as f64);

    // 3. v2 -> spin: the guest loops until its fuel runs out, then the same rollback.
    let before = slot.stats();
    let spin_written = Instant::now();
    place(spin, live);
    wait_until(|| slot.stats().rollbacks > before.rollbacks, "fuel rollback");
    report.num("spin.write_to_rollback_ms", ms(spin_written.elapsed()));
    report.num("spin.worst_call_us", worst_ns.load(Ordering::Relaxed) as f64 / 1e3);
    assert_eq!(slot.live(), v2_sha, "rolled back to v2");

    stop.store(true, Ordering::Relaxed);
    caller.join().expect("caller");
    let s = slot.stats();
    report.num("total.calls", calls.load(Ordering::Relaxed) as f64);
    report.num("total.swaps", s.swaps as f64);
    report.num("total.traps", s.traps as f64);
    report.num("total.rollbacks", s.rollbacks as f64);
    report.num("total.refused", s.refused as f64);
    eprintln!("swap/rollback: {s:?}");
}

struct Case {
    name: &'static str,
    /// The native function's answer, as text so the two sides compare.
    native: Box<dyn Fn() -> String>,
    /// The module's answer; panics if the module did not answer.
    wasm: Box<dyn Fn(&HotModule) -> String>,
}

fn cases() -> Vec<Case> {
    let read_short = "git status --short".to_owned();
    let exec_short = "cargo build -p acpmux".to_owned();
    let read_long = format!("rg -n foo {} | head -50 && cat README.md", "src/a.rs ".repeat(400));
    let claude = "\u{1b}[2mOpening browser\u{1b}[0m\r\n\u{1b}]8;;https://claude.ai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback\u{7}Sign in\u{1b}]8;;\u{7}\n".to_owned();
    let codex = "Sign in at https://auth.openai.com/codex/device \nEnter this one-time code\n  ABCD-1234\n\n".to_owned();
    let long_log =
        format!("{}{codex}", "\u{1b}[32mwaiting\u{1b}[0m for the browser...\n".repeat(1500));
    let mut out: Vec<Case> = Vec::new();
    for (name, cmd) in
        [("read_short", read_short), ("exec_short", exec_short), ("read_4k", read_long)]
    {
        let cmd = Arc::new(cmd);
        let c2 = cmd.clone();
        out.push(Case {
            name,
            native: Box::new(move || classify::is_pure_read(black_box(&cmd)).to_string()),
            wasm: Box::new(move |slot| {
                slot.is_pure_read(black_box(&c2)).expect("wasm answered").to_string()
            }),
        });
    }
    for (name, agent, text) in [
        ("offer_claude", Agent::Claude, claude),
        ("offer_codex", Agent::Codex, codex),
        ("offer_codex_64k", Agent::Codex, long_log),
    ] {
        let hot_agent = match agent {
            Agent::Claude => acpmux_hot::Agent::Claude,
            Agent::Codex => acpmux_hot::Agent::Codex,
            Agent::Gemini | Agent::Grok => continue,
        };
        let text = Arc::new(text);
        let t2 = text.clone();
        out.push(Case {
            name,
            native: Box::new(move || {
                format!("{:?}", parse::offer(agent, black_box(&text)).map(|o| (o.url, o.user_code)))
            }),
            wasm: Box::new(move |slot| {
                let offer = slot.login_offer(hot_agent, black_box(&t2)).expect("wasm answered");
                format!("{:?}", offer.map(|o| (o.url, o.user_code)))
            }),
        });
    }
    out
}

struct Dist {
    p50: f64,
    p99: f64,
    max: f64,
}

/// Native and wasm per-call times (ns), interleaved so both see the same machine.
fn per_call(slot: &HotModule, case: &Case) -> (Dist, Dist) {
    let (n, w) = ((case.native)(), (case.wasm)(slot));
    assert_eq!(n, w, "{}: native and wasm disagree", case.name);
    assert_ne!(n, "None", "{}: the case should find an offer", case.name);
    let rounds = 3000;
    let mut native = Vec::with_capacity(rounds);
    let mut wasm = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let t = Instant::now();
        black_box((case.native)());
        native.push(t.elapsed().as_nanos() as f64);
        let t = Instant::now();
        black_box((case.wasm)(slot));
        wasm.push(t.elapsed().as_nanos() as f64);
    }
    (dist(native), dist(wasm))
}

fn dist(mut v: Vec<f64>) -> Dist {
    v.sort_by(f64::total_cmp);
    let at = |q: f64| v[((v.len() - 1) as f64 * q) as usize];
    Dist { p50: at(0.5), p99: at(0.99), max: *v.last().unwrap_or(&0.0) }
}

/// The review follow-ups of #36427, each as a scenario that fails on the code before its fix.
/// Returns the names of the ones that failed.
fn regressions(
    good: &Path,
    v2: &Path,
    trap: &Path,
    spin: &Path,
    live: &Path,
    report: &mut serde_free::Obj,
) -> Vec<&'static str> {
    let mut failed = Vec::new();
    let mut check = |name: &'static str, ok: bool, report: &mut serde_free::Obj| {
        report.num(&format!("regression.{name}"), if ok { 1.0 } else { 0.0 });
        eprintln!("regression {name}: {}", if ok { "ok" } else { "FAILED" });
        if !ok {
            failed.push(name);
        }
    };

    // 1. A stale call traps after a newer module went live: the trapped module must not stay the
    // rollback target. A long-running `spin` call is in flight while `trap` is published; the
    // spin call then runs out of fuel (stale), and the next call traps in `trap`. The slot must
    // end on native code, not back on the refused `spin`.
    {
        // Fuel for a spin call of about 1.5 s on this machine, timed from a short one, so the
        // stale call is still running when the publish (40 to 140 ms of compile) lands.
        place(spin, live);
        let probe_fuel = 1_000_000_000u64;
        let probe =
            HotModule::new(live, Options { fuel_per_call: Some(probe_fuel), ..Options::default() })
                .expect("probe slot");
        probe.reload().expect("load spin");
        let t = Instant::now();
        let _ = probe.is_pure_read("ls");
        let per_s = probe_fuel as f64 / t.elapsed().as_secs_f64().max(1e-6);
        report.num("regression.stale_trap.fuel_per_s", per_s);
        let fuel = (per_s * 1.5) as u64;
        let options = Options { fuel_per_call: Some(fuel), ..Options::default() };
        let slot = HotModule::new(live, options).expect("slot");
        slot.reload().expect("load spin");
        let caller = {
            let slot = slot.clone();
            std::thread::spawn(move || slot.is_pure_read("ls"))
        };
        std::thread::sleep(Duration::from_millis(20));
        place(trap, live);
        slot.reload().expect("load trap");
        let still_running = !caller.is_finished();
        let stale = caller.join().expect("stale caller");
        let fresh = slot.is_pure_read("ls");
        report
            .num("regression.stale_trap.spin_outlived_publish", f64::from(u8::from(still_running)));
        check(
            "stale_trap_rollback",
            still_running && stale.is_none() && fresh.is_none() && slot.live().is_none(),
            report,
        );
    }

    // 2. The module file does not exist when the slot is made (a daemon started before the first
    // guest build): the slot still watches, and loads the file once it appears.
    {
        let _ = std::fs::remove_file(live);
        let slot = HotModule::new(live, Options::default());
        let loaded = match &slot {
            Ok(slot) => {
                let _watcher = slot.watch(Duration::from_millis(5)).expect("watcher");
                place(good, live);
                wait_for(|| slot.live().is_some(), Duration::from_secs(5))
            }
            Err(e) => {
                eprintln!("regression missing_file_at_start: {e}");
                false
            }
        };
        check("missing_file_at_start", loaded, report);
    }

    // 3. A rewrite in place that keeps size, mtime and inode (bytes refused, then a valid module of
    // the same size with the mtime put back) is still noticed.
    {
        place(good, live);
        let slot = HotModule::new(live, Options::default()).expect("slot");
        let _watcher = slot.watch(Duration::from_millis(5)).expect("watcher");
        wait_until(|| slot.live().is_some(), "good live");
        let v2_bytes = std::fs::read(v2).expect("read v2");
        let v2_sha = hex::encode(<sha2::Sha256 as sha2::Digest>::digest(&v2_bytes));
        let when = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let rewrite = |bytes: &[u8]| {
            use std::io::Write as _;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .truncate(true)
                .open(live)
                .expect("open live");
            f.write_all(bytes).expect("rewrite live");
            f.set_modified(when).expect("set mtime");
        };
        let refused = slot.stats().refused;
        rewrite(&vec![0u8; v2_bytes.len()]);
        let saw_junk = wait_for(|| slot.stats().refused > refused, Duration::from_secs(5));
        rewrite(&v2_bytes);
        let swapped =
            wait_for(|| slot.live().as_deref() == Some(v2_sha.as_str()), Duration::from_secs(3));
        check("rewrite_keeping_metadata", saw_junk && swapped, report);
    }
    failed
}

fn wait_for(mut done: impl FnMut() -> bool, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while !done() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_micros(500));
    }
    true
}

fn place(from: &Path, live: &Path) {
    // Written beside it and renamed over it, as an atomic replace (what `bench.sh`'s cp -f is not).
    let tmp = live.with_extension("tmp");
    std::fs::copy(from, &tmp).expect("copy module");
    std::fs::rename(&tmp, live).expect("rename module");
}

fn wait_until(mut done: impl FnMut() -> bool, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_micros(200));
    }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn host() -> String {
    std::process::Command::new("uname")
        .arg("-a")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// A flat JSON object without a serde dependency.
mod serde_free {
    #[derive(Default)]
    pub struct Obj(Vec<String>);
    impl Obj {
        pub fn num(&mut self, k: &str, v: f64) {
            self.0.push(format!("\"{k}\": {v:.3}"));
        }
        pub fn str(&mut self, k: &str, v: &str) {
            self.0.push(format!("\"{k}\": \"{}\"", v.replace('\\', "\\\\").replace('"', "\\\"")));
        }
        pub fn finish(&self) -> String {
            format!("{{\n  {}\n}}\n", self.0.join(",\n  "))
        }
    }
}
