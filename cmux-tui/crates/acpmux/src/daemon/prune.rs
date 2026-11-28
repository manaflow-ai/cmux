//! Retired daemons are pruned: "plus i was thinking how about we can help prune
//! retired/old/irrelevant acpmux daemons automatically. i know we did a lot of that manually
//! before. we need to be able to have the app/daemon auto heal and stuff. [...] we need to have
//! more of our things be more self-cleaning." (Leo, 2026-11-22, ask-061fea24e8)
//!
//! Each daemon already stops itself once it is unused (`unused_exit.rs`), its app is gone
//! (`app_orphan.rs`), its owner app quit (`owner_exit.rs`), its home, socket or lock went or was
//! replaced (`home_watch.rs`: a removed temporary home, a daemon that lost its home to a newer
//! one) or its installed executable was replaced by an update (`exe_swap.rs`). This file adds the
//! two parts those leave out.
//!
//! **A retired build stops sooner, by its own decision.** A daemon whose executable is gone from
//! the path it started from (a tagged or per-build install that was removed, not replaced) serves
//! a build nobody installs any more. It looks at that path every [`LOOK_EVERY`] (one `stat`);
//! once the file is gone it stops as soon as it has been unused for [`RETIRED_GRACE`] instead of
//! the hour of `unused_exit::GRACE`. "Unused" is exactly what the hour already asks: no client,
//! and nothing [`crate::hub::Hub::in_use`] names (its startup or adoption, a peer, mesh, tailnet
//! or WireGuard link, a WebSocket listener off loopback, an undelivered message, a watch, a move,
//! a running agent or agent host, a turn or anything one waits on, a background task), checked
//! by the daemon itself, under its own state, with a client that arrives meanwhile starting the
//! wait again. Nothing outside the daemon reads its status and then stops it, so there is no race
//! between a read and a stop. Never on the shared `~/.acpmux` (which the app, NIGHTLY, the CLI
//! and peers expect to answer), never for a daemon acpmux's service unit runs, never for a
//! memory-store daemon (a stop loses its chats: `AcpmuxVersionHandoff.swift`) and never where
//! `ACPMUX_UNUSED_EXIT_SECS=0` turned unused stops off.
//!
//! **Records no daemon holds are cleared.** A daemon that crashed or was killed leaves its socket
//! and `daemon.pid` behind. For the shared home and each per-build home under it
//! (`~/.acpmux/builds/*`), a pass looks at the lock: when no process holds `daemon.lock` (the
//! kernel lock, probed without taking it), the pid the lock names provably runs no more
//! (`kill(pid, 0)`: no such process) and the lock was last written over [`STALE_AFTER`] ago, it
//! removes that home's `acpmux.sock` (only a socket) and `daemon.pid`, holding the lock
//! exclusively for the moment of the removal so no daemon starts in between (a start in that
//! moment finds the lock taken and its starter tries again). It never removes the lock, the home
//! or anything else in it, and never signals a process. A live pid, even one that may have been
//! reused, is left: it is not provably no acpmux.
//!
//! Every home the pass looks at is listed with its verdict and the reason (`acpmux daemon prune`,
//! a dry run unless `--apply`; `--json`), and each removal writes one log line with pid, build,
//! age and reason. The pass reads no other process (holders register themselves:
//! `check-no-process-scan.py`): only lock files, owner records and `stat`s, at most [`MAX_HOMES`]
//! homes. A daemon on the shared home or a per-build home runs it [`START_DELAY`] after it
//! starts, then every [`LOOK_EVERY`]; `ACPMUX_DAEMON_PRUNE=0` turns off both parts.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long a retired daemon must be unused before it stops (the hour of `unused_exit::GRACE`
/// for one whose build is still installed).
pub(crate) const RETIRED_GRACE: Duration = Duration::from_secs(5 * 60);
/// How often a daemon looks at its executable, and how often the pass runs.
pub(crate) const LOOK_EVERY: Duration = Duration::from_secs(10 * 60);
/// How long after a daemon starts its first pass runs: its own startup comes first.
const START_DELAY: Duration = Duration::from_secs(2 * 60);
/// How long a lock nobody holds must have been left before its records are cleared.
pub(crate) const STALE_AFTER: Duration = Duration::from_secs(60);
/// The most homes one pass looks at: a constant cost however many build homes piled up.
pub(crate) const MAX_HOMES: usize = 512;
/// `ACPMUX_DAEMON_PRUNE=0` turns the pass and the retired stop off.
pub(crate) const OFF_ENV: &str = "ACPMUX_DAEMON_PRUNE";

