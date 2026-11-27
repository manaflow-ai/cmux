//! Existing keyed-daemon update path: drain first, then let its supervisor or a detached
//! takeover start replace it. Its app/provisioner enrolls the successor through the existing
//! protocol; no person key is exported across this handoff.
use cmux_supervise_core::{Swap, Swapped};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

// timeout: a successor which never asks to take over leaves the old daemon serving.
const HANDOVER_WITHIN: Duration = Duration::from_secs(15);

pub(super) async fn replace(installed: PathBuf, update_owner: String) -> Result<(), String> {
    let engine_args = crate::cli::entry::original_args()
        .map(<[String]>::to_vec)
        .unwrap_or_else(|| std::env::args().skip(1).collect());
    let args = super::daemon_prefix()
        .into_iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .chain(engine_args)
        .collect();
    tokio::task::spawn_blocking(move || {
        let mut steps = ExeSwap { installed, args, update_owner };
        match cmux_supervise_core::make_before_break(&mut steps, super::exe_swap::READY_WITHIN) {
            Swapped::New => Ok(()),
            Swapped::KeptOld(why) => Err(why),
        }
    })
    .await
    .map_err(|error| format!("keyed update task: {error}"))?
}

/// The swap's steps for this daemon.
struct ExeSwap {
    installed: PathBuf,
    /// This daemon's own arguments, after its executable.
    args: Vec<String>,
    update_owner: String,
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
        let mut child = successor
            .env("ACPMUX_HANDOVER_UPDATE_OWNER", &self.update_owner)
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
#[path = "keyed_swap_tests.rs"]
mod tests;
