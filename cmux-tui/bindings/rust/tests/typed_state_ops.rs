//! Typed calls the GPUI app used to send through `request_raw`:
//! `workspace.update`, `tab.pin`/`tab.unpin`/`tab.update`, `column.update`,
//! `window_record.*`, the personal workspace groups (`workspace_group.*`,
//! `workspace.place`, `workspace.placement.list`), keyed
//! `new-frontend-browser-tab` and `update-frontend-browser-tab`, and
//! protocol/2 errors through `request_raw`.
//! Each test runs the SDK against a one-connection mock daemon and checks the
//! exact request and the typed result.

use cmux::raw::{
    ClientConfig, FrontendBrowserEngine, FrontendBrowserTabCreate, FrontendBrowserTabUpdate,
};
use cmux::{
    ColumnEdge, ColumnMode, ColumnUpdateOptions, Config, Error, MutationOptions, PaneId, ScreenId,
    SessionId, TabId, TabUpdateOptions, Update, WorkspaceGroupCreateOptions,
    WorkspaceGroupUpdateOptions, WorkspaceId, WorkspacePlaceOptions, WorkspaceUpdateOptions,
};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

const SESSION: &str = "session_00000000000000000000000000000002";
const WORKSPACE: &str = "ws_00000000000000000000000000000003";
const SCREEN: &str = "screen_00000000000000000000000000000005";
const PANE: &str = "pane_00000000000000000000000000000006";
const TAB: &str = "tab_00000000000000000000000000000007";
const BROWSER: &str = "browser_0000000000000000000000000000000d";
const SPLIT: &str = "split_0000000000000000000000000000000e";

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

/// A mock daemon on a fresh socket that serves one connection with `serve`.
fn mock(serve: impl FnOnce(&mut UnixStream, &mut BufReader<UnixStream>) + Send + 'static) -> Mock {
    let path = std::env::temp_dir().join(format!(
        "cmux-typed-state-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ));
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        serve(&mut stream, &mut reader);
    });
    Mock { path, server: Some(server) }
}

struct Mock {
    path: PathBuf,
    server: Option<thread::JoinHandle<()>>,
}

impl Mock {
    fn client(&self) -> cmux::Client {
        cmux::Client::connect(
            Config::from_socket_path(&self.path).with_timeout(Duration::from_secs(2)),
        )
        .unwrap()
    }

    fn raw(&self) -> cmux::raw::Client {
        let config =
            ClientConfig::from_socket_path(&self.path).with_timeout(Duration::from_secs(2));
        cmux::raw::Client::connect(config).unwrap()
    }

    fn finish(mut self) {
        self.server.take().unwrap().join().unwrap();
    }
}

impl Drop for Mock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn read_line(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the client closed early");
    serde_json::from_str(&line).unwrap()
}

/// The next protocol/2 request.
fn request(reader: &mut BufReader<UnixStream>, operation: &str) -> Value {
    let value = read_line(reader);
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["type"], "request");
    assert_eq!(value["operation"], operation, "{value}");
    value
}

fn respond(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut response = Map::from_iter([
        ("protocol".to_string(), json!("cmux.protocol/2")),
        ("type".to_string(), json!("response")),
        ("id".to_string(), request["id"].clone()),
    ]);
    response.extend(body.as_object().unwrap().clone());
    writeln!(stream, "{}", Value::Object(response)).unwrap();
}

fn mutation_ok(stream: &mut UnixStream, request: &Value, value: Value) {
    assert!(request["idempotency_key"].is_string(), "{request}");
    let result = json!({"value": value, "generation": "g", "revision": "9", "replayed": false});
    respond(stream, request, json!({"ok": true, "result": result}));
}

fn tab_snapshot(extra: Value) -> Value {
    json!({"id": TAB, "pane_id": PANE, "name": null, "index": 0, "focused": true,
           "content_kind": "browser", "content_id": BROWSER, "extra": extra})
}

fn tab(client: &cmux::Client) -> cmux::Tab {
    client
        .session(SessionId::parse(SESSION).unwrap())
        .workspace(WorkspaceId::parse(WORKSPACE).unwrap())
        .screen(ScreenId::parse(SCREEN).unwrap())
        .pane(PaneId::parse(PANE).unwrap())
        .tab(TabId::parse(TAB).unwrap())
}

