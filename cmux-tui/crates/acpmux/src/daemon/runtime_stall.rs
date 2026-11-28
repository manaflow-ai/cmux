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
//! On 2026-11-28 a Linux daemon stalled 74 times in eight hours, and the captures could not say
//! what held it. The blocking pool's threads carry the workers' name (`tokio-rt-worker`), so
//! "53 runtime threads in fsync" was read as 53 of 32 workers blocked, when most were the pool's
//! (which is where blocking I/O belongs) and, in most captures, every worker was parked and one
//! ran user code. And each syscall's fd was a number in a process that no longer existed. So a
//! capture marks the workers ([`mark_worker`], from the runtime's park hook: only a worker
//! parks), names the file behind each fd-taking syscall (`/proc/self/fd`), and opens with a
//! summary of what the workers do. The first capture of each daemon is kept beside the newest
//! [`KEEP`] (a run of restarts had pruned the start of every stall that mattered), and the
//! capture's own time is not read as the process not running: all 17 "this whole process did not
//! run" lines that day came right after a capture that took 5 to 87 s on the slow disk.
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
/// Each daemon's first capture is kept too, for this many of the newest daemons.
pub(crate) const KEEP_FIRSTS: usize = 20;
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
    drive(
        None,
        std::thread::sleep,
        || origin().elapsed(),
        || Duration::from_millis(BEAT_MS.load(Ordering::Relaxed)),
        |step| act(&runtime, &dir, step),
    );
}

/// The watch's loop, its clock and actions passed in so a test can run it: sleep, check, act. The
/// next sleep's lateness counts from when the action ended, so a capture slow on a slow disk is
/// this thread's own work, not the process not running. `rounds` bounds it for a test.
pub(crate) fn drive(
    rounds: Option<usize>,
    mut sleep: impl FnMut(Duration),
    mut now: impl FnMut() -> Duration,
    mut beat: impl FnMut() -> Duration,
    mut act: impl FnMut(Step),
) {
    let mut state = Watch::default();
    let mut last = now();
    let mut done = 0;
    while rounds.is_none_or(|r| done < r) {
        done += 1;
        sleep(CHECK_EVERY);
        let woke = now();
        let own_late = woke.saturating_sub(last).saturating_sub(CHECK_EVERY);
        act(state.check(woke, beat(), own_late));
        last = now();
    }
}

fn act(runtime: &tokio::runtime::Handle, dir: &Path, step: Step) {
    match step {
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
            let counts = counts(runtime);
            let started = Instant::now();
            let file = capture.then(|| capture_stacks(dir)).flatten();
            tracing::warn!(
                silent_ms = silent.as_millis() as u64,
                first,
                %counts,
                capture_ms = started.elapsed().as_millis() as u64,
                stacks = file.as_ref().map(|f| f.display().to_string()).unwrap_or_else(|| "none".into()),
                "the daemon's runtime has run no task: every worker is blocked or busy"
            );
        }
    }
}

/// The thread ids of the runtime's workers, as they first park.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
static WORKERS: std::sync::Mutex<Vec<i64>> = std::sync::Mutex::new(Vec::new());

