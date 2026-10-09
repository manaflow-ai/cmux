//! Who starts acpmux (coordinator rule, 2026-10-06): an always-on brain's
//! LaunchAgent supervises it (`OPTCHAT_ACPMUX_SUPERVISED=1`), so the host never
//! spawns one: it waits, with a bounded backoff, for the supervised daemon's
//! socket. In local (app) mode the host starts acpmux when none answers, but
//! never again after it saw a daemon go away (a quit or End Sessions shut it
//! down on purpose; respawning leaves an orphan).

mod exe;

use std::os::unix::net::UnixListener;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use optchat_chief::acpmux_daemon::{Action, Mode, decide, ensure_with};

/// An ACPMUX_BIN that would prove a spawn by writing a marker file.
fn spawn_marker(dir: &std::path::Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let marker = dir.join("spawned");
    let bin = dir.join("fake-acpmux");
    exe::write_executable(
        &bin,
        &format!("#!/bin/sh\ntouch '{}'\nsleep 5\n", marker.display()),
    );
    (bin, marker)
}

#[test]
fn the_rule_in_one_table() {
    assert_eq!(decide(Mode::Supervised, true, false), Action::Ready);
    assert_eq!(decide(Mode::Supervised, false, false), Action::Wait);
    assert_eq!(decide(Mode::Supervised, false, true), Action::Wait);
    assert_eq!(decide(Mode::Local, true, true), Action::Ready);
    assert_eq!(decide(Mode::Local, false, false), Action::Spawn);
    assert_eq!(
        decide(Mode::Local, false, true),
        Action::Refuse,
        "never respawn after a shutdown it saw"
    );
}

#[test]
fn a_supervised_host_never_spawns_and_gives_up_after_its_wait() {
    let dir = tempfile::tempdir().unwrap();
    let (bin, marker) = spawn_marker(dir.path());
    let socket = dir.path().join("acpmux.sock");
    let seen = AtomicBool::new(false);
    let started = Instant::now();
    let r = ensure_with(
        &socket,
        Mode::Supervised,
        &seen,
        Some(bin.to_str().unwrap()),
        Duration::from_millis(300),
        &|_| {},
    );
    assert!(r.is_err());
    assert!(
        started.elapsed() >= Duration::from_millis(300),
        "it waited for the supervisor"
    );
    std::thread::sleep(Duration::from_millis(100));
    assert!(!marker.exists(), "a supervised host never starts acpmux");
}

#[test]
fn a_supervised_host_connects_once_the_supervisor_is_up() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let path = socket.clone();
    let supervisor = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        let listener = UnixListener::bind(&path).unwrap();
        // Accept the readiness probe, then keep the socket alive briefly.
        let _ = listener.accept();
        std::thread::sleep(Duration::from_millis(200));
    });
    let seen = AtomicBool::new(false);
    let r = ensure_with(
        &socket,
        Mode::Supervised,
        &seen,
        None,
        Duration::from_secs(5),
        &|_| {},
    );
    assert_eq!(r, Ok(None), "ready without a spawn");
    supervisor.join().unwrap();
}

#[test]
fn a_local_host_does_not_respawn_a_daemon_it_saw_go_away() {
    let dir = tempfile::tempdir().unwrap();
    let (bin, marker) = spawn_marker(dir.path());
    let socket = dir.path().join("acpmux.sock");
    let seen = AtomicBool::new(true);
    let r = ensure_with(
        &socket,
        Mode::Local,
        &seen,
        Some(bin.to_str().unwrap()),
        Duration::from_secs(1),
        &|_| {},
    );
    assert!(r.unwrap_err().contains("shut down"));
    std::thread::sleep(Duration::from_millis(100));
    assert!(!marker.exists());
}

/// LAUNCH-NO-TCC-PROMPTS: the acpmux daemon a local host starts runs in its
/// acpmux home, never in the host's own folder (the app's `/`, or the home
/// folder), where everything it starts without a folder would read the
/// protected folders (live incident 2026-10-09).
#[test]
fn a_local_host_starts_acpmux_in_its_acpmux_home() {
    let dir = tempfile::tempdir().unwrap();
    let report = dir.path().join("cwd.txt");
    let bin = dir.path().join("fake-acpmux");
    exe::write_executable(
        &bin,
        &format!("#!/bin/sh\n/bin/pwd -P > '{}'\n", report.display()),
    );
    let socket = dir.path().join("acpmux.sock");
    let seen = AtomicBool::new(false);
    // The fake exits without a socket: the start fails, after it ran.
    let _ = ensure_with(
        &socket,
        Mode::Local,
        &seen,
        Some(bin.to_str().unwrap()),
        Duration::from_secs(1),
        &|_| {},
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::fs::read_to_string(&report).map_or(true, |s| s.trim().is_empty())
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(20));
    }
    let cwd = std::fs::read_to_string(&report).unwrap();
    let home = std::env::var("ACPMUX_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| dir.path().to_owned());
    assert_eq!(
        std::path::Path::new(cwd.trim()),
        std::fs::canonicalize(home).unwrap()
    );
}
