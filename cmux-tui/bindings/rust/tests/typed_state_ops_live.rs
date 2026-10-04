//! The typed state calls against a real cmux-tui daemon: `workspace.update`,
//! `tab.pin`/`tab.unpin`/`tab.update`, `column.update`, `window_record.*`,
//! keyed `new-frontend-browser-tab` and `update-frontend-browser-tab`, a
//! protocol/2 error through `request_raw`, and the personal workspace groups
//! (`workspace_group.*`, `workspace.place`, `workspace.placement.list`).
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.

use cmux::raw::{
    ClientConfig, FrontendBrowserEngine, FrontendBrowserTabCreate, FrontendBrowserTabUpdate,
};
use cmux::{
    ColumnEdge, ColumnMode, ColumnUpdateOptions, Config, Direction, Error, LayoutNode,
    SplitOptions, TabUpdateOptions, Update, WorkspaceGroupCreateOptions,
    WorkspaceGroupUpdateOptions, WorkspacePlaceOptions, WorkspaceUpdateOptions,
};
use serde_json::json;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
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

/// A headless daemon in its own state directory; `name` keeps the tests of
/// this binary, which run in parallel, apart.
fn start_daemon(binary: &Path, name: &str) -> (Daemon, PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-sdk-{name}-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", &format!("sdk-{name}"), "--socket"])
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

#[test]
fn typed_state_ops_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary), "state");
    let config = Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let client = cmux::Client::connect(config).unwrap();
    let session = client.current_session();
    let created = session.create_workspace(Some("typed-state".into())).unwrap();
    let path = created.value.clone();
    let workspace = session.workspace(path.workspace_id().clone());

    // workspace.update: the shared identity lands in extra.
    let options = WorkspaceUpdateOptions {
        title: Update::Set("Typed".into()),
        color: Update::Set("#FF8800".into()),
        icon: Update::Unchanged,
    };
    let updated = workspace.update(options).unwrap();
    assert_eq!(updated.value.extra.get("title"), Some(&json!("Typed")), "{:?}", updated.value);
    assert!(updated.value.extra.contains_key("color"), "{:?}", updated.value);
    let cleared = workspace
        .update(WorkspaceUpdateOptions { color: Update::Clear, ..Default::default() })
        .unwrap();
    assert!(!cleared.value.extra.contains_key("color"), "{:?}", cleared.value);

    // tab.pin, tab.unpin, tab.update.
    let screen = workspace.screen(path.screen_id().unwrap().clone());
    let pane = screen.pane(path.pane_id().unwrap().clone());
    let tab = pane.tab(path.tab_id().unwrap().clone());
    assert_eq!(tab.pin().unwrap().value.extra.get("pinned"), Some(&json!(true)));
    let unpinned = tab.unpin().unwrap().value;
    assert_ne!(unpinned.extra.get("pinned"), Some(&json!(true)), "{unpinned:?}");
    let zoomed = tab.update(TabUpdateOptions { zoom: Update::Set(1.5), ..Default::default() });
    assert_eq!(zoomed.unwrap().value.extra.get("zoom"), Some(&json!(1.5)));

    // column.update on a viewport column made by a split with a width.
    let mut split = SplitOptions::new(Direction::Right);
    split.viewport_width = Some(0.5);
    pane.split(split).unwrap();
    let LayoutNode::Viewport(viewport) = screen.refresh().unwrap().layout.root else {
        panic!("a split with viewport_width makes viewport columns");
    };
    assert_eq!(viewport.columns.len(), 2);
    let column = viewport.columns[1].column_id.as_str().to_string();
    screen.update_column(column.clone(), ColumnUpdateOptions::width(0.6)).unwrap();
    let pin = ColumnUpdateOptions::pin(ColumnEdge::Right, ColumnMode::Docked);
    screen.update_column(column.clone(), pin).unwrap();
    // The layout document carries the flag (dock-columns-v1).
    let LayoutNode::Viewport(pinned) = screen.refresh().unwrap().layout.root else {
        panic!("still a viewport");
    };
    let dock = pinned.columns.iter().find(|c| c.column_id.as_str() == column).unwrap().dock;
    assert_eq!(dock.map(|s| (s.edge, s.mode)), Some((ColumnEdge::Right, ColumnMode::Docked)));
    screen.update_column(column, ColumnUpdateOptions::unpin()).unwrap();

    // window_record.*: compare-and-swap on the record's own revision.
    let record = json!({"frame": [10, 20, 800, 600]});
    let put = session.put_window_record("install-live", "w1", record.clone(), Some(0)).unwrap();
    let stored: serde_json::Value = put.value.record.deserialize().unwrap();
    assert_eq!((put.value.owner.as_str(), &stored), ("install-live", &record));
    let stale = session.put_window_record("install-live", "w1", record, Some(0));
    match stale.unwrap_err() {
        Error::Protocol { code, .. } => assert_eq!(code, "revision.conflict"),
        other => panic!("expected revision.conflict, got {other:?}"),
    }
    let rows = session.window_records().unwrap();
    assert!(rows.iter().any(|row| row.id == put.value.id && row.revision == put.value.revision));
    let deleted =
        session.delete_window_record("install-live", "w1", Some(put.value.revision)).unwrap();
    assert_eq!(deleted.value.revision, put.value.revision);
    assert!(session.window_records().unwrap().iter().all(|row| row.id != put.value.id));

    // Keyed frontend browser tab: a retry returns the first tab.
    let raw_config = ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let mut raw = cmux::raw::Client::connect(raw_config).unwrap();
    let mut create =
        FrontendBrowserTabCreate::new("https://cmux.com", FrontendBrowserEngine::Cef, "live-tab-1");
    create.owner = Some("install-live".into());
    let browser_tabs = |session: &cmux::Session| {
        let tabs = session.snapshot().unwrap().tabs;
        tabs.iter().filter(|tab| tab.content_kind == cmux::TabContentKind::Browser).count()
    };
    let before = browser_tabs(&session);
    let first = raw.create_frontend_browser_tab(create.clone()).unwrap();
    let retry = raw.create_frontend_browser_tab(create).unwrap();
    assert_eq!((first.replayed, retry.replayed), (false, true));
    assert_eq!((retry.tab_id.clone(), retry.surface), (first.tab_id.clone(), first.surface));
    assert_eq!(browser_tabs(&session), before + 1, "the keyed retry made no second tab");
    let written = raw
        .write_frontend_browser_tab(FrontendBrowserTabUpdate {
            surface: first.surface,
            url: Some("https://cmux.com/docs".into()),
            title: Some("Docs".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!((written.url.as_str(), written.changed), ("https://cmux.com/docs", true));

    // request_raw keeps the protocol/2 error.
    let envelope = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "live-raw",
        "operation": "window_record.delete", "idempotency_key": "live-raw-delete",
        "params": {"machine": "current", "session": "current", "install_id": "install-live",
                   "window_id": "w1", "expected_revision": "7"}});
    match raw.request_raw(envelope.as_object().unwrap().clone()).unwrap_err() {
        Error::Protocol { code, details, .. } => {
            assert!(
                code == "revision.conflict" || code == "resource.not_found",
                "{code} {details}"
            );
        }
        other => panic!("expected Error::Protocol, got {other:?}"),
    }
    raw.close();
    created.resource.close().unwrap();
}

