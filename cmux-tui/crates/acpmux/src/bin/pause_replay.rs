//! Pause-policy replay: runs a Cloud agent VM pause policy over real per-session activity
//! timelines and scores it. Dev only, built only with `--features pause-replay`; nothing in the
//! daemon calls it and it changes no product behaviour.
//!
//! Leo, 2026-11-23 06:31Z: "we need to hill climb and ultra dogfood the individual pausing and
//! resuming." His rule (2026-11-24, relayed): measure dynamic policies, not only fixed settings;
//! replay real traces, then A/B; report the static best, the dynamic best and the gap.
//!
//! Input: the timelines JSON written by the lane's extractor (no text, hashed ids):
//! `{"sessions":[{"id","kind","tail","events":[[t_seconds, code, class], ...]}]}` with codes
//! `in` (an inbound that wakes the agent; class person/agent/bg/notice/retry), `a` (activity in a
//! turn), `t` (a tool call started; class), `r` (a tool call returned), `bg` (outstanding
//! background tasks, as a number).
//!
//! Model. Each gap between two events is either busy (the agent was working: a model call or a
//! tool running; awake under every policy), held (idle, but a background task the agent started
//! is still running; awake under every policy) or idle (no open tool call, no background task,
//! and the next event is an inbound). A policy picks, at the start of each idle gap, how long to
//! stay awake before pausing. A gap longer than that ends in a resume: the VM pays the resume as
//! awake time and the inbound waits for it. The session's tail after its last event is idle with
//! no wake.
//!
//! Usage: `cargo run -p acpmux --features pause-replay --bin pause-replay -- timelines.json`

use std::collections::HashMap;

use serde::Deserialize;

/// Idle timeout the Cloud agent VM pauses at today (seconds).
const TODAY_SECONDS: f64 = 900.0;
/// An inbound this soon after the turn's last event was already queued when the turn ended.
const PENDING_SECONDS: f64 = 1.0;
/// The session tail counted at most (a held-life cap; every timeout here is shorter).
const TAIL_CAP_SECONDS: f64 = 24.0 * 3600.0;
/// Timeouts a learned policy chooses from.
const GRID: [f64; 10] = [0.0, 5.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0, 900.0, 1800.0];

#[derive(Deserialize)]
struct Input {
    sessions: Vec<RawSession>,
}

