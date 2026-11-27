//! The dynamic CPU class (`dynamic`, opt-in): a session's harness and every process it
//! started yield to the GUI only while the Mac is actually contended, and get their CPU back
//! within seconds once it is not (Leo, 2026-11-25: "lucas ran into slow stuff on the desktop gui
//! app with claude bc he was at relatively high cpu and agents' tool calls ran at background
//! priority and stuff so it took like 87 minutes to do things... and then even when his cpu went
//! down to 80% the background priority stayed... we ought to have more dynamic stuff").
//!
//! - [`Sampler`] reads the contention about every [`TICK`] on its own thread, and only while
//!   some live session is `dynamic` ([`Sampler::want`]); otherwise the thread waits and wakes
//!   nothing (its bursts woke an idle daemon about 12 times a second): how late a
//!   user-interactive thread wakes from a 10 ms sleep (the GUI's main thread runs at that QoS, so
//!   this is what its frames see; the p90 of a 200 ms burst) and the share of all CPUs busy
//!   (`host_statistics64` HOST_CPU_LOAD_INFO). The app's own frame times do not reach the daemon,
//!   so the interactive thread's lateness stands in for them. macOS only: Linux sessions get
//!   their share from their cgroup's `CPUWeight` (`session_scope.rs`), elsewhere nothing reads.
//! - [`Controller`] turns samples into one decision, with hysteresis: it demotes after
//!   [`DEMOTE_AFTER`] pressured samples in a row (busy at least [`DEMOTE_BUSY`] and the
//!   interactive thread [`DEMOTE_LATE_MS`] late) and promotes after [`PROMOTE_AFTER`] clear ones
//!   (busy under [`CLEAR_BUSY`] or lateness under [`CLEAR_LATE_MS`]). A demotion soon after a
//!   promotion ([`FLAP_WINDOW_MS`]: the agents were the load) doubles the clear samples the next
//!   promotion needs, up to [`PROMOTE_AFTER_MAX`]; a demotion after a calm spell starts at
//!   [`PROMOTE_AFTER`] again. No reading demotes nothing, and nothing stays demoted on a stale one.
//! - [`wants_background`] decides per session: a turn the person waits on (their prompt in a chat
//!   they have open and attend, before its first token or tool result) never yields.
//! - [`Demotion`] keeps each harness's spells, for `acpmux session info` (`cpuClass`) and the
//!   daemon log.

use serde::Serialize;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::Duration;

/// How often the controller decides.
pub const TICK: Duration = Duration::from_secs(1);
/// Busy share at or past which a late interactive thread counts as pressure.
pub const DEMOTE_BUSY: f64 = 0.90;
/// Interactive-thread lateness (p90, ms) at or past which a busy host counts as pressure: an idle
/// Mac wakes it about 0.1 ms late, a saturated one 1.6 ms at the median (RFD 0072).
pub const DEMOTE_LATE_MS: f64 = 2.0;
/// Busy share under which the host is clear, however late the thread woke (Lucas's Mac at 80%).
pub const CLEAR_BUSY: f64 = 0.85;
/// Lateness under which the host is clear, however busy: the GUI meets its deadlines.
pub const CLEAR_LATE_MS: f64 = 0.5;
/// Pressured samples in a row before agents yield.
pub const DEMOTE_AFTER: u32 = 3;
/// Clear samples in a row before they get their CPU back.
pub const PROMOTE_AFTER: u32 = 3;
/// The most clear samples a promotion ever needs (the flap backoff's cap).
pub const PROMOTE_AFTER_MAX: u32 = 30;
/// A demotion this soon after a promotion is a flap: the agents themselves were the pressure.
pub const FLAP_WINDOW_MS: u64 = 30_000;
/// A sample older than this is no reading.
pub const STALE_MS: u64 = 5_000;

/// One reading of contention.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    /// The share of all CPUs busy since the last sample (0..1).
    pub busy: f64,
    /// How late a user-interactive thread woke from a 10 ms sleep, the p90 of one burst (ms).
    pub late_ms: f64,
}

impl Sample {
    /// The interactive app misses deadlines now.
    pub fn pressured(&self) -> bool {
        self.busy >= DEMOTE_BUSY && self.late_ms >= DEMOTE_LATE_MS
    }

    /// Nothing interactive waits on the CPU now.
    pub fn clear(&self) -> bool {
        self.busy < CLEAR_BUSY || self.late_ms < CLEAR_LATE_MS
    }
}

/// The one decision for every `dynamic` session: whether agents yield now (module docs).
#[derive(Debug, Clone, Default)]
pub struct Controller {
    demoting: bool,
    pressured_run: u32,
    clear_run: u32,
    /// Clear samples the current demotion needs before it ends (0: [`PROMOTE_AFTER`]).
    promote_after: u32,
    last_promoted_ms: Option<u64>,
    last: Option<Sample>,
}

