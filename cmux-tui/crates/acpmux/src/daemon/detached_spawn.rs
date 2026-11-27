use super::*;

#[cfg(target_os = "linux")]
fn cgroup_is_in_sessions_scope(contents: &str) -> bool {
    contents.lines().filter_map(|line| line.splitn(3, ':').nth(2)).any(|path| {
        path.split('/').any(|component| component == crate::session_scope::SESSIONS_SLICE)
    })
}

#[cfg(target_os = "linux")]
fn daemon_started_in_session_scope() -> bool {
    std::fs::read_to_string("/proc/self/cgroup")
        .is_ok_and(|contents| cgroup_is_in_sessions_scope(&contents))
}

#[cfg(target_os = "linux")]
pub(super) fn daemon_command(this: &crate::self_command::SelfCommand) -> std::process::Command {
    if daemon_started_in_session_scope()
        && let Some(runner) = crate::session_scope::scope_runner()
        && crate::session_scope::can_make_scope(&runner)
    {
        let mut command = std::process::Command::new(runner);
        command.args([
            "--user",
            "--scope",
            "--quiet",
            "--collect",
            "--no-block",
            "--description=acpmux daemon",
            "--",
        ]);
        command.arg(&this.exe).args(&this.prefix).args(["daemon", "run", "--ready-fd"]);
        return command;
    }
    this.command(&["daemon", "run", "--ready-fd"])
}

#[cfg(not(target_os = "linux"))]
pub(super) fn daemon_command(this: &crate::self_command::SelfCommand) -> std::process::Command {
    this.command(&["daemon", "run", "--ready-fd"])
}

/// The starter chat's session marks a daemon never keeps (`spawn_detached`, the upgrade
/// handover in `daemon/exe_swap.rs`).
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) const STARTER_SESSION_MARKS: [&str; 4] =
    ["ACPMUX_SESSION_ID", "ACPMUX_SESSION_NAME", "ACPMUX_HOST_NONCE", "ACPMUX_BG_TASK"];

/// Name the binary a start runs and why, in the daemon log the new daemon writes to and in this
/// command's own log, so a daemon that came back from an unexpected build says who chose it.
#[cfg(unix)]
pub(crate) fn log_start_choice(log: &mut std::fs::File, choice: &start_exe::Choice) {
    use std::io::Write as _;
    let line = format!(
        "acpmux: starting the daemon from {} (pid {} asked): {}",
        choice.this.exe.display(),
        std::process::id(),
        choice.why
    );
    tracing::info!("{line}");
    let _ = writeln!(log, "{line}");
}

/// Write the key on the daemon's key socket after the daemon said it is
/// not dumpable, then close it. No signal (the daemon refused the key, or
/// exited): nothing is written, and the daemon runs without a key.
#[cfg(unix)]
pub(super) fn hand_key(mut link: std::os::unix::net::UnixStream, key: &str) {
    use std::io::{Read, Write};
    // timeout: a child that never reaches KEY_READY must not retain the
    // person key or strand a handoff thread forever.
    let _ = link.set_read_timeout(Some(START_BUDGET));
    let mut said = [0u8; KEY_READY.len()];
    if link.read_exact(&mut said).is_err() || said != KEY_READY {
        tracing::warn!("the daemon did not say it is not dumpable: no person key was handed over");
        return;
    }
    let line = zeroize::Zeroizing::new(format!("{key}\n"));
    if let Err(e) = link.write_all(line.as_bytes()) {
        tracing::warn!("hand the person key to the daemon: {e}");
    }
    let _ = link.shutdown(std::net::Shutdown::Both);
}

#[cfg(all(test, target_os = "linux"))]
mod scope_tests {
    use super::cgroup_is_in_sessions_scope;

    #[test]
    fn daemon_scope_escape_matches_only_an_exact_session_slice_component() {
        assert!(cgroup_is_in_sessions_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/acpmuxsessions.slice/run-a.scope\n"
        ));
        assert!(!cgroup_is_in_sessions_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-a.scope\n"
        ));
        assert!(!cgroup_is_in_sessions_scope(
            "0::/user.slice/acpmuxsessions.slice.backup/run-a.scope\n"
        ));
        assert!(cgroup_is_in_sessions_scope(
            "1:name=systemd:/user.slice/acpmuxsessions.slice/run-a.scope\n"
        ));
    }
}
