//! An update that moves this daemon's executable away (F9): the swap renames the old app bundle
//! under a backup folder (`nightly-update` moves it to `~/.local/state/nightly-update/backup/`)
//! and puts the new one at the installed path. The daemon outlives the app, so until now it kept
//! serving from the backup path, and clients that check their peer's executable refused it
//! (compendium app-and-daemons, "refused the acpmux socket peer: pid N runs .../backup/...").
//!
//! The daemon watches the identity of its installed executable and of every folder above it
//! (the home watch's kernel watch, `home_watch::Owned`, no polling). Once that path is replaced
//! or moved, and a file runs there again, it swaps make-before-break
//! (`cmux_supervise_core::make_before_break`):
//!
//! 1. start the new build beside this daemon: `<installed> --version` must answer;
//! 2. readiness: it answered within [`READY_WITHIN`]. A new build that does not run (a cut copy,
//!    another architecture, a refused signature) is dropped here and this daemon keeps serving;
//! 3. handover through the owner's own restart command: the service manager's restart for a
//!    daemon it runs (launchd `kickstart -k`, systemd `restart`), else a `daemon run --take-over`
//!    of the installed path, which asks this daemon to hand the home over (agents kept) and
//!    serves it next. If that start ends before it asks, this daemon keeps serving.
//!
//! A swap that kept this daemon tries again by itself ([`RETRY_AFTER`]), and a client may ask for
//! it now (`_acpmux/shutdown` with `swapIfReplaced`, [`request_swap`]): the app does that instead
//! of stopping a daemon whose bundle an update replaced.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_supervise_core::{Swap, Swapped};

/// How long after the installed path changed a file there may take to become runnable (its
/// copy and chmod), looked at every [`BUILD_LOOK`].
// timeout: an update that leaves no runnable file is no build yet; the next change looks again.
const BUILD_WITHIN: Duration = Duration::from_secs(10);
const BUILD_LOOK: Duration = Duration::from_millis(100);
/// How long the new build may take to answer `--version`.
// timeout: a new build that hangs at its start is a failed readiness; the old daemon serves on.
pub(crate) const READY_WITHIN: Duration = Duration::from_secs(10);
/// How long a `--take-over` start has to reach its handover request before the swap reads it
/// as failed.
// timeout: a take-over start that never asks is a failed handover; the old daemon serves on.
const HANDOVER_WITHIN: Duration = Duration::from_secs(15);

/// After a swap that kept the old daemon (a new build that did not answer, a take-over start that
/// never asked in time under load), the watch tries again after each of these waits, as long as
/// the installed path still is not the file this daemon runs. Before, a failed swap waited for the
/// next change of the path, so the replaced daemon served on until the app stopped it: the app
/// cannot hand a daemon whose bundle an update replaced this launch's person key (it cannot check
/// that peer), and its stop left every chat without a daemon until a new one started (Leo's
/// NIGHTLY, 2026-11-22 23:44Z: the swap failed at :25, the app stopped the daemon at :35, 4.6 s
/// dark).
// timeout: not a deadline; the waits between swap attempts, each a `--version` and a take-over start.
pub(crate) const RETRY_AFTER: [Duration; 5] = [
    Duration::from_secs(5),
    Duration::from_secs(15),
    Duration::from_secs(30),
    Duration::from_secs(60),
    Duration::from_secs(120),
];

/// The installed path and its identity when the watch started, for [`replaced`] and a client's
/// swap request ([`request_swap`]).
static WATCHED: std::sync::OnceLock<(PathBuf, super::home_watch::Owned)> =
    std::sync::OnceLock::new();
/// A client asked for the swap now (`_acpmux/shutdown` with `swapIfReplaced`).
static SWAP_NOW: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// Why the installed executable is no longer the file this daemon runs, when a runnable build
/// is there now; `None` when it is the same file, the watch is off, or no build runs there yet.
pub(crate) fn replaced() -> Option<String> {
    let (installed, owned) = WATCHED.get()?;
    let why = owned.lost()?;
    runnable(installed).then_some(why)
}

