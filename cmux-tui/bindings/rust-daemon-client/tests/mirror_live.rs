//! `DaemonClient` against a real cmux-tui daemon: the mirror keeps a tab
//! group created through the SDK (MirrorChange::TabGroup), and a bookmark
//! write is reported as DaemonEvent::BookmarksChanged.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux_daemon_client::cmux;
use cmux_daemon_client::{Change, DaemonClient, DaemonConfig, DaemonEvent, Mirror, MirrorChange};
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
    let dir = std::env::temp_dir().join(format!("cmux-daemon-client-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "daemon-client-live", "--socket"])
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
    rx: &mpsc::Receiver<(DaemonEvent, Mirror)>,
    what: &str,
    mut done: impl FnMut(&DaemonEvent, &Mirror) -> bool,
) -> (DaemonEvent, Mirror) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let (event, mirror) =
            rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if let DaemonEvent::Disconnected { error, .. } = &event {
            panic!("disconnected while waiting for {what}: {error}");
        }
        if done(&event, &mirror) {
            return (event, mirror);
        }
    }
}

#[test]
fn mirror_keeps_tab_groups_and_reports_bookmark_changes_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));
    let mut config = DaemonConfig::new("daemon-client-live");
    config.socket = Some(socket.clone());
    let (tx, rx) = mpsc::channel();
    let mut client = DaemonClient::spawn(config, move |event, mirror| {
        let _ = tx.send((event.clone(), mirror.clone()));
    })
    .unwrap();
    let (connected, _) = wait_for(&rx, "connect", |e, _| matches!(e, DaemonEvent::Connected(_)));
    let DaemonEvent::Connected(info) = connected else { unreachable!() };
    assert!(info.capabilities.iter().any(|c| c == cmux_daemon_client::BOOKMARKS_CAPABILITY));
    wait_for(&rx, "reset", |e, _| *e == DaemonEvent::Reset);

    let sdk = cmux::Client::connect(
        cmux::Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10)),
    )
    .unwrap();
    let session = sdk.current_session();
    let created = session.create_workspace(Some("mirror-live".into())).unwrap();
    let tab = created.value.tab_id().unwrap().clone();
    let pane = created.value.pane_id().unwrap().clone();
    let options = cmux::TabGroupCreateOptions {
        name: Some("Mirrored".into()),
        ..cmux::TabGroupCreateOptions::new(vec![tab.clone()])
    };
    let group = session.create_tab_group(options).unwrap().value;
    let (_, mirror) = wait_for(&rx, "tab group", |e, _| match e {
        DaemonEvent::Delta { changes, .. } => {
            changes.iter().any(|c| *c == MirrorChange::TabGroup(Change::Added(group.id.clone())))
        }
        _ => false,
    });
    let mirrored = &mirror.tab_groups[&group.id];
    assert_eq!((mirrored.name.as_str(), mirrored.tab_ids.clone()), ("Mirrored", vec![tab]));
    assert_eq!(mirror.tab_groups_of(&pane).len(), 1);
    session.ungroup_tab_group(&group.id).unwrap();
    wait_for(&rx, "ungroup", |_, m| !m.tab_groups.contains_key(&group.id));

    let raw_config =
        cmux::raw::ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let mut raw = cmux::raw::Client::connect(raw_config).unwrap();
    let created_bookmark = raw
        .create_bookmark(cmux::raw::CreateBookmarkRequest {
            browser_profile_id: "default".into(),
            parent: "bar".into(),
            kind: "folder".into(),
            title: "Mirror".into(),
            index: cmux::raw::Optional::Missing,
            url: cmux::raw::Optional::Missing,
            favicon_key: cmux::raw::Optional::Missing,
            source_key: cmux::raw::Optional::Missing,
            created_ms: cmux::raw::Optional::Missing,
            bookmark: cmux::raw::Optional::Missing,
            origin: cmux::raw::Optional::Missing,
            mutation_id: cmux::raw::Optional::Missing,
        })
        .unwrap();
    assert!(created_bookmark.changed);
    let (changed, _) = wait_for(&rx, "bookmarks-changed", |e, _| {
        matches!(e, DaemonEvent::BookmarksChanged { .. })
    });
    let DaemonEvent::BookmarksChanged { browser_profile_id, bookmarks_revision } = changed else {
        unreachable!()
    };
    assert_eq!(browser_profile_id, "default");
    assert!(bookmarks_revision > 0);
    raw.close();
    sdk.close().unwrap();

    client.stop();
    wait_for(&rx, "stopped", |e, _| *e == DaemonEvent::Stopped);
}