impl Controller {
    /// Takes one sample (`None`: nothing read) at `now_ms` on a monotonic clock; true while
    /// agents yield.
    pub fn observe(&mut self, sample: Option<Sample>, now_ms: u64) -> bool {
        self.last = sample;
        let Some(sample) = sample else {
            // Never hold agents down on a guess.
            if self.demoting {
                self.promote(now_ms);
            }
            self.pressured_run = 0;
            return false;
        };
        if self.demoting {
            self.clear_run = if sample.clear() { self.clear_run + 1 } else { 0 };
            if self.clear_run >= self.needed() {
                self.promote(now_ms);
            }
        } else {
            self.pressured_run = if sample.pressured() { self.pressured_run + 1 } else { 0 };
            if self.pressured_run >= DEMOTE_AFTER {
                let flapped = self
                    .last_promoted_ms
                    .is_some_and(|p| now_ms.saturating_sub(p) < FLAP_WINDOW_MS);
                self.promote_after = if flapped {
                    self.needed().saturating_mul(2).min(PROMOTE_AFTER_MAX)
                } else {
                    PROMOTE_AFTER
                };
                self.demoting = true;
                self.pressured_run = 0;
                self.clear_run = 0;
            }
        }
        self.demoting
    }

    fn promote(&mut self, now_ms: u64) {
        self.demoting = false;
        self.clear_run = 0;
        self.last_promoted_ms = Some(now_ms);
    }

    /// Clear samples in a row the current demotion needs before it ends.
    pub fn needed(&self) -> u32 {
        if self.promote_after == 0 { PROMOTE_AFTER } else { self.promote_after }
    }

    pub fn demoting(&self) -> bool {
        self.demoting
    }

    /// What `session info` says of the host: the decision and the last sample.
    pub fn view(&self) -> Value {
        json!({
            "yielding": self.demoting,
            "busy": self.last.map(|s| (s.busy * 1000.0).round() / 1000.0),
            "lateMs": self.last.map(|s| (s.late_ms * 100.0).round() / 100.0),
            "promoteAfter": self.needed(),
        })
    }
}

/// Whether a session of `class` runs in background class now, given the controller's decision
/// and whether the person waits on its turn. `normal` never; `background` (asked for by name)
/// always, as before; `dynamic` while the host is contended, unless the person waits on it.
pub fn wants_background(class: super::CpuClass, demoting: bool, waited_on: bool) -> bool {
    match class {
        super::CpuClass::Normal => false,
        super::CpuClass::Background => true,
        super::CpuClass::Dynamic => demoting && !waited_on,
    }
}

/// One harness's demotion record: in background class now or not, and the time spent there.
#[derive(Debug, Default)]
pub struct Demotion {
    background: AtomicBool,
    /// When the current spell began (monotonic ms + 1; 0: none).
    since: AtomicU64,
    total_ms: AtomicU64,
    spells: AtomicU32,
    /// A promotion clears the tree once more on the next tick: a process forked from a still
    /// background one while the first clear walked the tree inherited the class.
    recheck: AtomicBool,
}

impl Demotion {
    pub fn is_background(&self) -> bool {
        self.background.load(Ordering::SeqCst)
    }

    /// Records the class it is now in; true when that changed.
    pub fn mark(&self, on: bool, now_ms: u64) -> bool {
        if self.background.swap(on, Ordering::SeqCst) == on {
            return false;
        }
        if on {
            self.since.store(now_ms + 1, Ordering::SeqCst);
            self.spells.fetch_add(1, Ordering::SeqCst);
        } else {
            let since = self.since.swap(0, Ordering::SeqCst);
            if since > 0 {
                self.total_ms.fetch_add(now_ms.saturating_sub(since - 1), Ordering::SeqCst);
            }
            self.recheck.store(true, Ordering::SeqCst);
        }
        true
    }

    /// Takes the one extra clear a promotion asked for.
    pub fn take_recheck(&self) -> bool {
        self.recheck.swap(false, Ordering::SeqCst)
    }

    /// Milliseconds spent in background class, the current spell included.
    pub fn demoted_ms(&self, now_ms: u64) -> u64 {
        let since = self.since.load(Ordering::SeqCst);
        let open = if since > 0 { now_ms.saturating_sub(since - 1) } else { 0 };
        self.total_ms.load(Ordering::SeqCst) + open
    }

    pub fn spells(&self) -> u32 {
        self.spells.load(Ordering::SeqCst)
    }

    /// `session info`'s `cpuClass`: the class asked for, the one it runs at now, the time spent
    /// demoted and in how many spells.
    pub fn view(&self, class: super::CpuClass, now_ms: u64) -> Value {
        let now = if self.is_background() { "background" } else { "normal" };
        let since = self.since.load(Ordering::SeqCst);
        json!({
            "class": class.name(),
            "now": now,
            "demotedMs": self.demoted_ms(now_ms),
            "demotions": self.spells(),
            "demotedForMs": (since > 0).then(|| now_ms.saturating_sub(since - 1)),
        })
    }
}

