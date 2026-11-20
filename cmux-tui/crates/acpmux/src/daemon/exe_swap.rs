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

/// Watch the installed executable; swap once an update replaced it. The path, its identity and
/// the kernel watch are taken here, when this is called (before the daemon says ready: an update
/// right after ready is then a change, never the baseline); the future it returns never resolves.
pub(super) fn watch(args: Vec<String>) -> impl std::future::Future<Output = ()> + Send + 'static {
    let start = start();
    async move {
        let Some((installed, owned, _watcher, mut rx)) = start else {
            return std::future::pending().await;
        };
        loop {
            if rx.recv().await.is_none() {
                return std::future::pending().await;
            }
            let Some(why) = owned.lost() else { continue };
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
            tracing::warn!("update: {why}; swapping to the build at {}", installed.display());
            let mut steps = ExeSwap { installed: installed.clone(), args: args.clone() };
            match tokio::task::spawn_blocking(move || {
                cmux_supervise_core::make_before_break(&mut steps, READY_WITHIN)
            })
            .await
            {
                Ok(Swapped::New) => return std::future::pending().await,
                Ok(Swapped::KeptOld(why)) => {
                    tracing::warn!(
                        "update: the new build did not take over; this daemon serves on: {why}"
                    );
                }
                Err(e) => tracing::warn!("update: the swap task: {e}"),
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
            let status = cmux_process::Command::new(program)
                .args(args)
                .stdin(cmux_process::Stdio::null())
                .status()
                .map_err(|e| format!("{}: {e}", restart.join(" ")))?;
            return if status.success() {
                Ok(())
            } else {
                Err(format!("{} exited {status}", restart.join(" ")))
            };
        }
        // Its own session, so this daemon's stop does not end it.
        let mut child = cmux_process::Command::new(&self.installed)
            .args(handover_args(&self.args))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
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
mod tests {
    use super::*;

    #[test]
    fn the_successor_gets_this_daemons_flags_but_not_its_fds() {
        let args: Vec<String> = [
            "acp",
            "daemon",
            "run",
            "--ready-fd",
            "3",
            "--memory",
            "--person-key-fd=4",
            "--take-over",
            "--dev",
        ]
        .map(String::from)
        .to_vec();
        assert_eq!(
            handover_args(&args),
            ["acp", "daemon", "run", "--take-over", "--memory", "--dev"]
        );
    }
}
