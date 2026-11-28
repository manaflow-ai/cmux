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
    let mut command = this.command(&["daemon", "run", "--ready-fd"]);
    // The daemon's freed pages go back as it frees them (macOS; malloc_space.rs).
    command.envs(cmux_tui_platform::malloc_space::child_env());
    command
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

/// Open the daemon log for append, owner-only like the config file: the log
/// can carry agent output and request details. A log left by an older build
/// with wider bits is narrowed to 0600.
#[cfg(unix)]
pub(super) fn open_daemon_log(path: &std::path::Path) -> Result<std::fs::File> {
    crate::config::private_state_append(path)
}

/// Start `<exe> [prefix] daemon run --ready-fd N` in its own session and
/// return the read end of its readiness pipe. With `key`, the daemon also
/// gets `--person-key-fd M`, one end of a socket pair: the key is written
/// only after the daemon wrote [`KEY_READY`] on it.
#[cfg(unix)]
pub(super) fn spawn_detached(
    key: Option<zeroize::Zeroizing<String>>,
) -> Result<(std::fs::File, u32)> {
    let choice = start_exe::current(&home())?;
    let this = &choice.this;
    crate::config::private_state_dir(&home())?;
    let mut log = open_daemon_log(&home().join("daemon.log"))?;
    log_start_choice(&mut log, &choice);
    let log_err = log.try_clone()?;
    // Close-on-exec from the start (`pipe2(O_CLOEXEC)` where the OS has it):
    // a child another thread forks meanwhile never inherits either end, and
    // pre_exec reopens the write end for the daemon only.
    let (reader, writer) = std::io::pipe().context("pipe for acpmux daemon readiness")?;
    let reader = std::fs::File::from(std::os::fd::OwnedFd::from(reader));
    let write_fd = std::os::fd::AsRawFd::as_raw_fd(&writer);
    // The key's socket pair: `ours` stays here, `theirs` goes to the daemon.
    let pair = match &key {
        Some(_) => {
            let (ours, theirs) =
                std::os::unix::net::UnixStream::pair().context("socket pair for the person key")?;
            Some((ours, theirs))
        }
        None => None,
    };
    let key_fd = pair.as_ref().map(|(_, theirs)| std::os::fd::AsRawFd::as_raw_fd(theirs));
    let mut cmd = daemon_command(this);
    crate::config::scrub_nested_claude_env(&mut cmd);
    // The daemon serves every session: its starter's turn values are not its own.
    for k in crate::config::inherited_caller_scoped_keys() {
        cmd.env_remove(k);
    }
    // Nor its starter's session marks: a daemon a chat's shell started carried that chat's id and
    // host nonce, and so did everything it started for other sessions, which made them read as
    // that chat's (`acpmux process owner`, `cli/process_owner.rs`).
    for k in STARTER_SESSION_MARKS {
        cmd.env_remove(k);
    }
    // The daemon must use this client's state directory and socket, including a host
    // override that its own environment would not reproduce, absolute: it changes into
    // its home before it binds (`login_placement::daemon_env`).
    let cwd = std::env::current_dir().context("this command's folder")?;
    let socket = std::env::var_os("ACPMUX_SOCKET");
    cmd.env_remove("ACPMUX_SOCKET");
    // A daemon a command starts has no owner app: only the app's launcher names one
    // (`daemon/owner_exit.rs`), so a CLI run from an agent or a harness never ties the new daemon
    // to the app that started an older one.
    cmd.env_remove(owner_exit::OWNER_APP_PID_ENV);
    for (key, value) in login_placement::daemon_env(&home(), socket.as_deref(), &cwd) {
        cmd.env(key, value);
    }
    cmd.arg(write_fd.to_string())
        .args(key_fd.map(|fd| ["--person-key-fd".to_owned(), fd.to_string()]).into_iter().flatten())
        .stdin(std::process::Stdio::null())
        .stdout(log)
        .stderr(log_err);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(move || {
                // New session so the daemon outlives the terminal; keep the
                // readiness descriptor open across exec.
                libc::setsid();
                libc::fcntl(write_fd, libc::F_SETFD, 0);
                if let Some(fd) = key_fd {
                    libc::fcntl(fd, libc::F_SETFD, 0);
                }
                Ok(())
            });
        }
    }
    let mut child = tokio::process::Command::from(cmd).spawn().context("spawn acpmux daemon")?;
    let child_pid = child.id().unwrap_or_default();
    // A lock-race loser exits promptly. Reap it even when its CLI caller keeps
    // running (stdio/TUI); dropping std::process::Child left a zombie per retry.
    // This async wait never holds runtime teardown open or kills the winner.
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    // Close this process's copy so end of file means the daemon closed it.
    drop(writer);
    if let (Some(key), Some((ours, theirs))) = (key, pair) {
        drop(theirs);
        // The daemon may be alive but busy before it can read its person key.
        // Keep that handoff off the caller's path and let EOF signal a dead
        // child instead of imposing a wall-clock cutoff.
        let _ = std::thread::Builder::new()
            .name("acpmux-person-key".into())
            .spawn(move || hand_key(ours, &key));
    }
    Ok((reader, child_pid))
}