/// Milliseconds on a monotonic clock that starts at the first call.
pub fn mono_ms() -> u64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64
}

/// The share busy between two `host_cpu_load_info` readings `[user, system, idle, nice]` (the
/// counters are 32-bit and wrap); None when no tick passed.
pub fn busy_between(before: [u32; 4], after: [u32; 4]) -> Option<f64> {
    let d: Vec<u64> =
        before.iter().zip(&after).map(|(b, a)| u64::from(a.wrapping_sub(*b))).collect();
    let total: u64 = d.iter().sum();
    (total > 0).then(|| (total - d[2]) as f64 / total as f64)
}

/// The process's one sampler thread and its last sample.
pub struct Sampler;

static LAST: std::sync::Mutex<Option<(Sample, u64)>> = std::sync::Mutex::new(None);
/// Whether some live session is `dynamic`, so the thread samples; its condvar wakes the thread.
static WANTED: std::sync::Mutex<bool> = std::sync::Mutex::new(false);
static WANTED_CHANGED: std::sync::Condvar = std::sync::Condvar::new();

impl Sampler {
    /// Starts the thread once (macOS; elsewhere nothing reads, and no thread starts). False
    /// when there is nothing to sample here.
    pub fn start() -> bool {
        static STARTED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        *STARTED.get_or_init(|| {
            if !cfg!(target_os = "macos") {
                return false;
            }
            std::thread::Builder::new().name("acpmux-cpu-pressure".into()).spawn(imp::run).is_ok()
        })
    }

    /// Samples while `on`; otherwise the thread waits after its current burst, with no timer.
    pub fn want(on: bool) {
        let mut wanted = WANTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *wanted != on {
            *wanted = on;
            WANTED_CHANGED.notify_all();
        }
    }

    pub fn wanted() -> bool {
        *WANTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Blocks the sampler thread until it is wanted.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn wait_until_wanted() {
        let wanted = WANTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _wanted = WANTED_CHANGED
            .wait_while(wanted, |on| !*on)
            .unwrap_or_else(std::sync::PoisonError::into_inner);
    }

    /// The last sample, None when there is none or it is older than [`STALE_MS`].
    pub fn read() -> Option<Sample> {
        let last = *LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        last.filter(|(_, at)| mono_ms().saturating_sub(*at) <= STALE_MS).map(|(s, _)| s)
    }

    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn publish(sample: Sample) {
        *LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((sample, mono_ms()));
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{Sample, Sampler, busy_between};
    use std::time::{Duration, Instant};

    /// One burst of 10 ms sleeps per tick: 20 wakes, about 2% of one thread's time.
    const SLEEP: Duration = Duration::from_millis(10);
    const BURST: Duration = Duration::from_millis(200);

    fn host_ticks() -> Option<[u32; 4]> {
        static HOST: std::sync::OnceLock<libc::mach_port_t> = std::sync::OnceLock::new();
        // SAFETY: no arguments; returns this host's name port.
        #[allow(deprecated)]
        let host = *HOST.get_or_init(|| unsafe { libc::mach_host_self() });
        // SAFETY: an all-zero host_cpu_load_info is a valid value of this plain C struct.
        let mut info: libc::host_cpu_load_info = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        // SAFETY: `info` is HOST_CPU_LOAD_INFO_COUNT integers of writable storage, as `count` says.
        let rc = unsafe {
            libc::host_statistics64(
                host,
                libc::HOST_CPU_LOAD_INFO,
                (&raw mut info).cast(),
                &raw mut count,
            )
        };
        (rc == libc::KERN_SUCCESS).then_some(info.cpu_ticks)
    }

    pub(super) fn run() {
        // SAFETY: sets this thread's own QoS class; no pointers.
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
        }
        let mut before = None;
        loop {
            if !Sampler::wanted() {
                // A busy share read across the wait would describe the wait, not now.
                Sampler::wait_until_wanted();
                before = None;
            }
            if before.is_none() {
                before = host_ticks();
            }
            let start = Instant::now();
            let mut late = Vec::with_capacity(24);
            while start.elapsed() < BURST {
                let t = Instant::now();
                std::thread::sleep(SLEEP);
                late.push(t.elapsed().saturating_sub(SLEEP).as_secs_f64() * 1000.0);
            }
            if let Some(rest) = super::TICK.checked_sub(start.elapsed()) {
                std::thread::sleep(rest);
            }
            let after = host_ticks();
            late.sort_by(f64::total_cmp);
            let p90 = late.get((late.len() * 9).div_ceil(10).saturating_sub(1)).copied();
            if let (Some(b), Some(a), Some(late_ms)) = (before, after, p90)
                && let Some(busy) = busy_between(b, a)
            {
                Sampler::publish(Sample { busy, late_ms });
            }
            before = after;
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub(super) fn run() {}
}