/// A client's swap request: when an update replaced this daemon's executable and a build runs at
/// the installed path, the watch swaps to it now, make-before-break, instead of the client's stop
/// (the old daemon serves until the new build asks for the home; if it never does, it serves
/// on). Returns why, or `None` (no update to swap to): then the client's stop goes on.
pub(crate) fn request_swap() -> Option<String> {
    let why = replaced()?;
    SWAP_NOW.notify_one();
    Some(why)
}

/// What woke the watch.
enum Wake {
    /// The kernel watch saw the path or a folder above it change.
    Changed,
    /// A client asked for the swap ([`request_swap`]).
    Asked,
    /// The wait after a failed swap ended ([`RETRY_AFTER`]).
    Retry,
}

/// Watch the installed executable; swap once an update replaced it. The path, its identity and
/// the kernel watch are taken here, when this is called (before the daemon says ready: an update
/// right after ready is then a change, never the baseline); the future it returns never resolves.
pub(super) fn watch(args: Vec<String>) -> impl std::future::Future<Output = ()> + Send + 'static {
    let start = start();
    if let Some((installed, owned, _, _)) = &start {
        let _ = WATCHED.set((installed.clone(), owned.clone()));
    }
    async move {
        let Some((installed, owned, _watcher, mut rx)) = start else {
            return std::future::pending().await;
        };
        let mut watching = true;
        // The next wait after a failed swap, by attempt; none after the last.
        let mut failed = 0usize;
        loop {
            let retry = failed.checked_sub(1).and_then(|i| RETRY_AFTER.get(i)).copied();
            let wake = tokio::select! {
                got = rx.recv(), if watching => match got {
                    Some(()) => Wake::Changed,
                    None => {
                        watching = false;
                        continue;
                    }
                },
                () = SWAP_NOW.notified() => Wake::Asked,
                () = tokio::time::sleep(retry.unwrap_or(Duration::MAX)), if retry.is_some() => Wake::Retry,
            };
            let Some(why) = owned.lost() else {
                failed = 0;
                continue;
            };
            // The move, the new copy and its mode are separate steps of the update, and the last
            // (a chmod) changes no identity the watch sees: look again until a file runs.
            let mut waited = Duration::ZERO;
            while !runnable(&installed) && waited < BUILD_WITHIN {
                tokio::time::sleep(BUILD_LOOK).await;
                waited += BUILD_LOOK;
            }
            if !runnable(&installed) {
                tracing::info!("update: {why}; waiting for a build at {}", installed.display());
                continue;
            }
            match wake {
                Wake::Changed => {
                    tracing::warn!(
                        "update: {why}; swapping to the build at {}",
                        installed.display()
                    )
                }
                Wake::Asked => tracing::warn!(
                    "update: {why}; a client asked for the swap; swapping to the build at {}",
                    installed.display()
                ),
                Wake::Retry => tracing::warn!(
                    "update: {why}; trying the swap again (attempt {}) to the build at {}",
                    failed + 1,
                    installed.display()
                ),
            }
            let mut steps = ExeSwap { installed: installed.clone(), args: args.clone() };
            match tokio::task::spawn_blocking(move || {
                cmux_supervise_core::make_before_break(&mut steps, READY_WITHIN)
            })
            .await
            {
                Ok(Swapped::New) => return std::future::pending().await,
                Ok(Swapped::KeptOld(why)) => {
                    failed += 1;
                    let next = RETRY_AFTER.get(failed - 1).map_or_else(
                        || "at the next change or a client's ask".to_owned(),
                        |d| format!("in {}s", d.as_secs()),
                    );
                    tracing::warn!(
                        "update: the new build did not take over; this daemon serves on, trying again {next}: {why}"
                    );
                }
                Err(e) => {
                    failed += 1;
                    tracing::warn!("update: the swap task: {e}");
                }
            }
        }
    }
}

type Started = (
    PathBuf,
    super::home_watch::Owned,
    crate::agent_host::record_watch::DirWatch,
    tokio::sync::mpsc::Receiver<()>,
);

