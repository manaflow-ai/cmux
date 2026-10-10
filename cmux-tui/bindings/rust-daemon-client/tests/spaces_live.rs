//! `DaemonClient` against a real cmux-tui daemon: a space (profile) write
//! is reported as DaemonEvent::PersonalChanged, `list-personal` reads as
//! `Spaces`, and a pinned workspace is in its space only (the membership
//! rule over the daemon's own pins and follows).
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux_daemon_client::cmux;
use cmux_daemon_client::{
    DEFAULT_SPACE, DaemonClient, DaemonConfig, DaemonEvent, Spaces, WorkspaceRef,
};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

struct Daemon {
    child: Child,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_daemon(binary: &Path) -> (Daemon, PathBuf) {
    let dir =
        std::env::temp_dir().join(format!("cmux-daemon-client-spaces-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "daemon-client-spaces", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start cmux-tui");
    let daemon = Daemon { child, dir };
    let deadline = Instant::now() + Duration::from_secs(30);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "cmux-tui did not listen on {socket:?}");
        thread::sleep(Duration::from_millis(50));
    }
    (daemon, socket)
}

fn wait_for(
    rx: &mpsc::Receiver<DaemonEvent>,
    what: &str,
    done: impl Fn(&DaemonEvent) -> bool,
) -> DaemonEvent {
    let deadline = Instant::now() + Duration::from_secs(20);
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
fn space_writes_report_personal_changed_and_list_personal_reads_as_spaces_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));
    let mut config = DaemonConfig::new("daemon-client-spaces");
    config.socket = Some(socket.clone());
    let (tx, rx) = mpsc::channel();
    let mut client = DaemonClient::spawn(config, move |event, _| {
        let _ = tx.send(event.clone());
    })
    .unwrap();
    let connected = wait_for(&rx, "connect", |e| matches!(e, DaemonEvent::Connected(_)));
    let DaemonEvent::Connected(info) = connected else { unreachable!() };
    assert!(info.capabilities.iter().any(|c| c == cmux_daemon_client::PROFILES_CAPABILITY));
    wait_for(&rx, "reset", |e| *e == DaemonEvent::Reset);

    let raw_config =
        cmux::raw::ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let mut raw = cmux::raw::Client::connect(raw_config).unwrap();
    let before =
        Spaces::from_personal(&raw.list_personal(cmux::raw::ListPersonalRequest {}).unwrap())
            .unwrap();
    assert_eq!(before.spaces.first().map(|s| s.id.as_str()), Some(DEFAULT_SPACE));

    raw.create_profile(cmux::raw::CreateProfileRequest {
        name: "Live".into(),
        profile: cmux::raw::Optional::Value("prof_live".into()),
        color: cmux::raw::Optional::Value("green".into()),
        browser_profile_id: cmux::raw::Optional::Missing,
        default_session_id: cmux::raw::Optional::Missing,
        defaults: cmux::raw::Optional::Missing,
        follows: cmux::raw::Optional::Missing,
        icon: cmux::raw::Optional::Missing,
        index: cmux::raw::Optional::Missing,
        theme: cmux::raw::Optional::Missing,
    })
    .unwrap();
    let changed =
        wait_for(&rx, "personal-changed", |e| matches!(e, DaemonEvent::PersonalChanged { .. }));
    let DaemonEvent::PersonalChanged { personal_revision } = changed else { unreachable!() };
    assert!(personal_revision > before.revision);

    let after =
        Spaces::from_personal(&raw.list_personal(cmux::raw::ListPersonalRequest {}).unwrap())
            .unwrap();
    let live = after.space("prof_live").expect("the new space");
    assert_eq!((live.name.as_str(), live.color.as_deref()), ("Live", Some("green")));
    assert_eq!(after.position("prof_live"), Some(after.spaces.len() - 1));

    // Move Workspace to Space (pin-workspace): the pinned workspace is in
    // that space only; another workspace of the same session stays in the
    // spaces that follow the session (default follows the local session).
    let sdk = cmux::Client::connect(
        cmux::Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10)),
    )
    .unwrap();
    sdk.current_session().create_workspace(Some("spaces-live".into())).unwrap();
    let tree = raw
        .request_raw(serde_json::Map::from_iter([(
            "cmd".to_string(),
            serde_json::Value::from("list-workspaces"),
        )]))
        .unwrap();
    let data = &tree["data"];
    let session = data["registry_id"].as_str().expect("registry_id").to_string();
    let first = &data["workspaces"][0];
    // The workspace's stable key (else its id, as cmux-next's
    // `WindowProfiles.qualified`).
    let key = first["key"]
        .as_str()
        .map(str::to_string)
        .or_else(|| {
            first.get("id").map(|id| id.as_str().map_or_else(|| id.to_string(), str::to_string))
        })
        .expect("a workspace key");
    raw.pin_workspace(cmux::raw::PinWorkspaceRequest {
        session_id: session.clone(),
        workspace_key: key.clone(),
        profile: "prof_live".into(),
    })
    .unwrap();
    wait_for(
        &rx,
        "personal-changed after the pin",
        |e| matches!(e, DaemonEvent::PersonalChanged { personal_revision } if *personal_revision > after.revision),
    );
    let pinned =
        Spaces::from_personal(&raw.list_personal(cmux::raw::ListPersonalRequest {}).unwrap())
            .unwrap();
    let workspace = WorkspaceRef { session: session.clone(), key };
    assert_eq!(pinned.spaces_of(&workspace), ["prof_live"]);
    assert!(pinned.closes(&workspace, "prof_live"), "only prof_live shows it");
    let other = WorkspaceRef { session, key: "not-pinned".into() };
    assert_eq!(pinned.spaces_of(&other), [DEFAULT_SPACE]);
    assert!(!pinned.closes(&other, "prof_live"));
    raw.close();
    sdk.close().unwrap();

    client.stop();
    wait_for(&rx, "stopped", |e| *e == DaemonEvent::Stopped);
}
