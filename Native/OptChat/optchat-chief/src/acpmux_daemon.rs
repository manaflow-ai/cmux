//! Finding and starting the acpmux daemon, the app's launch contract
//! (`ACPMUX_BIN`, `ACPMUX_HOME`, `ACPMUX_SOCKET`; mux/host/src/acpmux-daemon.ts):
//! when the socket does not answer, `$ACPMUX_BIN daemon run` starts detached
//! in its own process group with its log in `$ACPMUX_HOME/daemon.log`.

use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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

/// Starts the daemon unless the socket answers. Returns the started pid.
pub fn ensure(socket: &Path, log: &dyn Fn(&str)) -> Result<Option<u32>, String> {
    if reachable(socket) {
        return Ok(None);
    }
    let Some(bin) = env("ACPMUX_BIN") else {
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
    let mut child = Command::new(&bin)
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
            return Ok(Some(pid));
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