#[test]
fn workspace_update_sends_set_and_cleared_fields_and_decodes_the_snapshot() {
    let mock = mock(|stream, reader| {
        let update = request(reader, "workspace.update");
        assert_eq!(update["idempotency_key"], "color-1");
        assert_eq!(
            update["params"],
            json!({"machine": "current", "session": SESSION, "workspace": WORKSPACE,
                   "title": "Build", "color": null, "expected_revision": "8"})
        );
        let workspace = json!({"id": WORKSPACE, "session_id": SESSION, "name": "w", "index": 0,
                               "focused": true, "extra": {"title": "Build"}});
        mutation_ok(stream, &update, workspace);
    });
    let client = mock.client();
    let workspace = client
        .session(SessionId::parse(SESSION).unwrap())
        .workspace(WorkspaceId::parse(WORKSPACE).unwrap());
    let options = WorkspaceUpdateOptions {
        title: Update::Set("Build".to_string()),
        color: Update::Clear,
        icon: Update::Unchanged,
    };
    let updated = workspace
        .update_with(options, MutationOptions::new("color-1").unwrap().with_expected_revision(8))
        .unwrap();
    assert_eq!(updated.value.extra["title"], "Build");
    assert_eq!(updated.revision, 9);
    // Nothing to change: refused before any request.
    let error = workspace.update(WorkspaceUpdateOptions::default()).unwrap_err();
    assert!(matches!(error, Error::InvalidArgument(_)), "{error:?}");
    client.close().unwrap();
    mock.finish();
}

#[test]
fn tab_pin_unpin_and_update_send_their_operations_and_decode_tab_snapshots() {
    let mock = mock(|stream, reader| {
        let pin = request(reader, "tab.pin");
        assert_eq!(pin["idempotency_key"], "pin-1");
        assert_eq!(pin["params"]["tab"], TAB);
        mutation_ok(stream, &pin, tab_snapshot(json!({"pinned": true})));

        let unpin = request(reader, "tab.unpin");
        assert_eq!(unpin["params"]["tab"], TAB);
        mutation_ok(stream, &unpin, tab_snapshot(json!({})));

        let update = request(reader, "tab.update");
        let params = update["params"].as_object().unwrap();
        assert_eq!(params["zoom"], 1.25);
        assert_eq!(params["back"], json!(["https://a.example/", "https://b.example/"]));
        assert_eq!(params["forward"], json!([]));
        assert_eq!(params["owner"], "install-a");
        mutation_ok(stream, &update, tab_snapshot(json!({"zoom": 1.25, "owner": "install-a"})));

        let clear = request(reader, "tab.update");
        assert_eq!(clear["params"]["zoom"], Value::Null);
        assert!(clear["params"].get("back").is_none());
        mutation_ok(stream, &clear, tab_snapshot(json!({})));
    });
    let client = mock.client();
    let tab = tab(&client);
    let pinned = tab.pin_with(MutationOptions::new("pin-1").unwrap()).unwrap();
    assert_eq!(pinned.value.extra["pinned"], true);
    assert!(!tab.unpin().unwrap().value.extra.contains_key("pinned"));
    let updated = tab
        .update(TabUpdateOptions {
            zoom: Update::Set(1.25),
            back: Some(vec!["https://a.example/".into(), "https://b.example/".into()]),
            forward: Some(vec![]),
            owner: Some("install-a".into()),
        })
        .unwrap();
    assert_eq!(updated.value.extra["owner"], "install-a");
    tab.update(TabUpdateOptions { zoom: Update::Clear, ..Default::default() }).unwrap();

    // Catalog limits are refused before any request.
    for invalid in [
        TabUpdateOptions::default(),
        TabUpdateOptions { zoom: Update::Set(6.0), ..Default::default() },
        TabUpdateOptions { zoom: Update::Set(f64::NAN), ..Default::default() },
        TabUpdateOptions { back: Some(vec![String::new(); 21]), ..Default::default() },
        TabUpdateOptions { owner: Some(String::new()), ..Default::default() },
    ] {
        assert!(matches!(tab.update(invalid), Err(Error::InvalidArgument(_))));
    }
    client.close().unwrap();
    mock.finish();
}

