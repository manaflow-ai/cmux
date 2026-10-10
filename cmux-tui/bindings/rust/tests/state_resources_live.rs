//! Batch-2 typed calls against a real cmux-tui daemon: tab groups
//! (`tab_group.*`, `saved_tab_group.*`), closed history (`closed.list`,
//! `closed.reopen`), `workspace.create {ephemeral}`, the typed `bookmarks-v1`
//! raw results, and `Error::error_code` on a raw refusal.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.

use cmux::raw::{
    BookmarkImportNode, ClientConfig, CreateBookmarkRequest, DeleteBookmarkRequest,
    ImportBookmarksRequest, ListBookmarksRequest, Optional,
};
use cmux::{
    ClosedListOptions, ClosedReopenOptions, Config, CreateWorkspaceOptions, Direction,
    SplitOptions, TabGroupCreateOptions, TabGroupUpdateOptions,
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

fn live(name: &str) -> Option<(Daemon, PathBuf)> {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return None;
    };
    Some(start_daemon(Path::new(&binary), name))
}

fn connect(socket: &Path) -> cmux::Client {
    cmux::Client::connect(Config::from_socket_path(socket).with_timeout(Duration::from_secs(10)))
        .unwrap()
}

#[test]
fn tab_groups_and_closed_history_live_daemon() {
    let Some((_daemon, socket)) = live("tabgroups") else { return };
    let client = connect(&socket);
    let session = client.current_session();
    let created = session.create_workspace(Some("groups".into())).unwrap();
    let path = created.value.clone();
    let pane = created
        .resource
        .screen(path.screen_id().unwrap().clone())
        .pane(path.pane_id().unwrap().clone());
    // Group the tab of a second pane, so closing the group keeps the
    // workspace.
    let split = pane.split(SplitOptions::new(Direction::Right)).unwrap();
    let split_pane = split.value.pane_id().unwrap().clone();
    let tab = split.value.tab_id().unwrap().clone();

    let options = TabGroupCreateOptions {
        name: Some("Live".into()),
        color: Some("green".into()),
        ..TabGroupCreateOptions::new(vec![tab.clone()])
    };
    let group = session.create_tab_group(options).unwrap().value;
    assert_eq!((group.name.as_str(), group.color.as_str()), ("Live", "green"));
    assert_eq!((group.pane_id.clone(), group.tab_ids.clone()), (split_pane.clone(), vec![tab]));
    assert!(session.tab_groups().unwrap().iter().any(|g| g.id == group.id));
    assert_eq!(session.tab_groups_in_pane(&split_pane).unwrap().len(), 1);
    let rename = TabGroupUpdateOptions { name: Some("Renamed".into()), ..Default::default() };
    assert_eq!(session.update_tab_group(&group.id, rename).unwrap().value.name, "Renamed");
    assert_eq!(session.tab_group(&group.id).unwrap().name, "Renamed");

    // Saved groups: the live group links to its record.
    let saved = session.save_tab_group(&group.id, None).unwrap().value;
    assert_eq!((saved.name.as_str(), saved.members.len()), ("Renamed", 1));
    assert_eq!(
        session.tab_group(&group.id).unwrap().saved_tab_group_id.as_deref(),
        Some(saved.id.as_str())
    );
    assert!(session.saved_tab_groups().unwrap().iter().any(|s| s.id == saved.id));

    // Closing the group closes its tab; closed history records it.
    let before = session.closed_items(ClosedListOptions::default()).unwrap().len();
    let released = session.close_tab_group(&group.id).unwrap().value;
    assert_eq!(released.tab_group_id, group.id);
    let closed = session.closed_items(ClosedListOptions::default()).unwrap();
    assert_eq!(closed.len(), before + 1, "{closed:?}");
    assert_eq!(closed[0].member_count, 1, "{:?}", closed[0]);
    let reopened = session
        .reopen_closed(ClosedReopenOptions {
            closed: Some(closed[0].id.clone()),
            ..Default::default()
        })
        .unwrap()
        .value;
    assert_eq!(reopened.closed_id, closed[0].id);
    assert!(!reopened.tab_ids.is_empty(), "{reopened:?}");
    assert_eq!(session.closed_items(ClosedListOptions::default()).unwrap().len(), before);

    let deleted = session.delete_saved_tab_group(&saved.id).unwrap().value;
    assert!(deleted.deleted);
    assert!(session.saved_tab_groups().unwrap().iter().all(|s| s.id != saved.id));
    created.resource.close().unwrap();
}