/// The runtime's park hook (`cli/entry.rs`): records this thread as a worker, once. The blocking
/// pool's threads never park through it, so a capture tells the two apart.
pub(crate) fn mark_worker() {
    thread_local! {
        static MARKED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    if MARKED.with(|m| m.replace(true)) {
        return;
    }
    if let Some(tid) = this_tid() {
        WORKERS.lock().unwrap_or_else(|e| e.into_inner()).push(tid);
    }
}

#[cfg(target_os = "linux")]
fn this_tid() -> Option<i64> {
    // SAFETY: gettid takes no arguments and cannot fail.
    Some(unsafe { libc::syscall(libc::SYS_gettid) } as i64)
}

#[cfg(not(target_os = "linux"))]
fn this_tid() -> Option<i64> {
    None
}

#[cfg(target_os = "linux")]
fn workers() -> Vec<i64> {
    WORKERS.lock().unwrap_or_else(|e| e.into_inner()).clone()
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

/// Keeps the newest `keep` `stall-*.txt` files in `dir`, and the first file of each of the newest
/// [`KEEP_FIRSTS`] daemons (the pid ends the name): a daemon restarted again and again would
/// otherwise prune the start of its own stall.
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
    let mut firsts: Vec<&PathBuf> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for file in &files {
        if seen.insert(capture_pid(file)) {
            firsts.push(file);
        }
    }
    let firsts: std::collections::HashSet<&PathBuf> =
        firsts.iter().rev().take(KEEP_FIRSTS).copied().collect();
    let extra = files.len().saturating_sub(keep);
    for old in files.iter().take(extra).filter(|f| !firsts.contains(f)) {
        let _ = std::fs::remove_file(old);
    }
}

/// The pid a capture's name ends with (`stall-<stamp>-<pid>.txt`).
fn capture_pid(file: &Path) -> String {
    file.file_stem()
        .and_then(|n| n.to_str())
        .and_then(|n| n.rsplit_once('-'))
        .map(|(_, pid)| pid.to_string())
        .unwrap_or_default()
}

/// macOS: `sample` of this process for 2 s, every thread's stack with its counts.
#[cfg(target_os = "macos")]
fn write_stacks(file: &Path) -> std::io::Result<()> {
    // cmux-process (cmuxterm-hq#9096): the sampler ends with this handle if the capture returns early.
    let mut child = cmux_process::Command::new("/usr/bin/sample")
        .arg(std::process::id().to_string())
        .args(["2", "10", "-mayDie", "-file"])
        .arg(file)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::piped())
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
/// (no ptrace, no root): enough to tell a lock wait (futex) from disk or network I/O. Workers are
/// marked `role=worker`; a syscall that takes an fd names its file (`fd=...`). A summary of the
/// workers and of the files threads wait on comes first.
#[cfg(target_os = "linux")]
fn write_stacks(file: &Path) -> std::io::Result<()> {
    let workers = workers();
    let mut lines = Vec::new();
    let mut summary = Summary::default();
    for entry in std::fs::read_dir("/proc/self/task")? {
        let task = entry?.path();
        let read = |name: &str| std::fs::read_to_string(task.join(name)).unwrap_or_default();
        let tid = task.file_name().and_then(|n| n.to_str()).unwrap_or("?").to_string();
        let stat = read("stat");
        // The state is the field after the parenthesized name.
        let state = stat
            .rsplit_once(") ")
            .map(|(_, rest)| rest.chars().next().unwrap_or('?'))
            .unwrap_or('?');
        let syscall = read("syscall").trim().to_string();
        let wchan = read("wchan").trim().to_string();
        let worker = tid.parse::<i64>().is_ok_and(|t| workers.contains(&t));
        let blocked = blocked_on(&syscall);
        let fd = blocked.and_then(|b| b.fd).and_then(|fd| {
            std::fs::read_link(format!("/proc/self/fd/{fd}")).ok().map(|p| p.display().to_string())
        });
        summary.add(worker, state, &wchan, blocked.map(|b| b.name), fd.as_deref());
        let mut line = format!(
            "tid={tid} comm={} state={state} wchan={wchan} syscall={syscall}",
            read("comm").trim()
        );
        if worker {
            line.push_str(" role=worker");
        }
        if let Some(b) = blocked {
            line.push_str(&format!(" call={}", b.name));
        }
        if let Some(fd) = &fd {
            line.push_str(&format!(" fd={fd}"));
        }
        line.push('\n');
        let stack = read("stack");
        if !stack.is_empty() {
            line.push_str(&stack);
        }
        lines.push(line);
    }
    let mut out = summary.render(workers.len());
    for line in lines {
        out.push_str(&line);
    }
    std::fs::write(file, out)
}

/// What a capture's first lines say: the workers' states, and the files threads wait on.
#[cfg(target_os = "linux")]
#[derive(Default)]
struct Summary {
    worker_states: std::collections::BTreeMap<String, usize>,
    files: std::collections::BTreeMap<String, (usize, usize)>,
}

#[cfg(target_os = "linux")]
impl Summary {
    fn add(&mut self, worker: bool, state: char, wchan: &str, call: Option<&str>, fd: Option<&str>) {
        if worker {
            let what = match (state, call) {
                (_, Some(call)) => format!("{state}:{call}"),
                ('S', None) if wchan.starts_with("futex") => "parked-or-lock".to_string(),
                _ => format!("{state}:{wchan}"),
            };
            *self.worker_states.entry(what).or_default() += 1;
        }
        if let (Some(call), Some(fd)) = (call, fd) {
            // Only waits in a syscall a stalled runtime can be held by; a parked poll is not one.
            if state == 'D' || matches!(call, "flock" | "fsync" | "fdatasync") {
                let at = self.files.entry(format!("{call} {fd}")).or_default();
                if worker { at.0 += 1 } else { at.1 += 1 }
            }
        }
    }

    fn render(&self, workers: usize) -> String {
        let mut out = format!("# workers marked: {workers}\n# worker states:");
        for (what, n) in &self.worker_states {
            out.push_str(&format!(" {what}={n}"));
        }
        out.push('\n');
        let mut files: Vec<_> = self.files.iter().collect();
        files.sort_by_key(|(_, (w, o))| std::cmp::Reverse(w + o));
        for (what, (w, o)) in files.into_iter().take(30) {
            out.push_str(&format!("# waiting: {what} workers={w} others={o}\n"));
        }
        out
    }
}

/// A syscall a thread sits in, by name, and the fd it acts on when its first argument is one.
#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Blocked {
    pub(crate) name: &'static str,
    pub(crate) fd: Option<u64>,
}