#[test]
fn column_update_sends_typed_edge_mode_and_width() {
    let mock = mock(|stream, reader| {
        let screen = json!({"id": SCREEN, "workspace_id": WORKSPACE, "name": null, "index": 0,
            "focused": true, "layout": {"version": 1, "screen_id": SCREEN, "active_pane_id": PANE,
            "zoomed_pane_id": null, "root": {"kind": "leaf", "pane_id": PANE, "tab_ids": []}}});
        let pin = request(reader, "column.update");
        assert_eq!(
            pin["params"],
            json!({"machine": "current", "session": SESSION, "workspace": WORKSPACE,
                   "screen": SCREEN, "column": SPLIT, "sticky": true, "edge": "left",
                   "mode": "overlay"})
        );
        mutation_ok(stream, &pin, screen.clone());
        for edge in ["top", "bottom"] {
            let dock = request(reader, "column.update");
            assert_eq!(
                (&dock["params"]["edge"], &dock["params"]["mode"]),
                (&json!(edge), &json!("docked"))
            );
            mutation_ok(stream, &dock, screen.clone());
        }
        let width = request(reader, "column.update");
        let params = width["params"].as_object().unwrap();
        assert_eq!((params["width"].as_f64(), params.get("sticky")), (Some(0.5), None));
        mutation_ok(stream, &width, screen.clone());
        let unpin = request(reader, "column.update");
        assert_eq!(unpin["params"]["sticky"], false);
        assert!(unpin["params"].get("edge").is_none());
        mutation_ok(stream, &unpin, screen);
    });
    let client = mock.client();
    let screen = client
        .session(SessionId::parse(SESSION).unwrap())
        .workspace(WorkspaceId::parse(WORKSPACE).unwrap())
        .screen(ScreenId::parse(SCREEN).unwrap());
    screen
        .update_column(SPLIT, ColumnUpdateOptions::pin(ColumnEdge::Left, ColumnMode::Overlay))
        .unwrap();
    for edge in [ColumnEdge::Top, ColumnEdge::Bottom] {
        screen.update_column(SPLIT, ColumnUpdateOptions::pin(edge, ColumnMode::Docked)).unwrap();
    }
    screen.update_column(SPLIT, ColumnUpdateOptions::width(0.5)).unwrap();
    screen.update_column(SPLIT, ColumnUpdateOptions::unpin()).unwrap();
    for invalid in [
        ColumnUpdateOptions::default(),
        ColumnUpdateOptions::width(0.05),
        ColumnUpdateOptions::width(f64::INFINITY),
        ColumnUpdateOptions { edge: Some("left".into()), ..ColumnUpdateOptions::width(0.5) },
        ColumnUpdateOptions { edge: Some("left".into()), ..ColumnUpdateOptions::unpin() },
        ColumnUpdateOptions {
            edge: Some("middle".into()),
            sticky: Some(true),
            mode: None,
            width: None,
        },
        ColumnUpdateOptions {
            mode: Some("floating".into()),
            sticky: Some(true),
            edge: None,
            width: None,
        },
    ] {
        assert!(matches!(screen.update_column(SPLIT, invalid), Err(Error::InvalidArgument(_))));
    }
    client.close().unwrap();
    mock.finish();
}

fn window_record(revision: &str) -> Value {
    json!({"id": "install-a/w1", "install_id": "install-a", "window_id": "w1",
           "owner": "install-a", "revision": revision, "record": {"frame": [0, 0, 800, 600]},
           "updated_at_ms": "1700000000000"})
}

