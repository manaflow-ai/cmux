//! The daemon's runtime that stops running tasks names what it is stuck on, before anything
//! replaces it.
//!
//! On 2026-11-27 Leo's daemon wrote nothing for 20 minutes (15:12:30 to 15:32:37Z) and then
//! logged "this machine did not run for 20m 6s ... kind=stopped" (`hub/resume.rs`). The Mac was
//! awake (its display stayed on, `pmset -g log`), nothing sent the daemon SIGSTOP
//! (`killed-by-agents.log`, `mac_mem_backstop`), and none of the instrumented locks logged a long
//! hold (`hub/held_lock.rs` logs only when a hold ends). So the runtime itself ran no task:
//! a chat's finished turn and Leo's steers sat in it, and the chat read "Thinking" for 20
//! minutes. Leo: "mango has been "thinking" for an inordinate amount of time. i think they're
//! bugged and we need to fix this bug". Nothing recorded what the workers were blocked on, and
//! the waiter that now replaces a silent holder (`hung_holder.rs`, 15 s) ends the evidence too.
//!
//! This is the recorder. A task on the runtime stores a beat every [`BEAT_EVERY`]; a plain OS
//! thread, off the runtime, checks it every [`CHECK_EVERY`]. A beat older than [`STALL`] (well
//! under `hung_holder::SERVING_STALL`) is a stalled runtime: one WARN line with how long and the
//! runtime's counts, and the stacks of every thread written to `$ACPMUX_HOME/stalls/` (macOS:
//! `/usr/bin/sample`; Linux: each thread's state, wait channel and syscall from `/proc`). A stall
//! that goes on is captured again at [`SECOND_CAPTURE`], so two captures show whether the
//! threads moved. When the beat comes back, one WARN line says for how long it stopped.
//! When this thread's own sleep came back late as well, the whole process or machine did not run
//! (a sleep, a pause, SIGSTOP): that is `resume.rs`'s gap, not a stalled runtime, and it is not
//! captured. Captures are bounded: [`MAX_CAPTURES_PER_HOUR`], the newest [`KEEP`] files kept.
//!
//! A diagnostic only: it never stops, restarts or signals the daemon.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How often the runtime's task beats.
pub(crate) const BEAT_EVERY: Duration = Duration::from_millis(500);
/// How often the OS thread looks at the beat.
pub(crate) const CHECK_EVERY: Duration = Duration::from_secs(1);
/// A beat this old is a stalled runtime. At load 60 a runnable worker waits tens to hundreds of
/// milliseconds for a core (`hung_holder.rs`), so 5 s is a runtime that runs nothing, and it
/// is a third of the 15 s after which a waiter replaces the daemon: the stacks come first.
// timeout: the stall's threshold, no event to wait for; when passed it logs and captures stacks
pub(crate) const STALL: Duration = Duration::from_secs(5);
/// A stall still going at this age is captured a second time.
// timeout: the second capture's age, no event to wait for; when passed it captures again
pub(crate) const SECOND_CAPTURE: Duration = Duration::from_secs(60);
/// The most captures in one hour, whatever the stalls: a runtime that stalls every minute
/// writes a few files, not hundreds.
pub(crate) const MAX_CAPTURES_PER_HOUR: usize = 6;
/// The newest capture files kept in `stalls/`.
pub(crate) const KEEP: usize = 20;
/// The most one capture may take: `sample` runs for 2 s; a capture past this is ended.
// timeout: bound on one stack capture; when passed the capture is killed and the line says so
#[cfg(target_os = "macos")]
const CAPTURE_BOUND: Duration = Duration::from_secs(20);

/// What one check decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Step {
    /// The runtime beats.
    Fine,
    /// The runtime ran no task for `silent`; `capture` says whether to take stacks now.
    Stalled { silent: Duration, capture: bool, first: bool },
    /// The runtime beats again after a stall of about `stopped`.
    Recovered { stopped: Duration },
    /// This thread itself did not run for `gap`: the process or machine stopped, not the runtime.
    ProcessLate { gap: Duration },
}

