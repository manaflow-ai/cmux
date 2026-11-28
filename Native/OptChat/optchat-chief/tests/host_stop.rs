//! E20 (.cmux-scratch/chief-errors/catalog.md): stopping the Chief's brain
//! must stop what it started. SIGTERM (or SIGINT, SIGHUP) to the host ends
//! it with exit 0 after it shut down the acpmux daemon it started, which
//! ends that daemon's agent hosts and their sessions. A daemon the host
//! found running (the app's, a supervisor's) is not its to stop.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

mod real_python;

/// A fake `acpmux`: `daemon run` listens on $ACPMUX_SOCKET and writes its pid;
/// `daemon shutdown` records the call and ends it. The host speaks only to a
/// socket whose server process runs `ACPMUX_BIN` (cx-ggai), so the fake is the
/// Python interpreter's own image, which runs the script `daemon` from its
/// working folder, `$ACPMUX_HOME` (where the host starts it).
fn fake_acpmux(dir: &Path) -> std::path::PathBuf {
    let home = dir.join("acpmux");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(
        home.join("daemon"),
        r#"import os, signal, socket, sys
home = os.environ["ACPMUX_HOME"]
if sys.argv[1:2] == ["run"]:
    barrier = os.environ.get("FAKE_ACPMUX_BARRIER")
    if barrier:
        # Started, not listening yet: the test stops the host in this window.
        open(home + "/forked", "w").write(str(os.getpid()))
        open(barrier).read()
    s = socket.socket(socket.AF_UNIX); s.bind(os.environ["ACPMUX_SOCKET"]); s.listen(16)
    open(home + "/run.pid", "w").write(str(os.getpid()))
    held = []
    while True:
        held.append(s.accept()[0])
elif sys.argv[1:] == ["shutdown", "--end-agents"]:  # the brain ends its agents (cx-qryd0)
    open(home + "/calls", "a").write("shutdown\n")
    os.kill(int(open(home + "/run.pid").read()), signal.SIGTERM)
"#,
    )
    .unwrap();
    real_python::image()
}

/// Running, not a zombie: an orphan whose new parent has not reaped it yet
/// has ended (a container's pid 1 may never reap).
fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => stat
            .rsplit_once(") ")
            .is_none_or(|(_, rest)| !rest.starts_with('Z')),
        Err(_) => true,
    }
}