#[test]
fn window_records_list_put_with_record_revision_and_delete() {
    let mock = mock(|stream, reader| {
        let list = request(reader, "window_record.list");
        assert!(list.get("idempotency_key").is_none());
        assert_eq!(list["params"], json!({"machine": "current", "session": SESSION}));
        respond(stream, &list, json!({"ok": true, "result": [window_record("3")]}));

        let put = request(reader, "window_record.put");
        assert_eq!(put["idempotency_key"], "put-1");
        assert_eq!(
            put["params"],
            json!({"machine": "current", "session": SESSION, "install_id": "install-a",
                   "window_id": "w1", "expected_revision": "3",
                   "record": {"frame": [0, 0, 800, 600]}})
        );
        mutation_ok(stream, &put, window_record("4"));

        let stale = request(reader, "window_record.put");
        assert_eq!(stale["params"]["expected_revision"], "0");
        respond(
            stream,
            &stale,
            json!({"ok": false, "error": {"code": "revision.conflict",
            "message": "window record revision is 4", "details": {"current": "4"},
            "retryable": false}}),
        );

        let delete = request(reader, "window_record.delete");
        assert_eq!(delete["params"]["window_id"], "w1");
        assert!(delete["params"].get("expected_revision").is_none());
        mutation_ok(stream, &delete, json!({"id": "install-a/w1", "revision": "4"}));
    });
    let client = mock.client();
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let rows = session.window_records().unwrap();
    assert_eq!((rows.len(), rows[0].revision, rows[0].updated_at_ms), (1, 3, 1_700_000_000_000));
    let record = json!({"frame": [0, 0, 800, 600]});
    let put = session
        .put_window_record_with(
            "install-a",
            "w1",
            record.clone(),
            Some(3),
            MutationOptions::new("put-1").unwrap(),
        )
        .unwrap();
    assert_eq!((put.value.revision, put.value.owner.as_str()), (4, "install-a"));
    match session.put_window_record("install-a", "w1", record.clone(), Some(0)).unwrap_err() {
        Error::Protocol { code, details, .. } => {
            assert_eq!((code.as_str(), &details["current"]), ("revision.conflict", &json!("4")));
        }
        other => panic!("expected revision.conflict, got {other:?}"),
    }
    let deleted = session.delete_window_record("install-a", "w1", None).unwrap();
    assert_eq!(deleted.value.revision, 4);

    // Refused before any request: a non-object record, a bad key, an
    // oversized record, and a cursor revision in MutationOptions.
    assert!(session.put_window_record("install-a", "w1", json!([]), None).is_err());
    assert!(session.put_window_record("install a", "w1", record.clone(), None).is_err());
    assert!(session.put_window_record("install_unadopted", "w1", record.clone(), None).is_err());
    let big = json!({"pad": "x".repeat(cmux::WINDOW_RECORD_MAX_BYTES)});
    assert!(session.put_window_record("install-a", "w1", big, None).is_err());
    let cursor = MutationOptions::unique().unwrap().with_expected_revision(1);
    assert!(session.put_window_record_with("install-a", "w1", record, None, cursor).is_err());
    client.close().unwrap();
    mock.finish();
}

const GROUP: &str = "grp_0b3a5f0e7c2d4a1b";
const REGISTRY: &str = "reg-local";

fn group_snapshot(name: &str, color: Value, collapsed: bool, index: u32) -> Value {
    json!({"id": GROUP, "room_id": "default", "name": name, "color": color,
           "collapsed": collapsed, "index": index})
}

fn placement_snapshot(group: Value, index: u32) -> Value {
    json!({"workspace": {"session_id": REGISTRY, "workspace_ref": "wk-1",
                         "workspace_id": WORKSPACE},
           "index": index, "group_id": group, "room_id": null})
}