/// Whether pruning is on (`ACPMUX_DAEMON_PRUNE` is anything but `0`).
pub(crate) fn enabled() -> bool {
    std::env::var(OFF_ENV).map_or(true, |v| v.trim() != "0")
}

// ---- A retired build stops sooner ----

/// Resolves, with why, once the executable this daemon started from is gone from its path. A
/// file there again (an update's replacement) is `exe_swap.rs`'s, never a retirement. Never
/// resolves when the path cannot be read at the start.
pub(super) async fn retired() -> String {
    let Some(exe) = std::env::current_exe().ok().filter(|p| exe_present(p)) else {
        return std::future::pending().await;
    };
    loop {
        tokio::time::sleep(LOOK_EVERY).await;
        let gone = {
            let exe = exe.clone();
            tokio::task::spawn_blocking(move || !exe_present(&exe)).await.unwrap_or(false)
        };
        if gone {
            return format!("its executable {} is gone", exe.display());
        }
    }
}

/// Whether a file is at `path`: an error other than "not found" (a permission) is no proof it
/// went.
pub(crate) fn exe_present(path: &Path) -> bool {
    match std::fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(e) => e.kind() != std::io::ErrorKind::NotFound,
    }
}

/// The stop line of a retired daemon: why it retired, why it is unused, and its pid, build and
/// age, on one line.
pub(crate) fn retired_stop_line(retired: &str, unused: &str, age: Duration) -> String {
    format!(
        "retired: {retired}, and {unused} (pid {} build {} age {} reason exe-gone)",
        std::process::id(),
        crate::build_info::build(),
        age_words(age)
    )
}

// ---- Records no daemon holds ----

/// What the pass saw of one home: a snapshot, so [`classify`] is a pure function of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Seen {
    pub home: PathBuf,
    /// The shared `~/.acpmux`.
    pub shared: bool,
    /// This process holds the home's lock (the daemon running the pass).
    pub this: bool,
    /// A process holds `daemon.lock` (the kernel lock).
    pub lock_held: bool,
    /// The pid the lock (else `daemon.pid`) names.
    pub holder: Option<u32>,
    /// `kill(holder, 0)` said there is no such process.
    pub holder_gone: bool,
    /// `acpmux.sock` is there, as a socket.
    pub socket_exists: bool,
    pub pid_file_exists: bool,
    /// Since the lock file was last written (a daemon writes it as it takes the lock).
    pub age: Option<Duration>,
    /// The program its owner record names (`daemon.owner.json`).
    pub exe: Option<PathBuf>,
    pub exe_exists: bool,
}

/// Why a home is left as it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Keep {
    /// This daemon's own home.
    ThisDaemon,
    /// The shared home's daemon, which the app and every command expect to answer: never pruned.
    SharedHome { pid: Option<u32> },
    /// A daemon holds the lock: it stops itself by its own rules.
    Runs { pid: Option<u32>, exe_gone: bool },
    /// No daemon, and no socket or pid file left either.
    Clean,
    /// The lock was written under [`STALE_AFTER`] ago: a start may be under way.
    Young,
    /// No daemon holds the lock, but it names no pid: not provably no acpmux.
    NoPid,
    /// No daemon holds the lock, but its pid still runs (maybe reused): not provably no acpmux.
    PidRuns { pid: u32 },
}