fn wait_for(what: &str, limit: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + limit;
    while !done() {
        assert!(
            Instant::now() < deadline,
            "{what} did not happen within {limit:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn stop_with(signal: i32) {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let acpmux_home = dir.path().join("acpmux");
    let token = dir.path().join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    let mut host = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket"])
        .arg(dir.path().join("missing.sock"))
        .arg("--mux-home")
        .arg(&home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env("ACPMUX_BIN", fake_acpmux(dir.path()))
        .env("ACPMUX_HOME", &acpmux_home)
        .env("ACPMUX_SOCKET", acpmux_home.join("acpmux.sock"))
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .env("OPTCHAT_INSPECTOR", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid_file = acpmux_home.join("run.pid");
    wait_for("the host starting acpmux", Duration::from_secs(30), || {
        std::fs::read_to_string(&pid_file).is_ok_and(|p| !p.is_empty())
    });
    let acpmux: i32 = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: the pid is our own child.
    unsafe { libc::kill(host.id() as i32, signal) };
    let mut status = None;
    wait_for("the host exiting", Duration::from_secs(10), || {
        status = host.try_wait().unwrap();
        status.is_some()
    });
    assert_eq!(status.unwrap().code(), Some(0), "a stop on request exits 0");
    assert_eq!(
        std::fs::read_to_string(acpmux_home.join("calls")).unwrap_or_default(),
        "shutdown\n",
        "the host shuts down the acpmux daemon it started"
    );
    wait_for("the acpmux daemon ending", Duration::from_secs(5), || {
        !alive(acpmux)
    });
}

#[test]
fn sigterm_stops_the_host_and_the_acpmux_daemon_it_started() {
    stop_with(libc::SIGTERM);
}

#[test]
fn sigint_and_sighup_stop_it_the_same_way() {
    stop_with(libc::SIGINT);
    stop_with(libc::SIGHUP);
}

#[test]
fn an_acpmux_daemon_the_host_found_running_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let acpmux_home = dir.path().join("acpmux");
    std::fs::create_dir_all(&acpmux_home).unwrap();
    let bin = fake_acpmux(dir.path());
    let socket = acpmux_home.join("acpmux.sock");
    let mut theirs = Command::new(&bin)
        .args(["daemon", "run"])
        .current_dir(&acpmux_home)
        .env("ACPMUX_HOME", &acpmux_home)
        .env("ACPMUX_SOCKET", &socket)
        .spawn()
        .unwrap();
    wait_for(
        "the other daemon listening",
        Duration::from_secs(10),
        || socket.exists(),
    );
    let token = dir.path().join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    let mut host = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket"])
        .arg(dir.path().join("missing.sock"))
        .arg("--mux-home")
        .arg(&home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env("ACPMUX_BIN", &bin)
        .env("ACPMUX_HOME", &acpmux_home)
        .env("ACPMUX_SOCKET", &socket)
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .env("OPTCHAT_INSPECTOR", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_secs(2));
    // SAFETY: the pid is our own child.
    unsafe { libc::kill(host.id() as i32, libc::SIGTERM) };
    let mut status = None;
    wait_for("the host exiting", Duration::from_secs(10), || {
        status = host.try_wait().unwrap();
        status.is_some()
    });
    assert_eq!(status.unwrap().code(), Some(0));
    assert!(
        !acpmux_home.join("calls").exists(),
        "not its daemon: no shutdown"
    );
    assert!(
        theirs.try_wait().unwrap().is_none(),
        "the other daemon still runs"
    );
    let _ = theirs.kill();
    let _ = theirs.wait();
}

/// cx-33c6: a stop signal that arrives after the host started acpmux but
/// before acpmux listened (the host has not recorded it yet) still shuts
/// that daemon down. The fake daemon holds in that window on a FIFO until
/// the test has signalled the host, so the order is fixed, not timed.
#[test]
fn a_sigterm_while_acpmux_starts_still_stops_it() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let acpmux_home = dir.path().join("acpmux");
    let token = dir.path().join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    let barrier = dir.path().join("barrier");
    let path = std::ffi::CString::new(barrier.to_str().unwrap()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0, "mkfifo");
    let stderr = dir.path().join("host.stderr");
    let mut host = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket"])
        .arg(dir.path().join("missing.sock"))
        .arg("--mux-home")
        .arg(&home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env("ACPMUX_BIN", fake_acpmux(dir.path()))
        .env("ACPMUX_HOME", &acpmux_home)
        .env("ACPMUX_SOCKET", acpmux_home.join("acpmux.sock"))
        .env("FAKE_ACPMUX_BARRIER", &barrier)
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .env("OPTCHAT_INSPECTOR", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(&stderr).unwrap())
        .spawn()
        .unwrap();
    // Whatever happens below, nothing of this test stays running.
    let mut guard = Leftovers(vec![host.id() as i32]);
    let forked = acpmux_home.join("forked");
    wait_for("the host starting acpmux", Duration::from_secs(30), || {
        std::fs::read_to_string(&forked).is_ok_and(|p| !p.is_empty())
    });
    let acpmux: i32 = std::fs::read_to_string(&forked)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    guard.0.push(acpmux);
    // SAFETY: the pid is our own child.
    unsafe { libc::kill(host.id() as i32, libc::SIGTERM) };
    // The host's stop watcher has taken the signal (it logs before it stops)
    // while acpmux still waits: the stop comes inside the start, every time.
    wait_for(
        "the host taking the stop signal",
        Duration::from_secs(10),
        || {
            std::fs::read_to_string(&stderr)
                .is_ok_and(|log| log.contains("stopping before the brain runs"))
        },
    );
    // The daemon goes on: it listens, so the host's start completes.
    std::fs::write(&barrier, "go").unwrap();
    let mut status = None;
    wait_for("the host exiting", Duration::from_secs(40), || {
        status = host.try_wait().unwrap();
        status.is_some()
    });
    // Reaped: its pid is no longer this test's to kill.
    guard.0.retain(|&pid| pid != host.id() as i32);
    let calls = std::fs::read_to_string(acpmux_home.join("calls")).unwrap_or_default();
    let ended = {
        let deadline = Instant::now() + Duration::from_secs(5);
        while alive(acpmux) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50)); // test harness: poll for the daemon's exit
        }
        !alive(acpmux)
    };
    drop(guard);
    assert_eq!(status.unwrap().code(), Some(0), "a stop on request exits 0");
    assert_eq!(
        calls, "shutdown\n",
        "the host shuts down the acpmux it was starting"
    );
    assert!(ended, "no acpmux of this host is left running");
}

/// Kills the given pids (this test's host and fake acpmux) when dropped, also
/// when an assertion fails.
struct Leftovers(Vec<i32>);

impl Drop for Leftovers {
    fn drop(&mut self) {
        for &pid in &self.0 {
            // SAFETY: pids this test started; a dead one returns ESRCH.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
}