#[test]
fn workspace_groups_create_update_move_delete_send_the_catalog_fields() {
    let mock = mock(|stream, reader| {
        let create = request(reader, "workspace_group.create");
        assert_eq!(create["idempotency_key"], "group-1");
        assert_eq!(
            create["params"],
            json!({"machine": "current", "session": SESSION, "name": "Work",
                   "color": "#225588", "collapsed": false, "index": 0,
                   "expected_revision": "4"})
        );
        mutation_ok(stream, &create, group_snapshot("Work", json!("#225588"), false, 0));

        let minimal = request(reader, "workspace_group.create");
        assert_eq!(
            minimal["params"],
            json!({"machine": "current", "session": SESSION, "name": "Play", "room": "default"})
        );
        mutation_ok(stream, &minimal, group_snapshot("Play", Value::Null, false, 1));

        let update = request(reader, "workspace_group.update");
        assert_eq!(
            update["params"],
            json!({"machine": "current", "session": SESSION, "workspace_group": GROUP,
                   "name": "Deep work", "color": null, "collapsed": true})
        );
        mutation_ok(stream, &update, group_snapshot("Deep work", Value::Null, true, 0));

        let moved = request(reader, "workspace_group.move");
        assert_eq!(
            moved["params"],
            json!({"machine": "current", "session": SESSION, "workspace_group": GROUP,
                   "index": 2})
        );
        mutation_ok(stream, &moved, group_snapshot("Deep work", Value::Null, true, 1));

        let delete = request(reader, "workspace_group.delete");
        assert_eq!(
            delete["params"],
            json!({"machine": "current", "session": SESSION, "workspace_group": GROUP})
        );
        let ungrouped = json!([{"session_id": REGISTRY, "workspace_ref": "wk-1",
                                "workspace_id": WORKSPACE},
                               {"session_id": "reg-other", "workspace_ref": "wk-9",
                                "workspace_id": null}]);
        mutation_ok(stream, &delete, json!({"id": GROUP, "ungrouped": ungrouped}));
    });
    let client = mock.client();
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let options = WorkspaceGroupCreateOptions {
        color: Some("#225588".into()),
        collapsed: Some(false),
        index: Some(0),
        ..WorkspaceGroupCreateOptions::new("Work")
    };
    let mutation = MutationOptions::new("group-1").unwrap().with_expected_revision(4);
    let created = session.create_workspace_group_with(options, mutation).unwrap();
    assert_eq!(
        (created.value.id.as_str(), created.value.color.as_deref(), created.revision),
        (GROUP, Some("#225588"), 9)
    );
    let play = WorkspaceGroupCreateOptions {
        room: Some("default".into()),
        ..WorkspaceGroupCreateOptions::new("Play")
    };
    assert_eq!(session.create_workspace_group(play).unwrap().value.color, None);
    let update = WorkspaceGroupUpdateOptions {
        name: Some("Deep work".into()),
        color: Update::Clear,
        collapsed: Some(true),
        room: None,
    };
    let updated = session.update_workspace_group(GROUP, update).unwrap().value;
    assert_eq!((updated.name.as_str(), updated.collapsed), ("Deep work", true));
    assert_eq!(session.move_workspace_group(GROUP, 2).unwrap().value.index, 1);
    let deleted = session.delete_workspace_group(GROUP).unwrap().value;
    assert_eq!(deleted.ungrouped.len(), 2);
    assert_eq!(deleted.ungrouped[0].workspace_id, Some(WorkspaceId::parse(WORKSPACE).unwrap()));
    assert_eq!(deleted.ungrouped[1].placement_id(), "reg-other/wk-9");

    // Refused before any request: nothing to update, bad state ids.
    let nothing = session.update_workspace_group(GROUP, WorkspaceGroupUpdateOptions::default());
    assert!(matches!(nothing, Err(Error::InvalidArgument(_))), "{nothing:?}");
    assert!(session.move_workspace_group("", 0).is_err());
    assert!(session.delete_workspace_group("g".repeat(65)).is_err());
    let bad_room = WorkspaceGroupCreateOptions { room: Some(String::new()), ..Default::default() };
    assert!(session.create_workspace_group(bad_room).is_err());
    client.close().unwrap();
    mock.finish();
}