/// The installed path, its identity now, and a kernel watch on it and every folder above it.
fn start() -> Option<Started> {
    let installed = std::env::current_exe().ok()?;
    let Some(owned) = super::home_watch::Owned::now(&[&installed]) else {
        tracing::warn!("update watch off: {} cannot be read", installed.display());
        return None;
    };
    let (tx, rx) = tokio::sync::mpsc::channel::<()>(1);
    let mut paths: Vec<PathBuf> = installed.ancestors().map(Path::to_path_buf).collect();
    if let Ok(resolved) = std::fs::canonicalize(&installed) {
        paths.extend(resolved.ancestors().map(Path::to_path_buf));
    }
    paths.retain(|p| !p.as_os_str().is_empty() && p != Path::new("/"));
    paths.sort();
    paths.dedup();
    let Some(watcher) = crate::agent_host::record_watch::DirWatch::start_identities(&paths, {
        move || {
            let _ = tx.try_send(());
            tx.is_closed()
        }
    }) else {
        tracing::warn!("update watch off: no watch on {}", installed.display());
        return None;
    };
    Some((installed, owned, watcher, rx))
}

/// A regular file this user may run.
fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The swap's steps for this daemon.
struct ExeSwap {
    installed: PathBuf,
    /// This daemon's own arguments, after its executable.
    args: Vec<String>,
}

impl Swap for ExeSwap {
    type New = cmux_process::Child;

    fn start_new(&mut self) -> Result<cmux_process::Child, String> {
        cmux_process::Command::new(&self.installed)
            .arg("--version")
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .spawn()
            .map_err(|e| format!("{}: {e}", self.installed.display()))
    }

    fn ready(&mut self, new: &mut cmux_process::Child, deadline: Instant) -> Result<(), String> {
        let left = deadline.saturating_duration_since(Instant::now());
        let status = new
            .wait_timeout(left)
            .map_err(|e| format!("--version: {e}"))?
            .ok_or("no answer to --version")?;
        if !status.success() {
            return Err(format!("--version exited {status}"));
        }
        Ok(())
    }

    fn hand_over(&mut self, _new: &mut cmux_process::Child) -> Result<(), String> {
        if let Some(restart) = service_restart()
            && let Some((program, args)) = restart.split_first()
        {
            let command = restart.join(" ");
            let status = cmux_process::Command::new(program)
                .args(args)
                .stdin(cmux_process::Stdio::null())
                .status()
                .map_err(|e| format!("{command}: {e}"))?;
            restart_outcome(&command, status)?;
            tracing::info!("update: handed over to the new build through {command}");
            return Ok(());
        }
        let (stdout, stderr) = successor_output(&crate::config::home().join("daemon.log"));
        // Its own session, so this daemon's stop does not end it.
        let mut successor = cmux_process::Command::new(&self.installed);
        // A daemon started from a chat's shell by an older build kept that chat's marks; the
        // successor drops them (`STARTER_SESSION_MARKS`).
        for k in super::STARTER_SESSION_MARKS {
            successor.env_remove(k);
        }
        // It follows the owner this daemon follows now (a relaunched app adopted after an update,
        // `owner_exit::adopt_if_relaunched`), not the pid this daemon inherited, which an update
        // quit; and it learns the owner's executable, so it can adopt the relaunched app too.
        if let Some(pid) = crate::owner_exit::current_pid() {
            successor.env(crate::owner_exit::OWNER_APP_PID_ENV, pid.to_string());
        }
        if let Some(exe) = crate::owner_exit::current_exe() {
            successor.env(crate::owner_exit::OWNER_APP_EXE_ENV, exe);
        }
        let mut child = successor
            .args(handover_args(&self.args))
            .stdin(cmux_process::Stdio::null())
            .stdout(stdout)
            .stderr(stderr)
            .new_session()
            .spawn()
            .map_err(|e| format!("{}: {e}", self.installed.display()))?;
        // It took over once it asked this daemon to hand over (`supervision::stopping` holds the
        // handover's cause); it failed if it ended before that. A failed one ends with `child`.
        let deadline = Instant::now() + HANDOVER_WITHIN;
        loop {
            if super::supervision::handing_over() {
                child.detach("the take-over daemon serves this home after this daemon stops");
                return Ok(());
            }
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!("the take-over start exited {status} before it asked"));
            }
            if Instant::now() >= deadline {
                return Err("the take-over start never asked to take over".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn abort(&mut self, new: cmux_process::Child) {
        // Dropped, it ends and is reaped (`cmux_process::Child`).
        drop(new);
    }
}

/// Where the take-over daemon writes: this home's daemon log, as a daemon a command starts does
/// (`spawn_detached`). It wrote nowhere before, so after the first update a daemon's log stopped
/// for good, and a disconnect after it left no line. A log that cannot be opened leaves it none.
fn successor_output(log: &Path) -> (cmux_process::Stdio, cmux_process::Stdio) {
    let opened = super::open_daemon_log(log).and_then(|out| Ok((out.try_clone()?, out)));
    match opened {
        Ok((out, err)) => (out.into(), err.into()),
        Err(e) => {
            tracing::warn!("update: the take-over daemon writes no log: {e:#}");
            (cmux_process::Stdio::null(), cmux_process::Stdio::null())
        }
    }
}

/// This daemon's arguments (after its executable: `daemon run ...`, or `acp daemon run ...` as
/// `cmux-tui`) for its successor, with `--take-over` right after `run`. Its fds are not the
/// successor's, so `--ready-fd` and `--person-key-fd` stay out (the app that holds the person key
/// gives it again when it checks the daemon it started, `hub/person.rs`).
pub(super) fn handover_args(args: &[String]) -> Vec<String> {
    let run = args.iter().position(|a| a == "run").map_or(0, |i| i + 1);
    let mut out: Vec<String> = args.iter().take(run).cloned().collect();
    out.push("--take-over".into());
    let mut it = args.iter().skip(run);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--ready-fd" | "--person-key-fd" => {
                it.next();
            }
            "--take-over" => {}
            a if a.starts_with("--ready-fd=") || a.starts_with("--person-key-fd=") => {}
            _ => out.push(arg.clone()),
        }
    }
    out
}

