//! Typed state handles against a one-connection mock daemon: closed history
//! (`closed.list`, `closed.reopen`), tab groups (`tab_group.*`), saved tab
//! groups (`saved_tab_group.*`), and `workspace.create {ephemeral}`. Each
//! test checks the exact request and the typed, forward-compatible result.

mod common;

use cmux::{
    ClosedListOptions, ClosedReopenOptions, CreateWorkspaceOptions, Error, InitialContent,
    MutationOptions, PaneId, TabGroupCreateOptions, TabGroupMoveOptions, TabGroupUpdateOptions,
    TabId,
};
use common::{PANE, SESSION, TAB, TAB_2, WORKSPACE, mock, mutation_ok, read_ok, request, respond};
use serde_json::{Value, json};

const GROUP: &str = "tgrp_0123456789abcdef0123456789abcdef";
const SAVED: &str = "saved_0123456789abcdef0123456789abcdef";
const CLOSED: &str = "closed_0123456789abcdef0123456789abcdef";
const SCREEN_2: &str = "screen_00000000000000000000000000000009";

fn routing() -> Value {
    json!({"machine": "current", "session": SESSION})
}

fn with(mut params: Value, fields: Value) -> Value {
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    params
}

fn tab_group(name: &str, tabs: &[&str]) -> Value {
    json!({"id": GROUP, "pane_id": PANE, "name": name, "color": "blue", "collapsed": false,
           "tab_ids": tabs, "saved_tab_group_id": null})
}

fn closed_tab() -> Value {
    json!({"kind": "terminal", "name": "zsh", "cwd": "/tmp", "url": null,
           "browser_profile_id": null, "pinned": false})
}

#[test]
fn closed_list_and_reopen_send_their_fields_and_decode_groups() {
    let mock = mock(|stream, reader| {
        let list = request(reader, "closed.list");
        assert_eq!(list["params"], with(routing(), json!({"window": "install-a/w1", "limit": 5})));
        let screen = json!({"name": null, "tabs": [closed_tab()]});
        let member = json!({"kind": "tab", "name": "zsh", "workspace_id": WORKSPACE,
                            "pane_id": PANE, "index": 2, "screens": [screen]});
        let mut future = member.clone();
        future["kind"] = json!("hologram");
        future["sparkle"] = json!(1);
        let item = json!({"id": CLOSED, "kind": "tab", "name": "zsh", "workspace_id": WORKSPACE,
                          "pane_id": PANE, "index": 2, "closed_at_ms": "1700000000000",
                          "screens": [screen], "window": "install-a/w1", "member_count": 2,
                          "members": [member, future], "group_label": "x"});
        read_ok(stream, &list, json!([item]));

        let reopen = request(reader, "closed.reopen");
        assert_eq!(reopen["idempotency_key"], "reopen-1");
        assert_eq!(reopen["params"], with(routing(), json!({"closed": CLOSED, "members": [0]})));
        mutation_ok(
            stream,
            &reopen,
            json!({"closed_id": CLOSED, "kind": "tab", "workspace_id": WORKSPACE,
                   "workspace_ids": [WORKSPACE], "remaining": 1, "screen_ids": [SCREEN_2],
                   "tab_ids": [TAB]}),
        );

        // No group named: the daemon picks the window's newest group.
        let newest = request(reader, "closed.reopen");
        assert_eq!(newest["params"], with(routing(), json!({"window": "install-a/w1"})));
        respond(
            stream,
            &newest,
            json!({"ok": false, "error": {"code": "resource.not_found", "message": "none",
                   "details": {}, "retryable": false}}),
        );
    });
    let client = mock.client();
    let session = mock.session(&client);
    let options = ClosedListOptions { window: Some("install-a/w1".into()), limit: Some(5) };
    let items = session.closed_items(options).unwrap();
    assert_eq!(items.len(), 1);
    let item = &items[0];
    assert_eq!((item.id.as_str(), item.kind.as_str(), item.index), (CLOSED, "tab", 2));
    assert_eq!((item.closed_at_ms, item.member_count), (1_700_000_000_000, 2));
    assert_eq!(item.workspace_id.as_ref().map(|id| id.as_str()), Some(WORKSPACE));
    assert_eq!(item.screens[0].tabs[0].cwd.as_deref(), Some("/tmp"));
    assert_eq!(item.additional["group_label"], "x");
    // A member kind this SDK does not know decodes and keeps its fields.
    assert_eq!(item.members[1].kind, "hologram");
    assert_eq!(item.members[1].additional["sparkle"], 1);

    let reopened = session
        .reopen_closed_with(
            ClosedReopenOptions {
                closed: Some(CLOSED.into()),
                members: Some(vec![0]),
                ..Default::default()
            },
            MutationOptions::new("reopen-1").unwrap(),
        )
        .unwrap();
    assert_eq!((reopened.value.remaining, reopened.value.tab_ids[0].as_str()), (1, TAB));
    assert_eq!(reopened.value.screen_ids[0].as_str(), SCREEN_2);
    let error = session
        .reopen_closed(ClosedReopenOptions {
            window: Some("install-a/w1".into()),
            ..Default::default()
        })
        .unwrap_err();
    assert_eq!(error.error_code(), Some("resource.not_found"));
    // Refused before any request.
    let bad = ClosedListOptions { limit: Some(0), ..Default::default() };
    assert!(matches!(session.closed_items(bad), Err(Error::InvalidArgument(_))));
    let empty = ClosedReopenOptions { members: Some(vec![]), ..Default::default() };
    assert!(matches!(session.reopen_closed(empty), Err(Error::InvalidArgument(_))));
    client.close().unwrap();
    mock.finish();
}