#[test]
fn workspace_place_and_the_personal_lists_decode_typed_snapshots() {
    let mock = mock(|stream, reader| {
        let list = request(reader, "workspace_group.list");
        assert!(list.get("idempotency_key").is_none());
        assert_eq!(list["params"], json!({"machine": "current", "session": SESSION}));
        respond(
            stream,
            &list,
            json!({"ok": true, "result": [group_snapshot("Work",
            json!("red"), false, 0)]}),
        );

        let in_room = request(reader, "workspace_group.list");
        assert_eq!(in_room["params"]["room"], "default");
        respond(stream, &in_room, json!({"ok": true, "result": []}));

        let placements = request(reader, "workspace.placement.list");
        assert_eq!(placements["params"], json!({"machine": "current", "session": SESSION}));
        let other = json!({"workspace": {"session_id": "reg-other", "workspace_ref": "wk-9",
                                         "workspace_id": null},
                           "index": 1, "group_id": null, "room_id": "default"});
        respond(
            stream,
            &placements,
            json!({"ok": true, "result": [placement_snapshot(json!(GROUP), 0), other]}),
        );

        let place = request(reader, "workspace.place");
        assert_eq!(place["idempotency_key"], "place-1");
        assert_eq!(
            place["params"],
            json!({"machine": "current", "session": SESSION, "workspace": WORKSPACE,
                   "group": GROUP, "index": 3})
        );
        mutation_ok(stream, &place, placement_snapshot(json!(GROUP), 3));

        let ungroup = request(reader, "workspace.place");
        assert_eq!(
            ungroup["params"],
            json!({"machine": "current", "session": SESSION, "workspace": WORKSPACE,
                   "group": null})
        );
        mutation_ok(stream, &ungroup, placement_snapshot(Value::Null, 3));

        let reorder = request(reader, "workspace.place");
        assert!(reorder["params"].get("group").is_none());
        assert_eq!(reorder["params"]["index"], 0);
        mutation_ok(stream, &reorder, placement_snapshot(Value::Null, 0));
    });
    let client = mock.client();
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let groups = session.workspace_groups().unwrap();
    assert_eq!((groups.len(), groups[0].color.as_deref()), (1, Some("red")));
    assert!(session.workspace_groups_in_room("default").unwrap().is_empty());
    let placements = session.workspace_placements().unwrap();
    assert_eq!(placements[0].group_id.as_deref(), Some(GROUP));
    assert_eq!(placements[0].workspace.placement_id(), format!("{REGISTRY}/wk-1"));
    assert_eq!((placements[1].workspace.workspace_id.as_ref(), placements[1].index), (None, 1));
    assert_eq!(placements[1].room_id.as_deref(), Some("default"));

    let workspace = session.workspace(WorkspaceId::parse(WORKSPACE).unwrap());
    let into = WorkspacePlaceOptions { group: Update::Set(GROUP.into()), index: Some(3) };
    let placed = workspace.place_with(into, MutationOptions::new("place-1").unwrap()).unwrap();
    assert_eq!((placed.value.group_id.as_deref(), placed.value.index), (Some(GROUP), 3));
    let out = WorkspacePlaceOptions { group: Update::Clear, index: None };
    assert_eq!(workspace.place(out).unwrap().value.group_id, None);
    let first = WorkspacePlaceOptions { group: Update::Unchanged, index: Some(0) };
    assert_eq!(workspace.place(first).unwrap().value.index, 0);

    // Nothing to change is refused before any request.
    let nothing = workspace.place(WorkspacePlaceOptions::default());
    assert!(matches!(nothing, Err(Error::InvalidArgument(_))), "{nothing:?}");
    client.close().unwrap();
    mock.finish();
}

#[test]
fn workspace_group_snapshots_refuse_unknown_fields() {
    let mock = mock(|stream, reader| {
        let list = request(reader, "workspace_group.list");
        let mut group = group_snapshot("Work", Value::Null, false, 0);
        group["pinned"] = json!(true);
        respond(stream, &list, json!({"ok": true, "result": [group]}));
    });
    let client = mock.client();
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let error = session.workspace_groups().unwrap_err();
    assert!(matches!(error, Error::UnexpectedEnvelope(_)), "{error:?}");
    client.close().unwrap();
    mock.finish();
}

/// The next raw protocol-v12 command.
fn command(reader: &mut BufReader<UnixStream>, cmd: &str) -> Value {
    let value = read_line(reader);
    assert_eq!(value["cmd"], cmd, "{value}");
    value
}

fn reply(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut response = Map::from_iter([("id".to_string(), request["id"].clone())]);
    response.extend(body.as_object().unwrap().clone());
    writeln!(stream, "{}", Value::Object(response)).unwrap();
}

fn identify_with(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, keys: bool) {
    let identify = command(reader, "identify");
    let mut capabilities = vec!["frontend-browser-tabs-v1", "frontend-browser-owner-v1"];
    if keys {
        capabilities.push("frontend-browser-tab-keys-v1");
    }
    let data = json!({"app": "cmux-tui", "capabilities": capabilities, "daemon_handoff": 1,
                      "generation": "g", "pid": 1, "protocol": 12, "registry_id": "r",
                      "session": "mock", "terminal_revision": 0, "version": "0",
                      "workspace_revision": 0});
    reply(stream, &identify, json!({"ok": true, "data": data}));
}

