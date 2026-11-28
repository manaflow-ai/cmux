//! Generic event delivery against a real cmux-tui daemon (page-router-v1,
//! cmux2-0b requirement): with `DaemonConfig::raw_events`, a `subscribe`
//! event this crate has no typed variant for (`tree-changed` after a
//! `workspace.create`) still reaches the client, as `DaemonEvent::Event`
//! with the frame the daemon sent.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary;
//! without it the test reports the skip and passes.
// The install key reaches the owner only on Unix (cmux-tui local_owner.rs).
#![cfg(unix)]

use cmux_daemon_client::launcher::Launcher;
use cmux_daemon_client::{AppConnection, DaemonClient, DaemonConfig, DaemonEvent};
use serde_json::json;
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

#[test]
fn an_event_without_a_typed_variant_reaches_the_client_as_its_frame() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let binary = PathBuf::from(binary);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("dc-raw-{}-{}", std::process::id(), nanos % 1_000_000);
    let dir = std::env::temp_dir().join(format!("{session}-dir"));
    let state_dir = dir.join("tui");
    let mut launcher = Launcher::new(binary.clone(), session.clone());
    launcher.state_dir = Some(state_dir.clone());
    let _owner = Owner { launcher, dir };

    let mut config = DaemonConfig::new(session);
    config.binary = Some(binary);
    config.state_dir = Some(state_dir);
    config.raw_events = true;
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
    let key = client.install_key().expect("install key");
    let mut app = AppConnection::connect(&info.socket, Some(&key), TIMEOUT).unwrap();

    // A tree change: `subscribe` sends `tree-changed`, which has no typed
    // DaemonEvent; it must still arrive, with the daemon's frame.
    let created = app
        .request("workspace.create", json!({"initial_content": "empty"}), Some("dc-raw-ws"))
        .unwrap();
    let event = wait_for(
        &rx,
        "tree-changed as a raw frame",
        |e| matches!(e, DaemonEvent::Event { name, .. } if name == "tree-changed"),
    );
    let DaemonEvent::Event { name, frame } = event else { unreachable!() };
    assert_eq!(frame["event"], json!(name), "{frame}");
    assert!(frame.is_object(), "{frame}; created {created}");

    app.close();
    client.stop();
    wait_for(&rx, "stopped", |e| *e == DaemonEvent::Stopped);
}