impl Keep {
    pub(crate) fn word(&self) -> &'static str {
        match self {
            Self::ThisDaemon => "this-daemon",
            Self::SharedHome { .. } => "shared-home",
            Self::Runs { .. } => "runs",
            Self::Clean => "clean",
            Self::Young => "young",
            Self::NoPid => "no-pid",
            Self::PidRuns { .. } => "pid-runs",
        }
    }

    pub(crate) fn phrase(&self) -> String {
        let pid = |p: &Option<u32>| p.map_or("pid unknown".to_owned(), |p| format!("pid {p}"));
        let hour = super::unused_exit::GRACE.as_secs() / 60;
        match self {
            Self::ThisDaemon => "the daemon running this pass".into(),
            Self::SharedHome { pid: p } => format!(
                "the shared home's daemon ({}), which the app and every command expect: never \
                 pruned",
                pid(p)
            ),
            Self::Runs { pid: p, exe_gone: true } => format!(
                "a daemon runs here ({}) and its executable is gone: it stops itself once unused \
                 for {} (a build from before that rule: {hour} min)",
                pid(p),
                age_words(RETIRED_GRACE),
            ),
            Self::Runs { pid: p, exe_gone: false } => {
                format!(
                    "a daemon runs here ({}): it stops itself once unused for {hour} min",
                    pid(p)
                )
            }
            Self::Clean => "no daemon, and no socket or pid file left".into(),
            Self::Young => format!(
                "no daemon holds the lock, but it was written under {} ago: a start may be under \
                 way",
                age_words(STALE_AFTER)
            ),
            Self::NoPid => {
                "no daemon holds the lock, but it names no pid: not provably no acpmux".into()
            }
            Self::PidRuns { pid } => format!(
                "no daemon holds the lock, but pid {pid} still runs (maybe another process now): \
                 not provably no acpmux"
            ),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Its socket and pid file are a dead daemon's: removed.
    Stale {
        pid: u32,
    },
    Keep(Keep),
}

/// The verdict on one home (module docs).
pub(crate) fn classify(seen: &Seen) -> Verdict {
    if seen.this {
        return Verdict::Keep(Keep::ThisDaemon);
    }
    if seen.lock_held {
        if seen.shared {
            return Verdict::Keep(Keep::SharedHome { pid: seen.holder });
        }
        let exe_gone = seen.exe.is_some() && !seen.exe_exists;
        return Verdict::Keep(Keep::Runs { pid: seen.holder, exe_gone });
    }
    if !seen.socket_exists && !seen.pid_file_exists {
        return Verdict::Keep(Keep::Clean);
    }
    if seen.age.is_none_or(|age| age < STALE_AFTER) {
        return Verdict::Keep(Keep::Young);
    }
    match seen.holder {
        None => Verdict::Keep(Keep::NoPid),
        Some(pid) if !seen.holder_gone => Verdict::Keep(Keep::PidRuns { pid }),
        Some(pid) => Verdict::Stale { pid },
    }
}

/// `1h 10m`, `4m 2s`, `12s`.
pub(crate) fn age_words(age: Duration) -> String {
    let s = age.as_secs();
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m {}s", s / 60, s % 60),
        3600..86_400 => format!("{}h {}m", s / 3600, s % 3600 / 60),
        _ => format!("{}d {}h", s / 86_400, s % 86_400 / 3600),
    }
}

/// The pid on the first line of a lock file or `daemon.pid`.
pub(crate) fn parse_pid(text: &str) -> Option<u32> {
    text.lines().next()?.trim().parse().ok().filter(|p| *p > 0)
}

/// The homes a pass looks at: the shared home, this daemon's own, and each per-build home under
/// the shared one, at most [`MAX_HOMES`].
fn homes() -> Vec<PathBuf> {
    let shared = crate::config::default_home();
    let mut homes = vec![shared.clone()];
    let own = crate::config::home();
    if own != shared {
        homes.push(own);
    }
    if let Ok(entries) = std::fs::read_dir(shared.join("builds")) {
        for entry in entries.flatten() {
            if homes.len() >= MAX_HOMES {
                break;
            }
            let path = entry.path();
            if entry.file_type().is_ok_and(|t| t.is_dir()) && !homes.contains(&path) {
                homes.push(path);
            }
        }
    }
    homes
}