/// The check's state: sans I/O, so a test feeds times instead of stalling a runtime.
#[derive(Debug, Default)]
pub(crate) struct Watch {
    /// The beat's age when the stall was first seen, and when (watch time).
    stall: Option<Stall>,
    /// When captures were taken (watch time), the last hour's.
    captures: Vec<Duration>,
}

#[derive(Debug, Clone, Copy)]
struct Stall {
    /// The beat that went stale (watch time).
    beat: Duration,
    /// Captures taken for this stall.
    taken: u8,
}

impl Watch {
    /// One check at `now` (time since the watch's origin): the newest beat at `beat` on the same
    /// clock, and how late this thread's own sleep came back.
    pub(crate) fn check(&mut self, now: Duration, beat: Duration, own_late: Duration) -> Step {
        let silent = now.saturating_sub(beat);
        if own_late >= STALL {
            // The thread did not run either: whatever silence the beat shows, the runtime had no
            // chance to run. A stall seen before is over (the process ran again), unnamed.
            self.stall = None;
            return Step::ProcessLate { gap: own_late };
        }
        if silent < STALL {
            return match self.stall.take() {
                Some(stall) => Step::Recovered { stopped: beat.saturating_sub(stall.beat) },
                None => Step::Fine,
            };
        }
        let first = self.stall.is_none();
        let stall = self.stall.get_or_insert(Stall { beat, taken: 0 });
        let due = match stall.taken {
            0 => true,
            1 => silent >= SECOND_CAPTURE,
            _ => false,
        };
        self.captures.retain(|&at| now.saturating_sub(at) < Duration::from_secs(3600));
        let capture = due && self.captures.len() < MAX_CAPTURES_PER_HOUR;
        if due {
            // A capture refused by the hourly bound still counts as this stall's: no retry each second.
            stall.taken += 1;
        }
        if capture {
            self.captures.push(now);
        }
        // One line when it starts and one per capture; the rest of a long stall is quiet.
        if first || capture { Step::Stalled { silent, capture, first } } else { Step::Fine }
    }
}

/// The watch's clock origin, shared by the beat and the check.
fn origin() -> Instant {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    *ORIGIN.get_or_init(Instant::now)
}

/// The newest beat, in ms since [`origin`].
static BEAT_MS: AtomicU64 = AtomicU64::new(0);

fn stamp() {
    let ms = u64::try_from(origin().elapsed().as_millis()).unwrap_or(u64::MAX);
    BEAT_MS.store(ms, Ordering::Relaxed);
}

/// Starts the beat on the current runtime and the watch thread. Called once from the daemon's
/// start, inside its runtime.
pub(crate) fn start() {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    stamp();
    runtime.spawn(async {
        let mut every = tokio::time::interval(BEAT_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            stamp();
        }
    });
    let dir = crate::config::home().join("stalls");
    let spawned = std::thread::Builder::new()
        .name("acpmux-stall-watch".into())
        .spawn(move || watch(runtime, dir));
    if let Err(error) = spawned {
        tracing::warn!(%error, "cannot start the runtime stall watch; a stall will not be recorded");
    }
}

fn watch(runtime: tokio::runtime::Handle, dir: PathBuf) {
    let mut state = Watch::default();
    let mut last = Instant::now();
    loop {
        std::thread::sleep(CHECK_EVERY);
        let woke = Instant::now();
        let own_late = woke.saturating_duration_since(last).saturating_sub(CHECK_EVERY);
        last = woke;
        let now = origin().elapsed();
        let beat = Duration::from_millis(BEAT_MS.load(Ordering::Relaxed));
        match state.check(now, beat, own_late) {
            Step::Fine => {}
            Step::ProcessLate { gap } => {
                tracing::info!(
                    gap_ms = gap.as_millis() as u64,
                    "stall watch: this whole process did not run (a sleep, pause or stop), not a stalled runtime"
                );
            }
            Step::Recovered { stopped } => {
                tracing::warn!(
                    stopped_ms = stopped.as_millis() as u64,
                    "the daemon's runtime runs tasks again after a stall"
                );
            }
            Step::Stalled { silent, capture, first } => {
                let counts = counts(&runtime);
                let file = capture.then(|| capture_stacks(&dir)).flatten();
                tracing::warn!(
                    silent_ms = silent.as_millis() as u64,
                    first,
                    %counts,
                    stacks = file.as_ref().map(|f| f.display().to_string()).unwrap_or_else(|| "none".into()),
                    "the daemon's runtime has run no task: every worker is blocked or busy"
                );
            }
        }
    }
}