#[test]
fn tab_group_operations_send_their_fields_and_decode_snapshots() {
    let mock = mock(|stream, reader| {
        let list = request(reader, "tab_group.list");
        assert_eq!(list["params"], with(routing(), json!({"pane_id": PANE})));
        let mut future = tab_group("Work", &[TAB]);
        future["color"] = json!("ultraviolet");
        future["sync_state"] = json!("pending");
        read_ok(stream, &list, json!([future]));

        let get = request(reader, "tab_group.get");
        assert_eq!(get["params"], with(routing(), json!({"tab_group": GROUP})));
        read_ok(stream, &get, tab_group("Work", &[TAB]));

        let create = request(reader, "tab_group.create");
        assert_eq!(create["idempotency_key"], "group-1");
        assert_eq!(
            create["params"],
            with(routing(), json!({"tabs": [TAB, TAB_2], "name": "Work", "color": "green"}))
        );
        mutation_ok(stream, &create, tab_group("Work", &[TAB, TAB_2]));

        let update = request(reader, "tab_group.update");
        assert_eq!(
            update["params"],
            with(routing(), json!({"tab_group": GROUP, "collapsed": true}))
        );
        mutation_ok(stream, &update, tab_group("Work", &[TAB, TAB_2]));

        let add = request(reader, "tab_group.add_tabs");
        assert_eq!(
            add["params"],
            with(routing(), json!({"tab_group": GROUP, "tabs": [TAB_2], "index": 0}))
        );
        mutation_ok(stream, &add, tab_group("Work", &[TAB_2, TAB]));

        let remove = request(reader, "tab_group.remove_tabs");
        assert_eq!(remove["params"], with(routing(), json!({"tabs": [TAB_2]})));
        mutation_ok(stream, &remove, json!([tab_group("Work", &[TAB])]));

        let moved = request(reader, "tab_group.move");
        assert_eq!(
            moved["params"],
            with(routing(), json!({"tab_group": GROUP, "pane_id": PANE, "index": 3}))
        );
        mutation_ok(stream, &moved, tab_group("Work", &[TAB]));

        for operation in ["tab_group.ungroup", "tab_group.close"] {
            let release = request(reader, operation);
            assert_eq!(release["params"], with(routing(), json!({"tab_group": GROUP})));
            mutation_ok(stream, &release, json!({"tab_group_id": GROUP, "tab_ids": [TAB]}));
        }
    });
    let client = mock.client();
    let session = mock.session(&client);
    let pane = PaneId::parse(PANE).unwrap();
    let tab = TabId::parse(TAB).unwrap();
    let tab_2 = TabId::parse(TAB_2).unwrap();

    let listed = session.tab_groups_in_pane(&pane).unwrap();
    assert_eq!(listed[0].color, "ultraviolet");
    assert_eq!(listed[0].additional["sync_state"], "pending");
    assert_eq!(session.tab_group(GROUP).unwrap().tab_ids, std::slice::from_ref(&tab));

    let options = TabGroupCreateOptions {
        name: Some("Work".into()),
        color: Some("green".into()),
        ..TabGroupCreateOptions::new(vec![tab.clone(), tab_2.clone()])
    };
    let created = session.create_tab_group_with(options, MutationOptions::new("group-1").unwrap());
    assert_eq!(created.unwrap().value.tab_ids.len(), 2);
    let collapse = TabGroupUpdateOptions { collapsed: Some(true), ..Default::default() };
    session.update_tab_group(GROUP, collapse).unwrap();
    let added = session.add_tabs_to_tab_group(GROUP, vec![tab_2.clone()], Some(0)).unwrap();
    assert_eq!(added.value.tab_ids, [tab_2.clone(), tab.clone()]);
    let changed = session.remove_tabs_from_tab_groups(vec![tab_2]).unwrap();
    assert_eq!(changed.value.len(), 1);
    let destination = TabGroupMoveOptions { pane: Some(pane), index: Some(3) };
    session.move_tab_group(GROUP, destination).unwrap();
    let ungrouped = session.ungroup_tab_group(GROUP).unwrap().value;
    assert_eq!(ungrouped.tab_ids, std::slice::from_ref(&tab));
    assert_eq!(session.close_tab_group(GROUP).unwrap().value.tab_group_id, GROUP);

    // Refused before any request.
    let nothing = session.update_tab_group(GROUP, TabGroupUpdateOptions::default());
    assert!(matches!(nothing, Err(Error::InvalidArgument(_))));
    let no_tabs = session.create_tab_group(TabGroupCreateOptions::new(vec![]));
    assert!(matches!(no_tabs, Err(Error::InvalidArgument(_))));
    assert!(matches!(session.tab_group(""), Err(Error::InvalidArgument(_))));
    client.close().unwrap();
    mock.finish();
}