/// Reads `/proc/<tid>/syscall` ("NR ARG0 ARG1 ... SP PC"): the call's name for those that act on
/// files, and its fd (a dirfd of `AT_FDCWD` is none).
#[cfg(target_os = "linux")]
pub(crate) fn blocked_on(syscall: &str) -> Option<Blocked> {
    let mut parts = syscall.split_whitespace();
    let nr: i64 = parts.next()?.parse().ok()?;
    let arg0 = parts.next().and_then(|a| u64::from_str_radix(a.trim_start_matches("0x"), 16).ok());
    let name = fd_syscall_name(nr)?;
    // Real fds are small; AT_FDCWD (-100) reads as a huge unsigned value.
    let fd = arg0.filter(|&fd| fd < (1 << 24));
    Some(Blocked { name, fd })
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn fd_syscall_name(nr: i64) -> Option<&'static str> {
    Some(match nr {
        0 => "read",
        1 => "write",
        17 => "pread64",
        18 => "pwrite64",
        73 => "flock",
        74 => "fsync",
        75 => "fdatasync",
        77 => "ftruncate",
        217 => "getdents64",
        257 => "openat",
        258 => "mkdirat",
        263 => "unlinkat",
        264 => "renameat",
        277 => "sync_file_range",
        285 => "fallocate",
        316 => "renameat2",
        _ => return None,
    })
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
fn fd_syscall_name(nr: i64) -> Option<&'static str> {
    Some(match nr {
        63 => "read",
        64 => "write",
        67 => "pread64",
        68 => "pwrite64",
        32 => "flock",
        82 => "fsync",
        83 => "fdatasync",
        46 => "ftruncate",
        61 => "getdents64",
        56 => "openat",
        34 => "mkdirat",
        35 => "unlinkat",
        38 => "renameat",
        84 => "sync_file_range",
        47 => "fallocate",
        276 => "renameat2",
        _ => return None,
    })
}

#[cfg(all(target_os = "linux", not(any(target_arch = "x86_64", target_arch = "aarch64"))))]
fn fd_syscall_name(_nr: i64) -> Option<&'static str> {
    None
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn write_stacks(_file: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("no stack capture on this OS"))
}

#[cfg(test)]
#[path = "runtime_stall_tests.rs"]
mod tests;