#[test]
fn ephemeral_workspace_live_daemon() {
    let Some((_daemon, socket)) = live("ephemeral") else { return };
    let client = connect(&socket);
    let session = client.current_session();
    let options = CreateWorkspaceOptions {
        name: Some("incognito".into()),
        ephemeral: true,
        ..Default::default()
    };
    let created = session.create_workspace_with(options, cmux::MutationOptions::unique().unwrap());
    let created = created.unwrap();
    let snapshot = created.resource.refresh().unwrap();
    assert_eq!(snapshot.extra.get("ephemeral"), Some(&json!(true)), "{snapshot:?}");
    let normal = session.create_workspace(Some("normal".into())).unwrap();
    assert_eq!(normal.resource.refresh().unwrap().extra.get("ephemeral"), None);

    // A close inside an ephemeral workspace leaves no closed history.
    let before = session.closed_items(ClosedListOptions::default()).unwrap().len();
    let path = created.value.clone();
    let pane = created
        .resource
        .screen(path.screen_id().unwrap().clone())
        .pane(path.pane_id().unwrap().clone());
    let split = pane.split(SplitOptions::new(Direction::Right)).unwrap();
    split.resource.close().unwrap();
    assert_eq!(session.closed_items(ClosedListOptions::default()).unwrap().len(), before);
    created.resource.close().unwrap();
    normal.resource.close().unwrap();
}

#[test]
fn typed_bookmarks_and_error_code_live_daemon() {
    let Some((_daemon, socket)) = live("bookmarks") else { return };
    let config = ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let mut raw = cmux::raw::Client::connect(config).unwrap();
    let identity = raw.identify_server().unwrap();
    assert!(identity.capabilities.unwrap_or_default().iter().any(|c| c == "bookmarks-v1"));
    let list = |raw: &mut cmux::raw::Client| {
        raw.list_bookmarks(ListBookmarksRequest { browser_profile_id: "default".into() }).unwrap()
    };
    let empty = list(&mut raw);
    assert!(empty.bookmarks.is_empty());

    let folder = raw
        .create_bookmark(CreateBookmarkRequest {
            browser_profile_id: "default".into(),
            parent: "bar".into(),
            kind: "folder".into(),
            title: "Live".into(),
            index: Optional::Missing,
            url: Optional::Missing,
            favicon_key: Optional::Missing,
            source_key: Optional::Missing,
            created_ms: Optional::Missing,
            bookmark: Optional::Missing,
            origin: Optional::Value("sdk-live".into()),
            mutation_id: Optional::Value("m-1".into()),
        })
        .unwrap();
    assert!(folder.changed && !folder.replayed);
    assert_eq!((folder.bookmark.kind.as_str(), folder.bookmark.parent.as_str()), ("folder", "bar"));

    let page = BookmarkImportNode {
        kind: "url".into(),
        title: "Docs".into(),
        url: Some("https://cmux.com/docs".into()),
        created_ms: Some(5),
        children: None,
    };
    let imported = raw
        .import_bookmarks(ImportBookmarksRequest {
            browser_profile_id: "default".into(),
            parent: folder.bookmark.id.clone(),
            index: Optional::Missing,
            source_key: Optional::Missing,
            replace: None,
            nodes: vec![BookmarkImportNode {
                kind: "folder".into(),
                title: "Imported".into(),
                url: None,
                created_ms: None,
                children: Some(vec![Box::new(page)]),
            }],
            origin: Optional::Missing,
            mutation_id: Optional::Missing,
        })
        .unwrap();
    assert_eq!((imported.root_ids.len(), imported.count), (1, 2));
    let listed = list(&mut raw);
    assert!(listed.bookmarks_revision > empty.bookmarks_revision);
    let titles = listed.bookmarks.iter().map(|b| b.title.as_str()).collect::<Vec<_>>();
    assert_eq!(titles, ["Live", "Imported", "Docs"]);
    assert_eq!(listed.bookmarks[2].url.as_deref(), Some("https://cmux.com/docs"));

    let delete = DeleteBookmarkRequest {
        bookmark: folder.bookmark.id,
        origin: Optional::Missing,
        mutation_id: Optional::Missing,
    };
    let deleted = raw.delete_bookmark(delete.clone()).unwrap();
    assert_eq!(deleted.deleted.len(), 3);
    // The second delete is refused with a machine-readable code.
    let error = raw.delete_bookmark(delete).unwrap_err();
    assert_eq!(error.error_code(), Some("not_found"), "{error:?}");
    raw.close();
}