#[test]
fn workspace_groups_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary), "groups");
    let config = Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let client = cmux::Client::connect(config).unwrap();
    let session = client.current_session();
    let a = session.create_workspace(Some("group-a".into())).unwrap();
    let b = session.create_workspace(Some("group-b".into())).unwrap();
    let a_id = a.value.workspace_id().clone();
    let b_id = b.value.workspace_id().clone();

    // Create two groups; the second goes first.
    let work = WorkspaceGroupCreateOptions {
        color: Some("#225588".into()),
        ..WorkspaceGroupCreateOptions::new("Work")
    };
    let work = session.create_workspace_group(work).unwrap().value;
    assert_eq!(
        (work.name.as_str(), work.color.as_deref(), work.index),
        ("Work", Some("#225588"), 0)
    );
    let play =
        WorkspaceGroupCreateOptions { index: Some(0), ..WorkspaceGroupCreateOptions::new("Play") };
    let play = session.create_workspace_group(play).unwrap().value;
    let names = |session: &cmux::Session| {
        session.workspace_groups().unwrap().into_iter().map(|g| g.name).collect::<Vec<_>>()
    };
    assert_eq!(names(&session), ["Play", "Work"]);

    // Move, rename, recolor, collapse.
    session.move_workspace_group(&work.id, 0).unwrap();
    assert_eq!(names(&session), ["Work", "Play"]);
    let update = WorkspaceGroupUpdateOptions {
        name: Some("Deep work".into()),
        color: Update::Clear,
        collapsed: Some(true),
        room: None,
    };
    let updated = session.update_workspace_group(&work.id, update).unwrap().value;
    assert_eq!(
        (updated.name.as_str(), updated.color, updated.collapsed),
        ("Deep work", None, true)
    );
    let in_room = session.workspace_groups_in_room(work.room_id.clone()).unwrap();
    assert_eq!(in_room.len(), 2);

    // Place b into the group at the top, then a into it after b.
    let into = |group: &str, index| WorkspacePlaceOptions {
        group: Update::Set(group.to_string()),
        index: Some(index),
    };
    let placed = session.workspace(b_id.clone()).place(into(&work.id, 0)).unwrap().value;
    assert_eq!(placed.group_id.as_deref(), Some(work.id.as_str()));
    assert_eq!(placed.workspace.workspace_id.as_ref(), Some(&b_id));
    session.workspace(a_id.clone()).place(into(&work.id, 1)).unwrap();
    let placements = session.workspace_placements().unwrap();
    let position = |id: &cmux::WorkspaceId| {
        placements.iter().find(|p| p.workspace.workspace_id.as_ref() == Some(id)).unwrap()
    };
    assert!(position(&b_id).index < position(&a_id).index, "{placements:?}");
    assert_eq!(position(&a_id).group_id.as_deref(), Some(work.id.as_str()));

    // Ungroup a (keeps its position), then delete the group: b is ungrouped.
    let out = WorkspacePlaceOptions { group: Update::Clear, index: None };
    assert_eq!(session.workspace(a_id).place(out).unwrap().value.group_id, None);
    let deleted = session.delete_workspace_group(&work.id).unwrap().value;
    assert_eq!(deleted.id, work.id);
    assert!(
        deleted.ungrouped.iter().any(|w| w.workspace_id.as_ref() == Some(&b_id)),
        "{deleted:?}"
    );
    assert_eq!(names(&session), ["Play"]);
    assert!(session.workspace_placements().unwrap().iter().all(|p| p.group_id.is_none()));

    // An unknown group is a typed protocol error.
    match session.delete_workspace_group(&work.id).unwrap_err() {
        Error::Protocol { code, .. } => assert_eq!(code, "resource.not_found"),
        other => panic!("expected resource.not_found, got {other:?}"),
    }
    session.delete_workspace_group(&play.id).unwrap();
    a.resource.close().unwrap();
    b.resource.close().unwrap();
}