#[test]
fn saved_tab_group_operations_send_their_fields_and_decode_records() {
    let saved = json!({"id": SAVED, "room_id": "default", "name": "Work", "color": "red",
                       "members": [
                           {"kind": "terminal", "name": "zsh", "cwd": "/tmp", "url": null,
                            "engine": null, "browser_profile_id": null},
                           {"kind": "browser", "name": "Docs", "cwd": null,
                            "url": "https://cmux.com", "engine": "cef",
                            "browser_profile_id": "default"}],
                       "index": 0, "updated_at_ms": "42"});
    let mock = mock(move |stream, reader| {
        let list = request(reader, "saved_tab_group.list");
        assert_eq!(list["params"], with(routing(), json!({"room": "default"})));
        read_ok(stream, &list, json!([&saved]));

        let save = request(reader, "saved_tab_group.save");
        assert_eq!(save["params"], with(routing(), json!({"tab_group": GROUP})));
        mutation_ok(stream, &save, saved);

        let reopen = request(reader, "saved_tab_group.reopen");
        assert_eq!(
            reopen["params"],
            with(routing(), json!({"saved_tab_group": SAVED, "pane_id": PANE}))
        );
        mutation_ok(
            stream,
            &reopen,
            json!({"saved_tab_group_id": SAVED, "tab_group": tab_group("Work", &[TAB])}),
        );

        let delete = request(reader, "saved_tab_group.delete");
        assert_eq!(delete["params"], with(routing(), json!({"saved_tab_group": SAVED})));
        mutation_ok(stream, &delete, json!({"id": SAVED, "deleted": true}));
    });
    let client = mock.client();
    let session = mock.session(&client);
    let listed = session.saved_tab_groups_in_room("default").unwrap();
    assert_eq!((listed[0].updated_at_ms, listed[0].members.len()), (42, 2));
    assert_eq!(listed[0].members[1].engine.as_deref(), Some("cef"));
    assert_eq!(session.save_tab_group(GROUP, None).unwrap().value.id, SAVED);
    let reopened = session.reopen_saved_tab_group(SAVED, Some(PaneId::parse(PANE).unwrap()));
    assert_eq!(reopened.unwrap().value.tab_group.id, GROUP);
    assert!(session.delete_saved_tab_group(SAVED).unwrap().value.deleted);
    client.close().unwrap();
    mock.finish();
}

#[test]
fn ephemeral_workspace_create_sends_the_flag_only_when_set() {
    let mock = mock(|stream, reader| {
        for ephemeral in [true, false] {
            let create = request(reader, "workspace.create");
            let mut expected = with(routing(), json!({"initial_content": "empty"}));
            if ephemeral {
                expected["ephemeral"] = json!(true);
            }
            assert_eq!(create["params"], expected);
            mutation_ok(stream, &create, json!({"kind": "workspace", "workspace_id": WORKSPACE}));
        }
    });
    let client = mock.client();
    let session = mock.session(&client);
    for ephemeral in [true, false] {
        let options = CreateWorkspaceOptions {
            initial_content: InitialContent::Empty,
            ephemeral,
            ..Default::default()
        };
        let created = session.create_workspace_with(options, MutationOptions::unique().unwrap());
        assert_eq!(created.unwrap().resource.id().unwrap().as_str(), WORKSPACE);
    }
    client.close().unwrap();
    mock.finish();
}