#[test]
fn keyed_frontend_browser_tab_create_identifies_then_sends_the_key_and_decodes_replay() {
    let mock = mock(|stream, reader| {
        identify_with(stream, reader, true);
        for replayed in [false, true] {
            let create = command(reader, "new-frontend-browser-tab");
            assert_eq!(create["idempotency_key"], "gpui-tab-1");
            assert_eq!(
                (&create["pane"], &create["engine"], &create["owner"], &create["url"]),
                (&json!(7), &json!("cef"), &json!("install-a"), &json!("https://cmux.com"))
            );
            assert_eq!((&create["cols"], &create["rows"]), (&json!(80), &json!(24)));
            let data = json!({"surface": 42, "tab_resource_id": TAB,
                              "content_resource_id": BROWSER, "replayed": replayed});
            reply(stream, &create, json!({"ok": true, "data": data}));
        }
        let update = command(reader, "update-frontend-browser-tab");
        assert_eq!((&update["surface"], &update["favicon_url"]), (&json!(42), &Value::Null));
        assert!(update.get("owner").is_none());
        let data = json!({"surface": 42, "url": "https://cmux.com/docs", "title": "Docs",
                          "favicon_url": null, "owner": "install-a", "changed": true});
        reply(stream, &update, json!({"ok": true, "data": data}));
    });
    let mut raw = mock.raw();
    let mut create =
        FrontendBrowserTabCreate::new("https://cmux.com", FrontendBrowserEngine::Cef, "gpui-tab-1");
    create.pane = Some(7);
    create.owner = Some("install-a".into());
    create.size = Some((80, 24));
    let first = raw.create_frontend_browser_tab(create.clone()).unwrap();
    let retry = raw.create_frontend_browser_tab(create).unwrap();
    assert_eq!(
        (first.surface, first.tab_id.as_str(), first.browser_id.as_str()),
        (42, TAB, BROWSER)
    );
    assert_eq!((first.replayed, retry.replayed, retry.tab_id), (false, true, first.tab_id));
    let updated = raw
        .write_frontend_browser_tab(FrontendBrowserTabUpdate {
            surface: 42,
            url: Some("https://cmux.com/docs".into()),
            title: Some("Docs".into()),
            favicon_url: Update::Clear,
            owner: None,
        })
        .unwrap();
    assert_eq!(
        (updated.url.as_str(), updated.title.as_deref(), updated.changed),
        ("https://cmux.com/docs", Some("Docs"), true)
    );
    assert_eq!(updated.favicon_url, None);
    raw.close();
    mock.finish();
}

#[test]
fn keyed_frontend_browser_tab_create_refuses_a_daemon_without_keys_before_sending() {
    let mock = mock(|stream, reader| {
        identify_with(stream, reader, false);
        // The client must not send the create: the next line is EOF.
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).unwrap(), 0, "unexpected request {line}");
    });
    let mut raw = mock.raw();
    let create =
        FrontendBrowserTabCreate::new("https://cmux.com", FrontendBrowserEngine::Webkit, "k");
    match raw.create_frontend_browser_tab(create).unwrap_err() {
        Error::MissingCapability { capability, .. } => {
            assert_eq!(capability, "frontend-browser-tab-keys-v1");
        }
        other => panic!("expected MissingCapability, got {other:?}"),
    }
    let blank = FrontendBrowserTabCreate::new("https://cmux.com", FrontendBrowserEngine::Cef, " ");
    assert!(matches!(raw.create_frontend_browser_tab(blank), Err(Error::InvalidArgument(_))));
    raw.close();
    mock.finish();
}

#[test]
fn request_raw_keeps_the_full_protocol_two_error() {
    let mock = mock(|stream, reader| {
        let put = request(reader, "window_record.put");
        respond(
            stream,
            &put,
            json!({"ok": false, "error": {"code": "revision.conflict",
            "message": "stale", "details": {"current": "5"}, "retryable": false}}),
        );
        let legacy = command(reader, "close-pane");
        reply(stream, &legacy, json!({"ok": false, "error": "unknown pane 9"}));
    });
    let mut raw = mock.raw();
    let envelope = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "r1",
                          "operation": "window_record.put", "idempotency_key": "k",
                          "params": {"machine": "current", "session": "current"}});
    match raw.request_raw(envelope.as_object().unwrap().clone()).unwrap_err() {
        Error::Protocol { code, message, details, retryable } => {
            assert_eq!(
                (code.as_str(), message.as_str(), retryable),
                ("revision.conflict", "stale", false)
            );
            assert_eq!(details, json!({"current": "5"}));
        }
        other => panic!("expected Error::Protocol, got {other:?}"),
    }
    // A protocol-v12 failure keeps its string error.
    let legacy = json!({"cmd": "close-pane", "pane": 9});
    match raw.request_raw(legacy.as_object().unwrap().clone()).unwrap_err() {
        Error::Command { message, .. } => assert_eq!(message, "unknown pane 9"),
        other => panic!("expected Error::Command, got {other:?}"),
    }
    raw.close();
    mock.finish();
}
