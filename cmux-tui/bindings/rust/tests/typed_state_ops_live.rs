//! The typed state calls against a real cmux-tui daemon: `workspace.update`,
//! `tab.pin`/`tab.unpin`/`tab.update`, `column.update`, `window_record.*`,
//! keyed `new-frontend-browser-tab` and `update-frontend-browser-tab`, and a
//! protocol/2 error through `request_raw`.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.

use cmux::raw::{
    ClientConfig, FrontendBrowserEngine, FrontendBrowserTabCreate, FrontendBrowserTabUpdate,
};
use cmux::{
    ColumnEdge, ColumnMode, ColumnUpdateOptions, Config, Direction, Error, LayoutNode,
    SplitOptions, TabUpdateOptions, Update, WorkspaceUpdateOptions,
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

fn start_daemon(binary: &Path) -> (Daemon, PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-sdk-state-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-typed-state", "--socket"])
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
    let (_daemon, socket) = start_daemon(Path::new(&binary));
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
    let first = raw.create_frontend_browser_tab(create.clone()).unwrap();
    let retry = raw.create_frontend_browser_tab(create).unwrap();
    assert_eq!((first.replayed, retry.replayed), (false, true));
    assert_eq!((retry.tab_id.clone(), retry.surface), (first.tab_id.clone(), first.surface));
    let tabs = session.snapshot().unwrap().tabs;
    assert_eq!(tabs.iter().filter(|tab| tab.id == first.tab_id).count(), 1);
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
