//! Unix: the owner FIFO (cx-1rvy). Its write ends own the local router:
//! the daemon holds one and so does every agent host; the router stops when
//! the last one closes.

use super::{RouterOwner, ask_router};
use crate::config::home;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Duration;

/// This daemon's hold on the router: its write end of the owner FIFO, and
/// the router process when this daemon started it (unreaped until
/// `release`, so its pid stays ours).
pub(super) struct FifoOwner {
    _owner: std::fs::File,
    child: Option<std::process::Child>,
}

/// The FIFO whose write ends own the local router: the daemon holds one,
/// and so does every agent host (`open_router_owner`). The router stops when
/// the last one closes, so it lives exactly as long as a process that may
/// use it: a kept agent keeps it through a daemon restart, and a daemon that
/// dies in any way (SIGKILL included) with no agent left takes it along.
pub(crate) fn router_owner_fifo() -> PathBuf {
    home().join("router").join("owner.fifo")
}

/// An agent host's owner end of the local router: held for the host's
/// whole life (close-on-exec, so the harness never inherits it). None when
/// no router runs (no reader: the open fails at once) or there is no FIFO.
pub(crate) fn open_router_owner(fifo: &std::path::Path) -> Option<std::fs::File> {
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
    if !std::fs::symlink_metadata(fifo).ok()?.file_type().is_fifo() {
        return None;
    }
    std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(fifo).ok()
}

/// How long the shutdown path waits for a router it started to exit after
/// `shutdown`, before it kills that child.
const ROUTER_STOP_BUDGET: Duration = Duration::from_secs(2);

/// Opens the owner FIFO read-write: the daemon is a writer (an owner) and
/// the open never waits for a reader.
fn open_owner_rw(fifo: &std::path::Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::FileTypeExt;
    if !std::fs::symlink_metadata(fifo)?.file_type().is_fifo() {
        return Err(std::io::Error::other("the router owner path is not a FIFO"));
    }
    std::fs::OpenOptions::new().read(true).write(true).open(fifo)
}

impl RouterOwner for FifoOwner {
    fn ensure() -> Option<Self> {
        start_or_adopt()
    }

    fn release(self, stop: bool) {
        let_go(self, stop)
    }
}

/// Start the local router, or adopt the one that runs. A router answers on
/// `<home>/router/router.sock` (a short path for a long home:
/// `cmux_coderouter::admin_socket_path`):
/// - same build: this daemon opens the owner FIFO, then asks `adopt`. The
///   router refuses only when it is already stopping; then a new one starts
///   (it waits on router.lock for the old one).
/// - another build: replaced (`shutdown`, then a new router) only when no
///   kept agent host runs; while one runs, this daemon adopts it too, and a
///   later daemon start replaces it.
fn start_or_adopt() -> Option<FifoOwner> {
    use std::os::unix::process::CommandExt;
    let fifo = router_owner_fifo();
    if let Ok(status) = ask_router(b"{\"op\":\"status\"}\n") {
        let same_build = status.get("build").and_then(Value::as_str) == Some(crate::hub::build());
        let kept_hosts = crate::agent_host::sweep::running_hosts(&crate::agent_host::hosts_dir())
            .iter()
            .any(|host| !host.pooled);
        if same_build || kept_hosts {
            // `stopping`: the router refused because its owners are gone.
            // Anything else that is not `adopted` (no FIFO, a timeout, an
            // older router) is unclear.
            let mut stopping = false;
            if let Ok(owner) = open_owner_rw(&fifo) {
                let answer = ask_router(b"{\"op\":\"adopt\"}\n").ok();
                let flag = |name: &str| {
                    answer.as_ref().and_then(|v| v.get(name)).and_then(Value::as_bool) == Some(true)
                };
                if flag("adopted") {
                    tracing::info!("adopted the running local router");
                    return Some(FifoOwner { _owner: owner, child: None });
                }
                stopping = flag("stopping");
            }
            if kept_hosts && !stopping {
                // Kept agents use it: never replaced on an unclear answer.
                tracing::warn!("the local router could not be adopted; it stays for kept agents");
                return None;
            }
            if !same_build {
                // A router of an older build that cannot be adopted (no
                // owner FIFO) and still serves kept agents: used as it is.
                tracing::warn!("the local router of another build serves kept agents; it stays");
                return None;
            }
        }
        // Another build that no agent uses, or a router that is stopping:
        // the new router waits on router.lock until it has exited.
        let _ = ask_router(b"{\"op\":\"shutdown\"}\n");
    }
    let this = crate::self_command::SelfCommand::current().ok()?;
    let owner = match make_owner_fifo(&fifo).and_then(|()| open_owner_rw(&fifo)) {
        Ok(owner) => owner,
        Err(e) => {
            tracing::warn!("could not start the local router (owner FIFO): {e}");
            return None;
        }
    };
    let mut command = router_command(&this, &fifo);
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // Its own session: a terminal hangup does not stop it; the owner FIFO does.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    match command.spawn() {
        Ok(child) => Some(FifoOwner { _owner: owner, child: Some(child) }),
        Err(e) => {
            tracing::warn!("could not start the local router: {e}");
            None
        }
    }
}

