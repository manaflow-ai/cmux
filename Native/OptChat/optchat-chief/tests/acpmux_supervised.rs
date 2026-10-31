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

/// An update hands the Chief to a new host while the old host's acpmux
/// daemon still stops and holds `daemon.lock`, so the daemon the new host
/// starts exits at once (75, "another acpmux daemon holds ..."). The new
/// host starts acpmux again until the old daemon lets the lock go. Before,
/// it exited; with the watch's restarts that was three exits in a minute,
/// and the Chief stayed silent until the next ask (2026-10-20).
#[test]
fn a_local_host_starts_acpmux_once_a_stopping_daemon_lets_its_lock_go() {
    use std::sync::Mutex;
    // It starts a daemon in the daemon home: never a real home's.
    if std::env::var_os("ACPMUX_HOME").is_some() || std::env::var_os("ACPMUX_SOCKET").is_some() {
        eprintln!("skipped: ACPMUX_HOME or ACPMUX_SOCKET is set");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let held = dir.path().join("held");
    let attempts = dir.path().join("attempts");
    let started = dir.path().join("started");
    let bin = dir.path().join("fake-acpmux");
    // As acpmux: it exits 75 while another daemon holds the lock (`held`
    // stands for it); once it is free, it runs and the test binds its socket.
    exe::write_executable(
        &bin,
        &format!(
            "#!/bin/sh\necho run >> '{attempts}'\nif [ -e '{held}' ]; then exit 75; fi\ntouch '{started}'\nsleep 5\n",
            attempts = attempts.display(),
            held = held.display(),
            started = started.display()
        ),
    );
    std::fs::write(&held, "").unwrap();
    let socket = dir.path().join("acpmux.sock");
    let (path, attempts_seen, started_seen, held_marker) = (
        socket.clone(),
        attempts.clone(),
        started.clone(),
        held.clone(),
    );
    let old_daemon = std::thread::spawn(move || {
        let wait_for = |file: &std::path::Path| {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !file.exists() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            file.exists()
        };
        assert!(wait_for(&attempts_seen), "the first start ran");
        // The old daemon ends a moment after the first start failed.
        std::thread::sleep(Duration::from_millis(300));
        std::fs::remove_file(&held_marker).unwrap();
        if !wait_for(&started_seen) {
            return;
        }
        let listener = UnixListener::bind(&path).unwrap();
        let _ = listener.accept();
        std::thread::sleep(Duration::from_millis(200));
    });
    let logs = Mutex::new(Vec::<String>::new());
    let seen = AtomicBool::new(false);
    let r = ensure_with(
        &socket,
        Mode::Local,
        &seen,
        Some(bin.to_str().unwrap()),
        Duration::from_secs(1),
        &|message| logs.lock().unwrap().push(message.to_owned()),
    );
    old_daemon.join().unwrap();
    assert!(
        matches!(r, Ok(Some(_))),
        "started once the lock was free: {r:?}"
    );
    assert!(started.exists(), "it started acpmux again");
    assert!(
        logs.lock()
            .unwrap()
            .iter()
            .any(|m| m.contains("waiting for it to stop")),
        "it waited for the old daemon: {:?}",
        logs.lock().unwrap()
    );
    let runs = std::fs::read_to_string(&attempts).unwrap().lines().count();
    assert!(runs >= 2, "it started acpmux again after a refusal: {runs}");
}

/// Another starter can bring up the daemon while this host's starts find
/// daemon.lock held. The host adopts its socket without owning a daemon.
#[test]
fn a_local_host_adopts_a_daemon_that_answers_while_holding_its_lock() {
    use std::sync::{atomic::Ordering, mpsc};

    if std::env::var_os("ACPMUX_HOME").is_some() || std::env::var_os("ACPMUX_SOCKET").is_some() {
        eprintln!("skipped: ACPMUX_HOME or ACPMUX_SOCKET is set");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let attempts = dir.path().join("attempts");
    let give_up = dir.path().join("give-up");
    let bin = dir.path().join("fake-acpmux");
    // Every start finds the lock held, until the test ends a broken host's
    // wait with a plain failure.
    exe::write_executable(
        &bin,
        &format!(
            "#!/bin/sh\necho run >> '{}'\nif [ -e '{}' ]; then exit 1; fi\nexit 75\n",
            attempts.display(),
            give_up.display()
        ),
    );
    let socket = dir.path().join("acpmux.sock");
    let path = socket.clone();
    let (waiting_tx, waiting_rx) = mpsc::channel();
    let (result_tx, result_rx) = mpsc::channel();
    let host = std::thread::spawn(move || {
        let seen = AtomicBool::new(false);
        let result = ensure_with(
            &path,
            Mode::Local,
            &seen,
            Some(bin.to_str().unwrap()),
            Duration::from_secs(1),
            &|message| {
                if message.contains("waiting for it to stop") {
                    let _ = waiting_tx.send(());
                }
            },
        );
        result_tx
            .send((result, seen.load(Ordering::SeqCst)))
            .unwrap();
    });
    waiting_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    // The daemon that answers holds the lock, as acpmux records it: a start
    // still running when it answers is never counted as the host's own.
    std::fs::write(
        dir.path().join("daemon.lock"),
        format!("{}\n{}\n", std::process::id(), socket.display()),
    )
    .unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let result = result_rx.recv_timeout(Duration::from_secs(5));
    // End a broken host's starts before joining, so it finishes without
    // waiting out its full startup limit.
    std::fs::write(&give_up, "").unwrap();
    host.join().unwrap();
    drop(listener);
    assert_eq!(
        result.unwrap(),
        (Ok(None), true),
        "adopted without owning a daemon"
    );
    assert!(std::fs::read_to_string(attempts).unwrap().lines().count() >= 1);
}

/// Another starter's daemon can answer while this host's own start, refused
/// the lock, has not exited yet. The socket is that daemon's (daemon.lock
/// names its pid), so the host adopts it and never records the refused start
/// as a daemon it owns (and would later stop).
#[test]
fn a_local_host_never_counts_another_daemon_answering_before_its_start_exits() {
    use std::sync::{atomic::Ordering, mpsc};

    if std::env::var_os("ACPMUX_HOME").is_some() || std::env::var_os("ACPMUX_SOCKET").is_some() {
        eprintln!("skipped: ACPMUX_HOME or ACPMUX_SOCKET is set");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let spawned = dir.path().join("spawned");
    let bin = dir.path().join("fake-acpmux");
    // As acpmux refused the lock, slowly: it runs a moment, then exits 75.
    exe::write_executable(
        &bin,
        &format!(
            "#!/bin/sh\ntouch '{}'\nsleep 1\nexit 75\n",
            spawned.display()
        ),
    );
    let socket = dir.path().join("acpmux.sock");
    let path = socket.clone();
    let (result_tx, result_rx) = mpsc::channel();
    let host = std::thread::spawn(move || {
        let seen = AtomicBool::new(false);
        let result = ensure_with(
            &path,
            Mode::Local,
            &seen,
            Some(bin.to_str().unwrap()),
            Duration::from_secs(1),
            &|_| {},
        );
        result_tx
            .send((result.map(|pid| pid.is_some()), seen.load(Ordering::SeqCst)))
            .unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while !spawned.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(spawned.exists(), "the host started acpmux");
    // The other daemon holds the lock (its pid is this live test process)
    // and serves the socket while the host's start is still running.
    std::fs::write(
        dir.path().join("daemon.lock"),
        format!("{}\n{}\n", std::process::id(), socket.display()),
    )
    .unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let result = result_rx.recv_timeout(Duration::from_secs(10));
    host.join().unwrap();
    drop(listener);
    assert_eq!(
        result.unwrap(),
        (Ok(false), true),
        "adopted the other daemon, owning none"
    );
}
