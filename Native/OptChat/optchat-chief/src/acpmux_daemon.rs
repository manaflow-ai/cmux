//! Finding and starting the acpmux daemon, the app's launch contract
//! (`ACPMUX_BIN`, `ACPMUX_HOME`, `ACPMUX_SOCKET`; mux/host/src/acpmux-daemon.ts):
//! when the socket does not answer, `$ACPMUX_BIN daemon run` starts detached
//! in its own process group with its log in `$ACPMUX_HOME/daemon.log`.
//!
//! Who starts acpmux (one rule for every host, coordinator 2026-10-06; see
//! [`decide`]): with `OPTCHAT_ACPMUX_SUPERVISED=1` a supervisor owns the daemon
//! (the always-on brain's LaunchAgent), so the host never spawns one and waits
//! for its socket with a bounded backoff. Without it (the app's local Chief)
//! the host starts acpmux when none answers, but never again after it saw a
//! daemon it had reached go away: a quit or End Sessions shut it down on
//! purpose, and a respawn would leave an orphan.

use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::cli::env;

/// `ACPMUX_SOCKET`, else `$ACPMUX_HOME/acpmux.sock`, else `~/.acpmux/acpmux.sock`.
pub fn socket_path() -> PathBuf {
    if let Some(socket) = env("ACPMUX_SOCKET") {
        return socket.into();
    }
    if let Some(home) = env("ACPMUX_HOME") {
        return PathBuf::from(home).join("acpmux.sock");
    }
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    user.join(".acpmux").join("acpmux.sock")
}

/// Whether something accepts connections on the socket.
pub fn reachable(path: &Path) -> bool {
    UnixStream::connect(path).is_ok()
}

/// Who owns the acpmux daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// A supervisor (LaunchAgent) starts and restarts it: never spawn.
    Supervised,
    /// The host starts it when none answers (the app's local Chief).
    Local,
}

/// What to do about the daemon now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// The socket answers.
    Ready,
    /// Start `$ACPMUX_BIN daemon run`.
    Spawn,
    /// Wait for the supervisor's daemon.
    Wait,
    /// A daemon this host reached went away: it was shut down on purpose.
    Refuse,
}

/// `OPTCHAT_ACPMUX_SUPERVISED=1` (set by deploy/brain/install.sh): supervised.
pub fn mode() -> Mode {
    if env("OPTCHAT_ACPMUX_SUPERVISED").as_deref() == Some("1") {
        Mode::Supervised
    } else {
        Mode::Local
    }
}

/// The rule: `reachable` is the socket now, `seen_up` whether this host ever reached a daemon.
pub fn decide(mode: Mode, reachable: bool, seen_up: bool) -> Action {
    match (reachable, mode, seen_up) {
        (true, _, _) => Action::Ready,
        (false, Mode::Supervised, _) => Action::Wait,
        (false, Mode::Local, false) => Action::Spawn,
        (false, Mode::Local, true) => Action::Refuse,
    }
}

/// Whether this process ever reached an acpmux daemon (the local-mode respawn rule).
static SEEN_UP: AtomicBool = AtomicBool::new(false);

/// How long a supervised host waits for the supervisor's daemon in one call;
/// the callers' own link loops retry after that.
const SUPERVISED_WAIT: Duration = Duration::from_secs(30);

/// [`ensure_with`] in this process's mode (`OPTCHAT_ACPMUX_SUPERVISED`).
pub fn ensure(socket: &Path, log: &dyn Fn(&str)) -> Result<Option<u32>, String> {
    let bin = env("ACPMUX_BIN");
    ensure_with(
        socket,
        mode(),
        &SEEN_UP,
        bin.as_deref(),
        SUPERVISED_WAIT,
        log,
    )
}

/// Makes the daemon answer by the rule ([`decide`]): ready, wait (supervised,
/// bounded by `wait`), spawn (local, first time) or refuse. Returns the pid it
/// started, if any.
pub fn ensure_with(
    socket: &Path,
    mode: Mode,
    seen_up: &AtomicBool,
    bin: Option<&str>,
    wait: Duration,
    log: &dyn Fn(&str),
) -> Result<Option<u32>, String> {
    match decide(mode, reachable(socket), seen_up.load(Ordering::SeqCst)) {
        Action::Ready => {
            seen_up.store(true, Ordering::SeqCst);
            Ok(None)
        }
        Action::Wait => {
            await_socket(socket, wait)?;
            seen_up.store(true, Ordering::SeqCst);
            Ok(None)
        }
        Action::Refuse => Err(format!(
            "acpmux at {} was shut down; this host does not start it again",
            socket.display()
        )),
        Action::Spawn => {
            let pid = spawn(socket, bin, log)?;
            seen_up.store(true, Ordering::SeqCst);
            Ok(Some(pid))
        }
    }
}

/// Waits for a supervisor's daemon: a short, growing interval, bounded by `wait`.
fn await_socket(socket: &Path, wait: Duration) -> Result<(), String> {
    let deadline = Instant::now() + wait;
    let mut step = Duration::from_millis(25);
    loop {
        if reachable(socket) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "acpmux (supervised) is not up at {} after {} s",
                socket.display(),
                wait.as_secs_f32()
            ));
        }
        std::thread::sleep(
            step.min(deadline.saturating_duration_since(Instant::now()))
                .max(Duration::from_millis(1)),
        );
        step = (step * 2).min(Duration::from_millis(500));
    }
}

/// Starts `$ACPMUX_BIN daemon run` and waits for its socket (local mode).
fn spawn(socket: &Path, bin: Option<&str>, log: &dyn Fn(&str)) -> Result<u32, String> {
    let Some(bin) = bin else {
        return Err(format!(
            "acpmux is not reachable at {} and ACPMUX_BIN is not set",
            socket.display()
        ));
    };
    let home = env("ACPMUX_HOME").map(PathBuf::from).unwrap_or_else(|| {
        socket
            .parent()
            .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
    });
    std::fs::create_dir_all(&home).map_err(|e| format!("creating {}: {e}", home.display()))?;
    let out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(home.join("daemon.log"))
        .map_err(|e| format!("opening the daemon log: {e}"))?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    let mut child = Command::new(bin)
        .args(["daemon", "run"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", socket)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        // Its own process group, so it outlives the host like the app's start.
        .process_group(0)
        .spawn()
        .map_err(|e| format!("starting {bin}: {e}"))?;
    let pid = child.id();
    log(&format!(
        "started acpmux daemon {bin} (pid {pid}, ACPMUX_HOME {})",
        home.display()
    ));
    // Deviation: acpmux-daemon.ts waits on file-system events of the socket's
    // directory; without a watcher dependency this checks with a short,
    // growing interval, bounded at 30 s, and stops early when the child exits.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut step = Duration::from_millis(10);
    loop {
        if reachable(socket) {
            // Not waited for: it outlives the host (its own process group).
            drop(child);
            return Ok(pid);
        }
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!(
                "acpmux daemon exited before its socket was ready: {status}"
            ));
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "acpmux socket {} not ready after 30 s",
                socket.display()
            ));
        }
        std::thread::sleep(step);
        step = (step * 2).min(Duration::from_millis(250));
    }
}
