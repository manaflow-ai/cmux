//! Starts the pinned cmux-tui in a private session, follows it with
//! `DaemonClient`, mutates it through the SDK, and checks the mirror.
//!
//! Ignored by default (needs the binary: scripts/fetch-cmux-tui.sh or
//! CMUX2_TUI_BIN). Run: cargo test -p cmux-daemon-client -- --ignored

use cmux_daemon_client::cmux;
use cmux_daemon_client::launcher::{self, Launcher};
use cmux_daemon_client::{DaemonClient, DaemonConfig, DaemonEvent, Mirror};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Stops the daemon this test started and removes its state, even on panic.
struct Owner {
    launcher: Launcher,
    state_dir: PathBuf,
    socket: Option<PathBuf>,
}

impl Drop for Owner {
    fn drop(&mut self) {
        match self.launcher.stop(true) {
            Ok(_) => {}
            Err(e) => eprintln!("server stop for {}: {e}", self.launcher.session),
        }
        let _ = std::fs::remove_dir_all(&self.state_dir);
        // The owner leaves `<socket>.spawn-lock` in the runtime dir.
        if let Some(socket) = &self.socket {
            let mut lock = socket.clone().into_os_string();
            lock.push(".spawn-lock");
            let _ = std::fs::remove_file(lock);
            let _ = std::fs::remove_file(socket);
        }
    }
}

#[derive(Debug)]
struct Seen {
    event: DaemonEvent,
    workspaces: Vec<String>,
    mirror: Mirror,
}

fn wait_for(rx: &mpsc::Receiver<Seen>, what: &str, mut done: impl FnMut(&Seen) -> bool) -> Seen {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let seen = rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if let DaemonEvent::Disconnected { error, .. } = &seen.event {
            // Known at the pinned commit: the daemon sends a terminal whose
            // last tab closed without `lifecycle`, the SDK rejects it, and
            // the client resyncs from a fresh snapshot. Anything else fails.
            assert!(
                error.contains("missing field `lifecycle`"),
                "disconnected while waiting for {what}: {error}"
            );
            eprintln!("known SDK decode gap, client resyncs: {error}");
            continue;
        }
        if done(&seen) {
            return seen;
        }
    }
}

#[test]
#[ignore = "starts the pinned cmux-tui binary"]
fn mirror_follows_sdk_mutations() {
    let binary = launcher::resolve_binary().expect("cmux-tui binary");
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("cmux2-it-{}-{}", std::process::id(), nanos % 1_000_000);
    let state_dir = std::env::temp_dir().join(format!("{session}-state"));
    let mut launcher = Launcher::new(binary.clone(), session.clone());
    launcher.state_dir = Some(state_dir.clone());
    let mut owner = Owner { launcher, state_dir: state_dir.clone(), socket: None };

    let mut config = DaemonConfig::new(session);
    config.binary = Some(binary);
    config.state_dir = Some(state_dir);
    config.client_name = "cmux2-it".into();
    let (tx, rx) = mpsc::channel();
    let mut client = DaemonClient::spawn(config, move |event, mirror| {
        let workspaces = mirror.workspaces_ordered().iter().map(|w| w.name.clone()).collect();
        let _ = tx.send(Seen { event: event.clone(), workspaces, mirror: mirror.clone() });
    })
    .unwrap();

    let connected = wait_for(&rx, "connect", |s| matches!(s.event, DaemonEvent::Connected(_)));
    let DaemonEvent::Connected(info) = connected.event else { unreachable!() };
    owner.socket = Some(info.socket.clone());
    assert!(info.started, "a fresh session must start its owner");
    assert_eq!(info.build_commit.as_deref(), Some(launcher::pinned_commit()));
    let reset = wait_for(&rx, "reset", |s| s.event == DaemonEvent::Reset);
    assert!(reset.workspaces.is_empty());
    let me = info.client_id.clone().expect("client id");
    assert_eq!(reset.mirror.clients[&me].name.as_deref(), Some("cmux2-it"));
    assert_eq!(reset.mirror.clients[&me].client_kind.as_deref(), Some("frontend"));

    // Mutate through a separate SDK connection, as another client would.
    let sdk = cmux::Client::connect(
        cmux::Config::from_socket_path(&info.socket).with_timeout(Duration::from_secs(5)),
    )
    .unwrap();
    let session_handle = sdk.current_session();
    let created = session_handle.create_workspace(Some("it-alpha".into())).unwrap();
    let seen = wait_for(&rx, "it-alpha", |s| s.workspaces == ["it-alpha"]);
    let ws_id = created.resource.id().cloned().expect("created workspace id");
    let mirror = seen.mirror;
    let screens = mirror.screens_of(&ws_id);
    assert_eq!(screens.len(), 1);
    let panes = mirror.panes_of(&screens[0].id);
    assert_eq!(panes.len(), 1);
    assert_eq!(mirror.tabs_of(&panes[0].id).len(), 1);

    created.resource.rename("it-beta").unwrap();
    wait_for(&rx, "rename", |s| s.workspaces == ["it-beta"]);
    created.resource.close().unwrap();
    let closed = wait_for(&rx, "close", |s| s.workspaces.is_empty());
    assert!(closed.mirror.screens.is_empty() && closed.mirror.tabs.is_empty());
    sdk.close().unwrap();

    client.stop();
    wait_for(&rx, "stopped", |s| s.event == DaemonEvent::Stopped);
    drop(owner);
}