#[derive(Deserialize)]
struct RawSession {
    id: String,
    kind: String,
    #[serde(default)]
    tail: f64,
    events: Vec<(f64, String, serde_json::Value)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum Wake {
    Person,
    Agent,
    Bg,
    Notice,
    Retry,
    /// A wait the agent started ended (only with `--pause-waits`).
    WaitEnd,
}

impl Wake {
    fn parse(s: &str) -> Self {
        match s {
            "person" => Wake::Person,
            "agent" => Wake::Agent,
            "bg" => Wake::Bg,
            "notice" => Wake::Notice,
            _ => Wake::Retry,
        }
    }
}

#[derive(Clone, Debug)]
struct Idle {
    secs: f64,
    /// None: the session's tail, which no inbound ends.
    wake: Option<Wake>,
    /// The last tool class of the turn that just ended ("none" if it called no tool).
    last_tool: String,
    /// Only a wait was running (a background or tool call that waits on CI, a PR or a timer):
    /// awake today; idle when the platform delivers the wait's end instead (`--pause-waits`).
    wait: bool,
}

#[derive(Clone, Debug, Default)]
struct Session {
    id: String,
    main: bool,
    busy: f64,
    held: f64,
    /// Seconds in which only waits ran (also listed in `idles` with `wait`).
    waits: f64,
    span: f64,
    idles: Vec<Idle>,
}

fn build(raw: &RawSession) -> Session {
    let mut s = Session { id: raw.id.clone(), main: raw.kind == "main", ..Default::default() };
    // Open tool calls' classes, oldest first (results are taken to return in order).
    let mut open: std::collections::VecDeque<String> = Default::default();
    let mut bg = 0i64;
    let mut bg_waits = 0i64;
    let mut last_tool = "none".to_string();
    for w in raw.events.windows(2) {
        let (t0, code0, v0) = &w[0];
        match code0.as_str() {
            "t" => {
                last_tool = v0.as_str().unwrap_or("other").to_string();
                open.push_back(last_tool.clone());
            }
            "r" => {
                open.pop_front();
            }
            "bg" => {
                // `[outstanding, of them waits]`, or a bare count.
                bg = v0.get(0).and_then(|v| v.as_i64()).or_else(|| v0.as_i64()).unwrap_or(0);
                bg_waits = v0.get(1).and_then(|v| v.as_i64()).unwrap_or(0).min(bg);
            }
            "in" => {
                open.clear(); // a new turn: a tool still open was cancelled or its result was lost
                last_tool = "none".to_string();
            }
            _ => {}
        }
        let (t1, code1, v1) = &w[1];
        let gap = (t1 - t0).max(0.0);
        let compute_bg = bg - bg_waits > 0;
        let only_waits_open = !open.is_empty() && open.iter().all(|c| c == "wait");
        if code1 == "in" && open.is_empty() && !compute_bg && bg == 0 {
            let wake = Wake::parse(v1.as_str().unwrap_or(""));
            s.idles.push(Idle {
                secs: gap,
                wake: Some(wake),
                last_tool: last_tool.clone(),
                wait: false,
            });
        } else if !compute_bg && ((code1 == "in" && open.is_empty() && bg > 0) || only_waits_open) {
            // Only waits running: the wait's end (or an inbound) wakes the agent.
            s.waits += gap;
            s.idles.push(Idle {
                secs: gap,
                wake: Some(Wake::WaitEnd),
                last_tool: "wait".into(),
                wait: true,
            });
        } else if code1 == "in" && open.is_empty() {
            s.held += gap;
        } else {
            s.busy += gap;
        }
    }
    s.span = raw.events.last().map(|e| e.0).unwrap_or(0.0);
    if raw.tail > 0.0 {
        s.idles.push(Idle {
            secs: raw.tail.min(TAIL_CAP_SECONDS),
            wake: None,
            last_tool,
            wait: false,
        });
    }
    s
}

/// Resume cost in milliseconds: the awake time a resume costs and the wait it adds.
#[derive(Clone)]
enum ResumeCost {
    /// Log-normal through a measured p50 and p95.
    LogNormal { p50: f64, p95: f64 },
    /// Draw uniformly from measured samples.
    Samples(Vec<f64>),
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        // xorshift64*: deterministic, so a run's numbers reproduce.
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        (self.0.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
    }
    fn normal(&mut self) -> f64 {
        let u1 = self.next().max(1e-12);
        let u2 = self.next();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

impl ResumeCost {
    fn draw(&self, rng: &mut Rng) -> f64 {
        match self {
            ResumeCost::LogNormal { p50, p95 } => {
                let sigma = (p95 / p50).ln() / 1.644_853_6;
                p50 * (sigma * rng.normal()).exp()
            }
            ResumeCost::Samples(v) => v[((rng.next() * v.len() as f64) as usize).min(v.len() - 1)],
        }
    }
}

/// What a policy sees when an idle gap starts: nothing about how long it will be, except that an
/// inbound that already arrived (queued during the turn) is known.
struct Ctx<'a> {
    pending: bool,
    last_tool: &'a str,
}

trait Policy {
    fn name(&self) -> String;
    fn reset(&mut self) {}
    /// Seconds to stay awake before pausing (f64::INFINITY: stay awake).
    fn timeout(&mut self, ctx: &Ctx) -> f64;
    fn observe(&mut self, _idle: &Idle) {}
}

struct Fixed(f64);
impl Policy for Fixed {
    fn name(&self) -> String {
        format!("static {}", fmt_secs(self.0))
    }
    fn timeout(&mut self, _: &Ctx) -> f64 {
        self.0
    }
}

/// Ski rental over a set of gaps: the grid timeout with the least awake seconds plus
/// `lambda` seconds per resume.
fn best_timeout(gaps: &[f64], lambda: f64) -> f64 {
    let mut best = (f64::INFINITY, TODAY_SECONDS);
    for &t in &GRID {
        let cost: f64 = gaps.iter().map(|&g| if g > t { t + lambda } else { g }).sum();
        if cost < best.0 - 1e-9 {
            best = (cost, t);
        }
    }
    best.1
}

/// Per-session adaptive: the session's own last `window` idle gaps pick the timeout.
struct Adaptive {
    lambda: f64,
    window: usize,
    min_history: usize,
    cold: f64,
    hist: Vec<f64>,
}
impl Policy for Adaptive {
    fn name(&self) -> String {
        format!("adaptive (own gaps) λ={}", fmt_secs(self.lambda))
    }
    fn reset(&mut self) {
        self.hist.clear();
    }
    fn timeout(&mut self, ctx: &Ctx) -> f64 {
        if ctx.pending {
            return f64::INFINITY;
        }
        if self.hist.len() < self.min_history {
            return self.cold;
        }
        let from = self.hist.len().saturating_sub(self.window);
        best_timeout(&self.hist[from..], self.lambda)
    }
    fn observe(&mut self, idle: &Idle) {
        if idle.wake.is_some() {
            self.hist.push(idle.secs);
        }
    }
}

/// Pause at once at turn end unless an inbound is already pending (a background task running
/// keeps the VM awake under every policy). `grace` seconds awake first (0 for the pure rule).
struct TurnEnd {
    grace: f64,
}
impl Policy for TurnEnd {
    fn name(&self) -> String {
        if self.grace == 0.0 {
            "turn end, unless pending".into()
        } else {
            format!("turn end + {} grace, unless pending", fmt_secs(self.grace))
        }
    }
    fn timeout(&mut self, ctx: &Ctx) -> f64 {
        if ctx.pending { f64::INFINITY } else { self.grace }
    }
}

/// Next-gap predictor from the last tool-call class of the turn: a table class -> timeout,
/// learned on the other fold's sessions (2-fold by session id, so no session scores itself).
struct ByClass {
    lambda: f64,
    table: [HashMap<String, f64>; 2],
    fold: usize,
    /// Per-session history on top of the class prior once a session has enough gaps.
    with_history: Option<Adaptive>,
}
impl ByClass {
    fn train(sessions: &[Session], lambda: f64, with_history: bool) -> Self {
        let mut table: [HashMap<String, f64>; 2] = [HashMap::new(), HashMap::new()];
        for (fold, t) in table.iter_mut().enumerate() {
            let mut by: HashMap<String, Vec<f64>> = HashMap::new();
            for s in sessions.iter().filter(|s| fold_of(&s.id) != fold) {
                for i in s.idles.iter().filter(|i| i.wake.is_some() && !i.wait) {
                    by.entry(i.last_tool.clone()).or_default().push(i.secs);
                }
            }
            let all: Vec<f64> = by.values().flatten().copied().collect();
            t.insert("*".into(), best_timeout(&all, lambda));
            for (k, v) in by {
                if v.len() >= 20 {
                    t.insert(k, best_timeout(&v, lambda));
                }
            }
        }
        ByClass {
            lambda,
            table,
            fold: 0,
            with_history: with_history.then(|| Adaptive {
                lambda,
                window: 30,
                min_history: 10,
                cold: 0.0,
                hist: vec![],
            }),
        }
    }
}
impl Policy for ByClass {
    fn name(&self) -> String {
        if self.with_history.is_some() {
            format!("last-tool class + own gaps λ={}", fmt_secs(self.lambda))
        } else {
            format!("last-tool class λ={}", fmt_secs(self.lambda))
        }
    }
    fn reset(&mut self) {
        if let Some(a) = &mut self.with_history {
            a.reset();
        }
    }
    fn timeout(&mut self, ctx: &Ctx) -> f64 {
        if ctx.pending {
            return f64::INFINITY;
        }
        if let Some(a) = &mut self.with_history
            && a.hist.len() >= a.min_history
        {
            return a.timeout(ctx);
        }
        let t = &self.table[self.fold];
        *t.get(ctx.last_tool).or_else(|| t.get("*")).unwrap_or(&TODAY_SECONDS)
    }
    fn observe(&mut self, idle: &Idle) {
        if let Some(a) = &mut self.with_history {
            a.observe(idle);
        }
    }
}

fn fold_of(id: &str) -> usize {
    id.bytes().last().map(|b| (b % 2) as usize).unwrap_or(0)
}

#[derive(Clone, Debug, Default)]
struct Score {
    name: String,
    awake_s: f64,
    span_s: f64,
    resumes: usize,
    /// Of `resumes`, those a wait's end caused (only with `pause_waits`).
    wait_resumes: usize,
    wakes: usize,
    /// Added wait of each resume (ms) and whether its wake was an unmarked (maybe person) message.
    waits: Vec<(f64, bool)>,
}

impl Score {
    fn resumes_per_hour(&self) -> f64 {
        self.resumes as f64 / (self.span_s / 3600.0)
    }
    fn objective(&self, lambda: f64) -> f64 {
        self.awake_s + lambda * self.resumes as f64
    }
}

/// What a replay counts beyond the policy itself.
#[derive(Clone, Copy, Default)]
struct Mode {
    /// Treat a gap in which only waits ran as idle: the platform delivers the wait's end.
    pause_waits: bool,
    /// Leave out each session's tail after its last event.
    no_tail: bool,
}

fn replay(
    sessions: &[Session],
    policy: &mut dyn Policy,
    cost: &ResumeCost,
    seed: u64,
    mode: Mode,
) -> Score {
    let mut rng = Rng(seed);
    let mut sc = Score { name: policy.name(), ..Default::default() };
    for s in sessions {
        policy.reset();
        sc.awake_s += s.busy + s.held;
        sc.span_s += s.span;
        for idle in &s.idles {
            if idle.wake.is_none() && mode.no_tail {
                continue;
            }
            if idle.wait && !mode.pause_waits {
                sc.awake_s += idle.secs;
                continue;
            }
            let pending = idle.wake.is_some() && idle.secs <= PENDING_SECONDS;
            let t = policy.timeout(&Ctx { pending, last_tool: &idle.last_tool });
            if idle.wake.is_some() {
                sc.wakes += 1;
            }
            if idle.secs > t {
                sc.awake_s += t;
                if let Some(w) = idle.wake {
                    let ms = cost.draw(&mut rng);
                    sc.resumes += 1;
                    sc.awake_s += ms / 1000.0;
                    sc.waits.push((ms, w == Wake::Person));
                    if w == Wake::WaitEnd {
                        sc.wait_resumes += 1;
                    }
                }
            } else {
                sc.awake_s += idle.secs;
            }
            if !idle.wait {
                policy.observe(idle);
            }
        }
    }
    sc
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(f64::total_cmp);
    v[(((v.len() - 1) as f64) * p).round() as usize]
}

fn fmt_secs(s: f64) -> String {
    if s >= 60.0 && s % 60.0 == 0.0 { format!("{} min", s / 60.0) } else { format!("{s} s") }
}

struct Report {
    rows: Vec<Score>,
}

impl Report {
    fn table(&self, base: &Score, lambda: f64) -> String {
        let mut out = String::from(
            "| Policy | Awake h | Saved vs today, min | Saved % | Resumes per session-h | Added wait p50 / p95 ms per resume | Resumes on unmarked msgs | Resumes on a wait's end | Objective (λ) h |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|\n",
        );
        for r in &self.rows {
            let mut w: Vec<f64> = r.waits.iter().map(|x| x.0).collect();
            let unmarked = r.waits.iter().filter(|x| x.1).count();
            out += &format!(
                "| {} | {:.1} | {:.0} | {:.1}% | {:.2} | {:.0} / {:.0} | {} | {} | {:.1} |\n",
                r.name,
                r.awake_s / 3600.0,
                (base.awake_s - r.awake_s) / 60.0,
                100.0 * (base.awake_s - r.awake_s) / base.awake_s,
                r.resumes_per_hour(),
                pct(&mut w, 0.5),
                pct(&mut w, 0.95),
                unmarked,
                r.wait_resumes,
                r.objective(lambda) / 3600.0,
            );
        }
        out
    }
}

/// The static frontier's awake seconds at a given resume count (linear between grid points).
fn static_awake_at(statics: &[Score], resumes: usize) -> Option<f64> {
    let mut pts: Vec<(f64, f64)> = statics.iter().map(|s| (s.resumes as f64, s.awake_s)).collect();
    pts.sort_by(|a, b| a.0.total_cmp(&b.0));
    let r = resumes as f64;
    pts.windows(2).find(|w| w[0].0 <= r && r <= w[1].0).map(|w| {
        if w[1].0 == w[0].0 {
            w[0].1.min(w[1].1)
        } else {
            w[0].1 + (w[1].1 - w[0].1) * (r - w[0].0) / (w[1].0 - w[0].0)
        }
    })
}

fn run(sessions: &[Session], cost: &ResumeCost, lambda: f64, mode: Mode) -> String {
    let static_grid = [0.0, 2.0, 5.0, 10.0, 15.0, 30.0, 45.0, 60.0, 120.0, 300.0, 600.0, 900.0];
    let statics: Vec<Score> =
        static_grid.iter().map(|&t| replay(sessions, &mut Fixed(t), cost, 7, mode)).collect();
    let Some(base) = statics.iter().find(|s| s.name == "static 15 min").cloned() else {
        return "no static 15 min row\n".to_string();
    };

    let mut dynamics: Vec<Score> = vec![];
    for &l in &[10.0, 30.0, 120.0] {
        dynamics.push(replay(
            sessions,
            &mut Adaptive { lambda: l, window: 30, min_history: 5, cold: 60.0, hist: vec![] },
            cost,
            7,
            mode,
        ));
    }
    dynamics.push(replay(sessions, &mut TurnEnd { grace: 0.0 }, cost, 7, mode));
    dynamics.push(replay(sessions, &mut TurnEnd { grace: 2.0 }, cost, 7, mode));
    for &(l, hist) in &[(10.0, false), (30.0, false), (120.0, false), (30.0, true)] {
        let mut p = ByClass::train(sessions, l, hist);
        // Score each fold with the table learned on the other.
        let mut sc = Score::default();
        for fold in 0..2 {
            p.fold = fold;
            let part: Vec<Session> =
                sessions.iter().filter(|s| fold_of(&s.id) == fold).cloned().collect();
            let r = replay(&part, &mut p, cost, 7 + fold as u64, mode);
            sc.name = r.name;
            sc.awake_s += r.awake_s;
            sc.span_s += r.span_s;
            sc.resumes += r.resumes;
            sc.wait_resumes += r.wait_resumes;
            sc.wakes += r.wakes;
            sc.waits.extend(r.waits);
        }
        dynamics.push(sc);
    }

    let mut out = String::new();
    let busy: f64 = sessions.iter().map(|s| s.busy).sum();
    let held: f64 = sessions.iter().map(|s| s.held).sum();
    let waits: f64 = sessions.iter().map(|s| s.waits).sum();
    let gaps = || sessions.iter().flat_map(|s| &s.idles).filter(|i| !i.wait);
    let idle: f64 = gaps().filter(|i| i.wake.is_some()).map(|i| i.secs).sum();
    let tail: f64 = gaps().filter(|i| i.wake.is_none()).map(|i| i.secs).sum();
    let wakes = gaps().filter(|i| i.wake.is_some()).count();
    out += &format!(
        "sessions {} (top-level {}), span {:.1} h: busy {:.1} h, held by a background task that computes {:.1} h, only waits running {:.1} h, idle between turns {:.1} h over {} wakes; tails after the last event {:.1} h{}{}\n\n",
        sessions.len(),
        sessions.iter().filter(|s| s.main).count(),
        sessions.iter().map(|s| s.span).sum::<f64>() / 3600.0,
        busy / 3600.0,
        held / 3600.0,
        waits / 3600.0,
        idle / 3600.0,
        wakes,
        tail / 3600.0,
        if mode.no_tail { " (left out)" } else { "" },
        if mode.pause_waits { "; waits pause (the platform delivers their end)" } else { "" },
    );
    let report = Report { rows: statics.iter().chain(dynamics.iter()).cloned().collect() };
    out += &report.table(&base, lambda);
    let by_objective = |a: &&Score, b: &&Score| a.objective(lambda).total_cmp(&b.objective(lambda));
    let (Some(sbest), Some(dbest)) =
        (statics.iter().min_by(by_objective), dynamics.iter().min_by(by_objective))
    else {
        return out;
    };
    out += &format!(
        "\nobjective λ={}: static best `{}` {:.1} h; dynamic best `{}` {:.1} h; gap {:.1} h ({:.1}% of static best)\n",
        fmt_secs(lambda),
        sbest.name,
        sbest.objective(lambda) / 3600.0,
        dbest.name,
        dbest.objective(lambda) / 3600.0,
        (sbest.objective(lambda) - dbest.objective(lambda)) / 3600.0,
        100.0 * (sbest.objective(lambda) - dbest.objective(lambda)) / sbest.objective(lambda),
    );
    out += "\nAt equal resumes (static frontier interpolated at each dynamic policy's resume count):\n";
    for d in &dynamics {
        match static_awake_at(&statics, d.resumes) {
            Some(s) => {
                out += &format!(
                    "- {}: {} resumes; static at that count {:.1} h awake, dynamic {:.1} h: {:+.0} min\n",
                    d.name,
                    d.resumes,
                    s / 3600.0,
                    d.awake_s / 3600.0,
                    (s - d.awake_s) / 60.0
                )
            }
            None => {
                out +=
                    &format!("- {}: {} resumes, outside the static frontier\n", d.name, d.resumes)
            }
        }
    }
    out
}

const USAGE: &str = "usage: pause-replay TIMELINES.json [--lambda SECONDS] [--only main|sub] [--pause-waits] [--no-tail]";

fn main() -> std::process::ExitCode {
    match real_main() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("pause-replay: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn real_main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or(USAGE)?;
    let mut lambda = 30.0;
    let mut only: Option<String> = None;
    let mut mode = Mode::default();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--pause-waits" => mode.pause_waits = true,
            "--no-tail" => mode.no_tail = true,
            "--lambda" => {
                lambda = args.next().and_then(|v| v.parse().ok()).ok_or("--lambda SECONDS")?
            }
            "--only" => only = args.next(),
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("read {path}: {e}"))?;
    let input: Input = serde_json::from_slice(&bytes).map_err(|e| format!("parse {path}: {e}"))?;
    let sessions: Vec<Session> = input
        .sessions
        .iter()
        .filter(|s| only.as_deref().is_none_or(|k| s.kind == k))
        .map(build)
        .collect();
    let costs = [
        (
            "split drill 1a step 5 (start call + request to first byte, n=20): p50 662 ms, p95 834 ms",
            ResumeCost::LogNormal { p50: 662.0, p95: 834.0 },
        ),
        (
            "resume matrix hq#21300 platform arm, run 45177970049 (answered, n=3): 1531, 1992, 2195 ms",
            ResumeCost::Samples(vec![1531.0, 1992.0, 2195.0]),
        ),
    ];
    for (label, cost) in &costs {
        println!("## Resume cost: {label}\n");
        println!("{}", run(&sessions, cost, lambda, mode));
    }
    Ok(())
}

#[cfg(test)]
#[path = "pause_replay/tests.rs"]
mod tests;
