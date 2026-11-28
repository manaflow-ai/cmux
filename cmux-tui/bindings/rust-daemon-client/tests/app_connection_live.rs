//! The verified app connection against a real cmux-tui daemon: the client
//! starts the owner with its install key (`server ensure
//! --install-key-stdin`), an `AppConnection` that proves the key gets origin
//! `user` and `history.visit.record` is accepted, while a connection with no
//! hello or with another key is refused (`origin.forbidden`), and the
//! visit reaches the client as `DaemonEvent::HistoryChanged`.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// The install key reaches the owner only on Unix (cmux-tui local_owner.rs).
#![cfg(unix)]

use cmux_daemon_client::cmux;
use cmux_daemon_client::launcher::Launcher;
use cmux_daemon_client::{AppConnection, DaemonClient, DaemonConfig, DaemonEvent, InstallKey};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const TIMEOUT: Duration = Duration::from_secs(10);

/// Stops the owner this test started and removes its state, even on panic.
struct Owner {
    launcher: Launcher,
    dir: PathBuf,
}

impl Drop for Owner {
    fn drop(&mut self) {
        if let Err(e) = self.launcher.stop(true) {
            eprintln!("server stop for {}: {e}", self.launcher.session);
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(
    rx: &mpsc::Receiver<DaemonEvent>,
    what: &str,
    mut done: impl FnMut(&DaemonEvent) -> bool,
) -> DaemonEvent {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let event = rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if let DaemonEvent::Disconnected { error, .. } = &event {
            panic!("disconnected while waiting for {what}: {error}");
        }
        if done(&event) {
            return event;
        }
    }
}

fn record(
    connection: &mut AppConnection,
    url: &str,
    key: &str,
) -> cmux::raw::Result<serde_json::Value> {
    let at_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis().to_string();
    let params = json!({"profile": "default", "url": url, "at_ms": at_ms, "title": "Example"});
    connection.request("history.visit.record", params, Some(key))
}

#[test]
fn verified_app_connection_records_visits_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let binary = PathBuf::from(binary);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("dc-hello-{}-{}", std::process::id(), nanos % 1_000_000);
    let dir = std::env::temp_dir().join(format!("{session}-dir"));
    let state_dir = dir.join("tui");
    let mut launcher = Launcher::new(binary.clone(), session.clone());
    launcher.state_dir = Some(state_dir.clone());
    let _owner = Owner { launcher, dir };

    let mut config = DaemonConfig::new(session);
    config.binary = Some(binary);
    config.state_dir = Some(state_dir.clone());
    let (tx, rx) = mpsc::channel();
    let mut client = DaemonClient::spawn(config, move |event, _| {
        let _ = tx.send(event.clone());
    })
    .unwrap();
    let DaemonEvent::Connected(info) =
        wait_for(&rx, "connect", |e| matches!(e, DaemonEvent::Connected(_)))
    else {
        unreachable!()
    };
    assert!(info.started, "a fresh session must start its owner");
    assert!(info.capabilities.iter().any(|c| c == cmux_daemon_client::HISTORY_CAPABILITY));
    assert!(info.verified_app, "the owner started with the key must accept its proof");

    // cmux-next's file: <state dir>/frontend-install-key, 0600.
    let file = InstallKey::file_in(&state_dir);
    let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let key = client.install_key().expect("install key");
    assert_eq!(InstallKey::load_or_create(&file).as_ref(), Some(&key));

    // No hello: origin agent, refused.
    let mut plain = AppConnection::connect(&info.socket, None, TIMEOUT).unwrap();
    assert!(!plain.verified());
    let refused = record(&mut plain, "https://example.com/plain", "dc-hello-plain").unwrap_err();
    assert_eq!(refused.error_code(), Some("origin.forbidden"), "{refused}");

    // Another key: the proof is refused, origin agent, refused.
    let other = InstallKey::generate().unwrap();
    let mut forged = AppConnection::connect(&info.socket, Some(&other), TIMEOUT).unwrap();
    assert!(!forged.verified());
    let refused = record(&mut forged, "https://example.com/forged", "dc-hello-forged").unwrap_err();
    assert_eq!(refused.error_code(), Some("origin.forbidden"), "{refused}");

    // The app's key: verified, origin user, accepted, and reported.
    let mut app = AppConnection::connect(&info.socket, Some(&key), TIMEOUT).unwrap();
    assert!(app.verified());
    record(&mut app, "https://example.com/visited", "dc-hello-app").unwrap();
    let DaemonEvent::HistoryChanged { kinds, history_revision } =
        wait_for(&rx, "history-changed", |e| matches!(e, DaemonEvent::HistoryChanged { .. }))
    else {
        unreachable!()
    };
    assert!(kinds.iter().any(|k| k == "page"), "{kinds:?}");
    assert!(history_revision > 0);
    let listed = app.request("history.entries.list", json!({"profile": "default"}), None).unwrap();
    assert!(listed.to_string().contains("https://example.com/visited"), "{listed}");
    assert!(!listed.to_string().contains("https://example.com/forged"), "{listed}");

    plain.close();
    forged.close();
    app.close();
    client.stop();
    wait_for(&rx, "stopped", |e| *e == DaemonEvent::Stopped);
}