/// Whether `pid` provably runs no more: no such process (not EPERM, which is another user's).
#[cfg(unix)]
fn pid_gone(pid: u32) -> bool {
    let Ok(raw) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 sends nothing; it only asks whether the process exists.
    let rc = unsafe { libc::kill(raw, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[cfg(unix)]
fn is_socket(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket())
}

/// Look at one home.
#[cfg(unix)]
fn look(home: &Path, shared: &Path) -> Seen {
    let lock = home.join("daemon.lock");
    let lock_held = super::lock::lock_has_live_holder(&lock);
    let read_pid = |path: PathBuf| std::fs::read_to_string(path).ok().and_then(|t| parse_pid(&t));
    let holder = read_pid(lock.clone()).or_else(|| read_pid(home.join("daemon.pid")));
    let age =
        std::fs::metadata(&lock).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok());
    let exe = super::supervision::owner(home)
        .and_then(|r| r.argv.into_iter().next())
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    Seen {
        home: home.to_owned(),
        shared: home == shared,
        // A command that runs the pass holds no lock: only a daemon's own home is `this`.
        this: lock_held && holder == Some(std::process::id()),
        lock_held,
        holder,
        holder_gone: holder.is_some_and(pid_gone),
        socket_exists: is_socket(&home.join("acpmux.sock")),
        pid_file_exists: home.join("daemon.pid").exists(),
        age,
        exe_exists: exe.as_deref().is_some_and(exe_present),
        exe,
    }
}

/// Remove a dead daemon's socket and pid file, under the home's lock taken exclusively for the
/// moment of the removal, after one more look that its pid is still gone.
#[cfg(unix)]
fn clear(home: &Path, pid: u32) -> Result<Vec<&'static str>, String> {
    use cmux_file_lock::{FileLock, Kind, LockError};
    let lock = home.join("daemon.lock");
    let file = std::fs::File::open(&lock).map_err(|e| format!("open {}: {e}", lock.display()))?;
    // Held only for the removal below; its drop unlocks.
    let _held = match FileLock::try_take(file, Kind::Exclusive) {
        Ok(held) => held,
        Err(LockError::Busy(_)) => return Err("a daemon took the lock".into()),
        Err(LockError::Io(e)) => return Err(format!("lock {}: {e}", lock.display())),
    };
    let now = std::fs::read_to_string(&lock).ok().and_then(|t| parse_pid(&t));
    if now.is_some_and(|p| p != pid) || !pid_gone(pid) {
        return Err(format!("pid {pid} is no longer the gone holder"));
    }
    let mut removed = Vec::new();
    let socket = home.join("acpmux.sock");
    if is_socket(&socket) && crate::home_fs::remove_file(&socket).is_ok() {
        removed.push("acpmux.sock");
    }
    let pid_file = home.join("daemon.pid");
    let recorded = std::fs::read_to_string(&pid_file).ok().and_then(|t| parse_pid(&t));
    if pid_file.exists()
        && recorded.is_none_or(|p| p == pid)
        && crate::home_fs::remove_file(&pid_file).is_ok()
    {
        removed.push("daemon.pid");
    }
    Ok(removed)
}

/// One home, its verdict, and what an applied pass removed.
pub(crate) struct Judged {
    pub seen: Seen,
    pub verdict: Verdict,
    /// `Some` once a pass tried to clear it.
    pub cleared: Option<Result<Vec<&'static str>, String>>,
}

impl Judged {
    fn build(&self) -> String {
        self.seen.exe.as_deref().map_or("unknown".into(), |p| p.display().to_string())
    }

    fn age(&self) -> String {
        self.seen.age.map_or("unknown".into(), age_words)
    }

    fn pid(&self) -> String {
        self.seen.holder.map_or("none".into(), |p| p.to_string())
    }

    /// The one log line of a removal.
    pub(crate) fn log_line(&self) -> String {
        let removed = match &self.cleared {
            Some(Ok(r)) => r.join(", "),
            _ => String::new(),
        };
        format!(
            "pruned stale acpmux daemon records: pid {} build {} age {} reason stale-record (no \
             process holds the lock and the pid is gone) home {} removed {removed}",
            self.pid(),
            self.build(),
            self.age(),
            self.seen.home.display()
        )
    }