/// The runtime's counts a stuck runtime can still be read for, from any thread.
fn counts(runtime: &tokio::runtime::Handle) -> String {
    let metrics = runtime.metrics();
    format!(
        "workers={} alive_tasks={} global_queue={}",
        metrics.num_workers(),
        metrics.num_alive_tasks(),
        metrics.global_queue_depth()
    )
}

/// Writes every thread's stack (or state, where stacks cannot be read) to a new file in `dir`,
/// prunes the old ones, and returns the file; None when nothing could be written.
fn capture_stacks(dir: &Path) -> Option<PathBuf> {
    std::fs::create_dir_all(dir).ok()?;
    let stamp = chrono_like_stamp();
    let file = dir.join(format!("stall-{stamp}-{}.txt", std::process::id()));
    let written = write_stacks(&file);
    prune(dir, KEEP);
    match written {
        Ok(()) => Some(file),
        Err(error) => {
            tracing::warn!(%error, file = %file.display(), "stall watch: could not capture the stacks");
            None
        }
    }
}

/// UTC wall time as `YYYYMMDDTHHMMSSZ`, for file names that sort by time.
fn chrono_like_stamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (days, rem) = (secs / 86_400, secs % 86_400);
    let (y, m, d) = civil_from_days(days as i64);
    format!("{y:04}{m:02}{d:02}T{:02}{:02}{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
pub(crate) fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// Keeps the newest `keep` `stall-*.txt` files in `dir`.
pub(crate) fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("stall-") && n.ends_with(".txt"))
        })
        .collect();
    // The names start with the UTC time: by name is by age.
    files.sort();
    let extra = files.len().saturating_sub(keep);
    for old in files.into_iter().take(extra) {
        let _ = std::fs::remove_file(old);
    }
}

/// macOS: `sample` of this process for 2 s, every thread's stack with its counts.
#[cfg(target_os = "macos")]
fn write_stacks(file: &Path) -> std::io::Result<()> {
    let mut child = std::process::Command::new("/usr/bin/sample")
        .arg(std::process::id().to_string())
        .args(["2", "10", "-mayDie", "-file"])
        .arg(file)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + CAPTURE_BOUND;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait()? {
            if status.success() {
                return Ok(());
            }
            let mut err = String::new();
            if let Some(mut stderr) = child.stderr.take() {
                let _ = std::io::Read::read_to_string(&mut stderr, &mut err);
            }
            return Err(std::io::Error::other(format!("sample exited {status}: {}", err.trim())));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(std::io::Error::other(format!(
        "sample ran past {} s and was ended",
        CAPTURE_BOUND.as_secs()
    )))
}

/// Linux: each thread's name, state, wait channel and current syscall from `/proc/self/task`
/// (no ptrace, no root): enough to tell a lock wait (futex) from disk or network I/O.
#[cfg(target_os = "linux")]
fn write_stacks(file: &Path) -> std::io::Result<()> {
    let mut out = String::new();
    for entry in std::fs::read_dir("/proc/self/task")? {
        let task = entry?.path();
        let read = |name: &str| std::fs::read_to_string(task.join(name)).unwrap_or_default();
        let stat = read("stat");
        // The state is the field after the parenthesized name.
        let state = stat
            .rsplit_once(") ")
            .map(|(_, rest)| rest.chars().next().unwrap_or('?'))
            .unwrap_or('?');
        out.push_str(&format!(
            "tid={} comm={} state={} wchan={} syscall={}\n",
            task.file_name().and_then(|n| n.to_str()).unwrap_or("?"),
            read("comm").trim(),
            state,
            read("wchan").trim(),
            read("syscall").trim(),
        ));
        let stack = read("stack");
        if !stack.is_empty() {
            out.push_str(&stack);
        }
    }
    std::fs::write(file, out)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn write_stacks(_file: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("no stack capture on this OS"))
}

#[cfg(test)]
#[path = "runtime_stall_tests.rs"]
mod tests;
