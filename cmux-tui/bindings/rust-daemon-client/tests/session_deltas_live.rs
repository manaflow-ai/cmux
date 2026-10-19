//! Raw session deltas against a real cmux-tui daemon (cmux2-0b): with
//! `DaemonConfig::raw_session_deltas`, a sidebar change (a new workspace)
//! arrives as `DaemonEvent::SessionDelta` with the `session.events` delta
//! the stream delivered, just before the typed `DaemonEvent::Delta` of the
//! same revision. A client without the flag gets no `SessionDelta`.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary;
//! without it the test reports the skip and passes.
// The install key reaches the owner only on Unix (cmux-tui local_owner.rs).
#![cfg(unix)]

use cmux_daemon_client::cmux::SessionEvent;
use cmux_daemon_client::launcher::Launcher;
use cmux_daemon_client::{
    AppConnection, Change, DaemonClient, DaemonConfig, DaemonEvent, MirrorChange,
};
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

/// Every event up to the first one `done` accepts, in order.
fn events_until(
    rx: &mpsc::Receiver<DaemonEvent>,
    what: &str,
    mut done: impl FnMut(&DaemonEvent) -> bool,
) -> Vec<DaemonEvent> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut seen = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let event = rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if let DaemonEvent::Disconnected { error, .. } = &event {
            panic!("disconnected while waiting for {what}: {error}");
        }
        let last = done(&event);
        seen.push(event);
        if last {
            return seen;
        }
    }
}

fn adds_a_workspace(event: &DaemonEvent) -> bool {
    matches!(event, DaemonEvent::Delta { changes, .. }
        if changes.iter().any(|c| matches!(c, MirrorChange::Workspace(Change::Added(_)))))
}

fn spawn(config: DaemonConfig) -> (DaemonClient, mpsc::Receiver<DaemonEvent>) {
    let (tx, rx) = mpsc::channel();
    let client = DaemonClient::spawn(config, move |event, _| {
        let _ = tx.send(event.clone());
    })
    .unwrap();
    (client, rx)
}

#[test]
fn a_sidebar_change_arrives_as_its_raw_delta_then_the_typed_delta() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let binary = PathBuf::from(binary);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("dc-sdelta-{}-{}", std::process::id(), nanos % 1_000_000);
    let dir = std::env::temp_dir().join(format!("{session}-dir"));
    let state_dir = dir.join("tui");
    let mut launcher = Launcher::new(binary.clone(), session.clone());
    launcher.state_dir = Some(state_dir.clone());
    let _owner = Owner { launcher, dir };

    let mut on = DaemonConfig::new(session.clone());
    on.binary = Some(binary.clone());
    on.state_dir = Some(state_dir.clone());
    on.raw_session_deltas = true;
    let (mut raw_client, raw_rx) = spawn(on);
    let connected = events_until(&raw_rx, "connect", |e| matches!(e, DaemonEvent::Connected(_)));
    let Some(DaemonEvent::Connected(info)) = connected.last().cloned() else { unreachable!() };
    events_until(&raw_rx, "reset", |e| *e == DaemonEvent::Reset);

    // The same daemon, without the flag (the default).
    let mut off = DaemonConfig::new(session);
    off.binary = Some(binary);
    off.state_dir = Some(state_dir);
    assert!(!off.raw_session_deltas, "raw session deltas are off by default");
    let (mut plain_client, plain_rx) = spawn(off);
    events_until(&plain_rx, "connect", |e| matches!(e, DaemonEvent::Connected(_)));
    events_until(&plain_rx, "reset", |e| *e == DaemonEvent::Reset);

    let key = raw_client.install_key().expect("install key");
    let mut app = AppConnection::connect(&info.socket, Some(&key), TIMEOUT).unwrap();
    let created = app
        .request("workspace.create", json!({"initial_content": "empty"}), Some("dc-sdelta-ws"))
        .unwrap();

    // With the flag: every typed Delta comes right after its SessionDelta,
    // whose frame is the stream's delta of that revision.
    let raw = events_until(&raw_rx, "the new workspace's delta", adds_a_workspace);
    let mut pairs = 0;
    for (index, event) in raw.iter().enumerate() {
        let DaemonEvent::Delta { revision, .. } = event else { continue };
        let before = index.checked_sub(1).map(|i| &raw[i]);
        let Some(DaemonEvent::SessionDelta { revision: raw_revision, frame }) = before else {
            panic!("Delta {revision} did not follow a SessionDelta: {raw:?}; created {created}");
        };
        assert_eq!(raw_revision, revision, "{raw:?}");
        let SessionEvent::Delta(delta) = &**frame else { panic!("not a delta frame: {frame:?}") };
        assert_eq!(delta.revision, *revision, "{frame:?}");
        assert!(!delta.changes.is_empty(), "{frame:?}");
        pairs += 1;
    }
    assert!(pairs > 0, "{raw:?}");

    // Without it: the same change, and nothing new.
    let plain = events_until(&plain_rx, "the new workspace's delta", adds_a_workspace);
    assert!(
        !plain.iter().any(|e| matches!(e, DaemonEvent::SessionDelta { .. })),
        "a client without raw_session_deltas got a SessionDelta: {plain:?}"
    );

    app.close();
    raw_client.stop();
    plain_client.stop();
    events_until(&raw_rx, "stopped", |e| *e == DaemonEvent::Stopped);
    let rest = events_until(&plain_rx, "stopped", |e| *e == DaemonEvent::Stopped);
    assert!(!rest.iter().any(|e| matches!(e, DaemonEvent::SessionDelta { .. })), "{rest:?}");
}