/// What the end of the service manager's restart command says about the handover. Exit 0: the
/// restart was queued. Killed by SIGTERM: the stop was issued already. The command runs as this
/// daemon's child, so it is in the job it restarts (systemd's unit cgroup, launchd's job), and the
/// manager's stop of that job (`restart --no-block`, `kickstart -k`) sends SIGTERM to it too, in
/// the moment between queueing the restart and exiting. Before this, every hourly update logged
/// "the new build did not take over ... exited signal: 15 (SIGTERM)" while the new build served
/// 0.9 s later (cmuxterm-hq #19255, findings 2026-11-22 section 2).
///
/// Signal 15 alone decides it, not this daemon's own stop flag (`supervision::stopping`): the
/// daemon's SIGTERM is read on the async runtime after its sender is looked up, so the flag can
/// trail the reap of this child, and waiting for it would only add a race. Any other signal or
/// exit code is a failed handover, and this daemon serves on.
fn restart_outcome(command: &str, status: std::process::ExitStatus) -> Result<(), String> {
    use std::os::unix::process::ExitStatusExt as _;
    if status.success() || status.signal() == Some(libc::SIGTERM) {
        Ok(())
    } else {
        Err(format!("{command} exited {status}"))
    }
}

/// The service manager's own restart command for the job that runs this daemon, if one does.
fn service_restart() -> Option<Vec<String>> {
    if super::managed_by_acpmux_unit() {
        return Some(
            [
                "systemctl",
                "--user",
                "restart",
                "--no-block",
                crate::cli::daemon_service::SYSTEMD_SERVICE,
            ]
            .map(String::from)
            .to_vec(),
        );
    }
    #[cfg(target_os = "macos")]
    if std::env::var("XPC_SERVICE_NAME").ok().as_deref()
        == Some(crate::cli::daemon_service::LAUNCHD_LABEL)
    {
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        return Some(vec![
            "launchctl".into(),
            "kickstart".into(),
            "-k".into(),
            format!("gui/{uid}/{}", crate::cli::daemon_service::LAUNCHD_LABEL),
        ]);
    }
    None
}

#[cfg(test)]
#[path = "exe_swap_tests.rs"]
mod tests;