/// The shutdown path. `stop`: no agent of this home is left (none was kept),
/// so the router is told to stop and, when this daemon started it, waited
/// for (`ROUTER_STOP_BUDGET`, then killed: it is unreaped, so the pid is
/// still ours). Either way the daemon's owner end closes; kept agent hosts
/// still hold theirs, so their router keeps serving them.
fn let_go(owner: FifoOwner, stop: bool) {
    use wait_timeout::ChildExt;
    let FifoOwner { _owner: owner, child } = owner;
    // A host this daemon did not reach (adoption failed, or it did not end)
    // still owns the router: then it stays.
    let stop = stop
        && crate::agent_host::sweep::running_hosts(&crate::agent_host::hosts_dir())
            .iter()
            .all(|host| host.pooled);
    if stop {
        let _ = ask_router(b"{\"op\":\"shutdown\"}\n");
    }
    drop(owner);
    let Some(mut child) = child else { return };
    if !stop {
        // Kept agents still use it; its exit is theirs to cause.
        drop(child);
        return;
    }
    if matches!(child.wait_timeout(ROUTER_STOP_BUDGET), Ok(Some(_))) {
        return;
    }
    tracing::warn!(
        "the local router (pid {}) did not stop within {ROUTER_STOP_BUDGET:?}; killing it",
        child.id()
    );
    let _ = child.kill();
    let _ = child.wait_timeout(ROUTER_STOP_BUDGET);
}

/// A fresh owner FIFO (0600) for a new router. An old router still reading
/// the previous FIFO keeps its own inode.
fn make_owner_fifo(fifo: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    if let Some(dir) = fifo.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let _ = std::fs::remove_file(fifo);
    let path = std::ffi::CString::new(fifo.as_os_str().as_bytes())?;
    // SAFETY: a valid NUL-terminated path.
    if unsafe { libc::mkfifo(path.as_ptr(), 0o600) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// `<acpmux> [prefix…] router serve` for this build, owned by `fifo`. Inside
/// cmux-tui the prefix is `acp`: `cmux-tui router serve` is the cmux CLI.
fn router_command(
    this: &crate::self_command::SelfCommand,
    fifo: &std::path::Path,
) -> std::process::Command {
    let mut command = this.command(&["router", "serve"]);
    command.env("CMUX_ROUTER_BUILD", crate::hub::build()).env("CMUX_ROUTER_OWNER_FIFO", fifo);
    command
}

#[cfg(test)]
mod self_command_tests {
    #[test]
    fn the_router_starts_under_the_daemon_prefix() {
        let [standalone, tui] = crate::self_command::test_commands();
        let fifo = std::path::Path::new("/tmp/owner.fifo");
        let args = |c: &std::process::Command| -> Vec<String> {
            c.get_args().map(|a| a.to_string_lossy().into_owned()).collect()
        };
        assert_eq!(args(&super::router_command(&standalone, fifo)), ["router", "serve"]);
        let command = super::router_command(&tui, fifo);
        assert_eq!(command.get_program(), tui.exe.as_os_str());
        assert_eq!(args(&command), ["acp", "router", "serve"]);
    }
}
