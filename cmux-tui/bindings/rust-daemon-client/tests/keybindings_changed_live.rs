//! `keybindings-changed` against a real cmux-tui daemon: a verified app
//! connection sets a binding with `keybindings.set` (the writer's origin), and a
//! hand edit of keybindings.json reaches the daemon's file watcher (origin
//! `file`); both reach the client as `DaemonEvent::KeybindingsChanged`, and
//! `keybindings.get` reads the new entries.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary and
//! `CMUX_NEXT_CONFIG_FILE` names a settings file in the temp directory (the
//! daemon keeps keybindings.json beside it). Without both the test reports
//! the skip and passes, so it never edits the user's own keybindings.json.
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

fn changed(event: &DaemonEvent) -> (String, u64) {
    match event {
        DaemonEvent::KeybindingsChanged { origin, keybindings_revision } => {
            (origin.clone(), *keybindings_revision)
        }
        other => unreachable!("{other:?}"),
    }
}

#[test]
fn keybindings_changed_reaches_the_client_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let Some(config_file) = std::env::var_os("CMUX_NEXT_CONFIG_FILE").map(PathBuf::from) else {
        eprintln!("skipped: set CMUX_NEXT_CONFIG_FILE to a settings file in the temp directory");
        return;
    };
    let temp = std::env::temp_dir().canonicalize().unwrap();
    let config_dir = config_file.parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&config_dir).unwrap();
    assert!(
        config_dir.canonicalize().unwrap().starts_with(&temp),
        "CMUX_NEXT_CONFIG_FILE must be in {}: this test writes keybindings.json beside it",
        temp.display()
    );
    let keybindings = config_dir.join("keybindings.json");
    std::fs::write(&keybindings, "[]\n").unwrap();

    let binary = PathBuf::from(binary);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let session = format!("dc-keys-{}-{}", std::process::id(), nanos % 1_000_000);
    let dir = std::env::temp_dir().join(format!("{session}-dir"));
    let state_dir = dir.join("tui");
    let mut launcher = Launcher::new(binary.clone(), session.clone());
    launcher.state_dir = Some(state_dir.clone());
    let _owner = Owner { launcher, dir };

    let mut config = DaemonConfig::new(session);
    config.binary = Some(binary);
    config.state_dir = Some(state_dir);
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
    assert!(info.capabilities.iter().any(|c| c == cmux_daemon_client::KEYBINDINGS_CAPABILITY));
    let key = client.install_key().expect("install key");
    let mut app = AppConnection::connect(&info.socket, Some(&key), TIMEOUT).unwrap();
    assert!(app.verified());

    let file = app.request("keybindings.get", json!({}), None).unwrap();
    assert_eq!(
        PathBuf::from(file["path"].as_str().unwrap()).canonicalize().unwrap(),
        keybindings.canonicalize().unwrap(),
        "{file}"
    );

    // A write through the owner: the writer's origin (not a hand edit).
    let set = json!({"command": "workbench.action.showCommands", "key": "ctrl+k ctrl+p"});
    app.request("keybindings.set", set, Some("dc-keys-set")).unwrap();
    let event = wait_for(&rx, "keybindings-changed (set)", |e| {
        matches!(e, DaemonEvent::KeybindingsChanged { .. })
    });
    let (origin, set_revision) = changed(&event);
    assert!(!origin.is_empty() && origin != "file", "{origin}");
    assert!(set_revision > 0);
    let file = app.request("keybindings.get", json!({}), None).unwrap();
    assert!(file.to_string().contains("workbench.action.showCommands"), "{file}");

    // A hand edit: the daemon's watcher, origin file.
    std::fs::write(&keybindings, r#"[{"key": "ctrl+alt+n", "command": "-workspace.new"}]"#)
        .unwrap();
    let event = wait_for(
        &rx,
        "keybindings-changed (hand edit)",
        |e| matches!(e, DaemonEvent::KeybindingsChanged { origin, .. } if origin == "file"),
    );
    let (_, edit_revision) = changed(&event);
    assert!(edit_revision > set_revision, "{edit_revision} after {set_revision}");
    let file = app.request("keybindings.get", json!({}), None).unwrap();
    assert!(file.to_string().contains("workspace.new"), "{file}");
    assert!(!file.to_string().contains("workbench.action.showCommands"), "{file}");

    app.close();
    client.stop();
    wait_for(&rx, "stopped", |e| *e == DaemonEvent::Stopped);
}
