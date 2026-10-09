//! The supervised plugin must not outlive the daemon that started it.
//!
//! A `kill -9` of the daemon skips the supervisor's process-group shutdown, so
//! without a host watch the scanner reconnects forever and a later daemon on
//! the same socket gets a duplicate scanner.
#![cfg(unix)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const EXIT_DEADLINE: Duration = Duration::from_secs(5);

/// Kills and reaps the child on every path, including a failed assertion.
struct Reaped(Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn missing_socket_path() -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or_default();
    std::env::temp_dir().join(format!(
        "cmux-host-exit-{}-{nanos}/missing.sock",
        std::process::id()
    ))
}

#[test]
fn plugin_exits_when_the_host_pid_exits() {
    let mut host = Reaped(
        Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn fake host"),
    );
    let host_pid = host.0.id();
    let socket = missing_socket_path();
    assert!(!socket.exists(), "test socket path must not exist");

    let mut plugin = Reaped(
        Command::new(env!("CARGO_BIN_EXE_cmux-agent-screen-detection"))
            .env("CMUX_TUI_SOCKET", &socket)
            .env("CMUX_PLUGIN_ID", "screen_detector")
            .env("CMUX_PLUGIN_HOST_PID", host_pid.to_string())
            .env_remove("CMUX_PLUGIN_GENERATION")
            .env_remove("CMUX_TUI_SESSION_ID")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn plugin"),
    );

    // The plugin keeps reconnecting while its host is alive.
    thread::sleep(Duration::from_millis(500));
    assert!(
        plugin.0.try_wait().expect("poll plugin").is_none(),
        "plugin exited while its host was still alive"
    );

    host.0.kill().expect("kill fake host");
    host.0.wait().expect("reap fake host");

    let deadline = Instant::now() + EXIT_DEADLINE;
    let status = loop {
        if let Some(status) = plugin.0.try_wait().expect("poll plugin") {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        thread::sleep(Duration::from_millis(50));
    };
    let status = status.unwrap_or_else(|| {
        panic!("plugin was still running {EXIT_DEADLINE:?} after host pid {host_pid} exited")
    });
    assert!(status.success(), "plugin exit status after host exit: {status}");
}