    pub(crate) fn json(&self) -> Value {
        let (verdict, reason, why) = match &self.verdict {
            Verdict::Stale { .. } => (
                "prune",
                "stale-record",
                "no process holds the lock and the pid it names is gone".to_owned(),
            ),
            Verdict::Keep(k) => ("keep", k.word(), k.phrase()),
        };
        json!({
            "home": self.seen.home,
            "pid": self.seen.holder,
            "build": self.build(),
            "ageSecs": self.seen.age.map(|a| a.as_secs()),
            "verdict": verdict,
            "reason": reason,
            "why": why,
            "removed": match &self.cleared { Some(Ok(r)) => json!(r), _ => Value::Null },
            "error": match &self.cleared { Some(Err(e)) => json!(e), _ => Value::Null },
        })
    }

    /// One line of `acpmux daemon prune`.
    pub(crate) fn line(&self) -> String {
        let head = format!("{} (pid {}, age {})", self.seen.home.display(), self.pid(), self.age());
        match (&self.verdict, &self.cleared) {
            (Verdict::Stale { .. }, Some(Ok(removed))) => {
                format!("pruned   {head}: stale-record, removed {}", removed.join(", "))
            }
            (Verdict::Stale { .. }, Some(Err(e))) => format!("missed   {head}: stale-record, {e}"),
            (Verdict::Stale { .. }, None) => format!(
                "would prune {head}: stale-record (no process holds the lock and the pid is \
                 gone): its acpmux.sock and daemon.pid"
            ),
            (Verdict::Keep(k), _) => format!("kept     {head}: {}: {}", k.word(), k.phrase()),
        }
    }
}

/// One pass over the homes; with `apply`, stale records are removed and each removal logged.
#[cfg(unix)]
pub(crate) fn pass(apply: bool) -> Vec<Judged> {
    let shared = crate::config::default_home();
    homes()
        .into_iter()
        .map(|home| {
            let seen = look(&home, &shared);
            let verdict = classify(&seen);
            let cleared = match verdict {
                Verdict::Stale { pid } if apply => Some(clear(&home, pid)),
                _ => None,
            };
            let judged = Judged { seen, verdict, cleared };
            match &judged.cleared {
                Some(Ok(_)) => tracing::info!("{}", judged.log_line()),
                Some(Err(e)) => {
                    tracing::info!("left stale records in {}: {e}", judged.seen.home.display())
                }
                None => {}
            }
            judged
        })
        .collect()
}

/// Whether this daemon runs the pass: pruning is on and its home is the shared one or a
/// per-build home under it (a test's temporary home never looks at the person's homes).
fn runs_here() -> bool {
    let shared = crate::config::default_home();
    let home = crate::config::home();
    enabled() && (home == shared || home.parent() == Some(shared.join("builds").as_path()))
}

/// The pass, [`START_DELAY`] after the daemon starts and then every [`LOOK_EVERY`]; never
/// resolves.
#[cfg(unix)]
pub(crate) async fn every_while_running() {
    if !runs_here() {
        return std::future::pending().await;
    }
    tokio::time::sleep(START_DELAY).await;
    loop {
        let _ = tokio::task::spawn_blocking(|| pass(true)).await;
        tokio::time::sleep(LOOK_EVERY).await;
    }
}

/// `acpmux daemon prune [--apply] [--json]`.
#[cfg(unix)]
pub async fn run_command(apply: bool, json_out: bool) -> anyhow::Result<()> {
    let started = std::time::Instant::now();
    let judged = tokio::task::spawn_blocking(move || pass(apply)).await?;
    if json_out {
        crate::cli::output::print_json(&json!({
            "applied": apply,
            "homes": judged.iter().map(Judged::json).collect::<Vec<_>>(),
        }));
        return Ok(());
    }
    for j in &judged {
        println!("{}", j.line());
    }
    if !apply && judged.iter().any(|j| matches!(j.verdict, Verdict::Stale { .. })) {
        println!("a dry run: `acpmux daemon prune --apply` removes those records");
    }
    println!("{} homes looked at in {} ms", judged.len(), started.elapsed().as_millis());
    Ok(())
}

#[cfg(test)]
#[path = "prune_tests.rs"]
mod tests;
