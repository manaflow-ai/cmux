use super::*;
#[test]
fn upgrade_is_first_output() {
    let mut c = Client::<Value>::new(["list"]);
    c.connected();
    assert!(std::str::from_utf8(&c.take_send().unwrap()).unwrap().contains("_acpmux/v2"));
}

/// A relayed page (row 8b) needs a ready connection, is sent once under its own sid, and
/// its answer or error comes back as one change for that sid with no sub; a reconnect drops
/// it and does not send it again.
#[test]
fn a_relayed_page_is_sent_once_and_answered_without_a_sub() {
    let mut client = Client::<Value>::connected_v2();
    let page = || Page::new("relay-1", "list", wire::PageSide::After, 0);
    assert!(matches!(client.relay_page(page()), Err(FrameError::Refused(_))));
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    client.relay_page(page()).unwrap();
    assert!(matches!(client.relay_page(page()), Err(FrameError::RequestInFlight)));
    let sent = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    let sent: Value = sent.decode_json().unwrap();
    assert_eq!(sent["method"], "page");
    assert_eq!(sent["params"]["sid"], "relay-1");
    assert!(client.take_send().is_none());
    let answer = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"relay-1","rows":[{"chatId":"a"}],"hasBefore":false,"hasAfter":true}),
    )
    .unwrap()
    .encode();
    assert_eq!(client.received(&answer), answer.len());
    match client.next_change() {
        Some(Change::Page(result)) => {
            assert_eq!(result.sid, "relay-1");
            assert_eq!(result.rows.len(), 1);
        }
        other => panic!("{other:?}"),
    }
    // Answered: the sid is free again, and a second answer for it is skipped.
    client.received(&answer);
    assert!(client.next_change().is_none());
    client.relay_page(Page::new("relay-2", "list", wire::PageSide::After, 0)).unwrap();
    let error = Frame::json(
        FrameKind::Error,
        &serde_json::json!({"method":"page","sid":"relay-2","code":"busy","message":"full"}),
    )
    .unwrap()
    .encode();
    client.received(&error);
    assert_eq!(
        client.next_change(),
        Some(Change::Error {
            method: "page".into(),
            sid: Some("relay-2".into()),
            id: None,
            code: "busy".into(),
        })
    );
    client.relay_page(Page::new("relay-3", "list", wire::PageSide::After, 0)).unwrap();
    client.disconnected();
    client.connected();
    let resent = std::iter::from_fn(|| client.take_send())
        .filter_map(|bytes| Frame::from_encoded(&bytes).ok())
        .filter(|frame| frame.payload().windows(7).any(|w| w == b"relay-3"))
        .count();
    assert_eq!(resent, 0, "a relayed page is not sent again");
    client.received(&hello);
    assert!(client.relay_page(Page::new("relay-3", "list", wire::PageSide::After, 0)).is_ok());
}

#[test]
fn received_stops_at_one_frame_until_change_is_taken() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    assert_eq!(client.received(&hello), hello.len());
    let _ = client.subscribe(Sub::new("s", "list")).unwrap();
    let first = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    let second = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"s","cursor":2,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    let mut bytes = first.clone();
    bytes.extend_from_slice(&second);
    assert_eq!(client.received(&bytes), first.len());
    assert_eq!(client.changes.len(), 1);
    assert_eq!(client.changes.front().map(|queued| queued.bytes), Some(first.len() as u64));
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    assert_eq!(client.received(&bytes[first.len()..]), second.len());
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
}

#[test]
fn method_not_found_returns_fallback_bytes_once() {
    let mut client = Client::<Value>::new(["list"]);
    client.connected();
    let reply = b"{\"error\":{\"code\":-32601}}\nrest";
    assert_eq!(client.received(reply), reply.len());
    assert_eq!(client.next_change(), Some(Change::Fallback(b"rest".to_vec())));
    assert_eq!(client.received(b"later"), 0);
}

#[test]
fn upgrade_requires_matching_id_and_true_result() {
    let mut client = Client::<Value>::new(["list"]);
    client.connected();
    let wrong_id = br#"{"jsonrpc":"2.0","id":99,"result":{"upgrade":true}}
"#;
    assert_eq!(client.received(wrong_id), wrong_id.len());
    assert!(matches!(client.next_change(), Some(Change::Error { .. })));

    let mut client = Client::<Value>::new(["list"]);
    client.connected();
    let reply = br#"{"jsonrpc":"2.0","id":1,"result":{"upgrade":true}}
"#;
    assert_eq!(client.received(reply), reply.len());
    assert!(!client.is_fallback());

    let mut client = Client::<Value>::new(["list"]);
    client.connected();
    let reply = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000}}
tail"#;
    assert_eq!(client.received(reply), reply.len());
    assert_eq!(client.next_change(), Some(Change::Fallback(b"tail".to_vec())));
}

#[test]
fn unknown_delta_op_advances_cursor_but_keeps_known_ops() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    let _ = client.subscribe(Sub::new("s", "list").from_cursor(0)).unwrap();
    let frame = Frame::json(FrameKind::Delta, &serde_json::json!({
        "sid":"s","ops":[{"op":"future","seq":1},{"op":"queue","seq":2,"bytes":4}],"replay":"end"
    })).unwrap().encode();
    assert_eq!(client.received(&frame), frame.len());
    assert!(matches!(client.next_change(), Some(Change::Queue { seq: 2, .. })));
    assert!(matches!(client.next_change(), Some(Change::ResumeEnd { cursor: Cursor(2), .. })));
}

#[test]
fn received_stops_until_the_previous_frame_changes_are_taken() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    let frame = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    assert_eq!(client.received(&frame), frame.len());
    assert_eq!(client.received(&frame), 0);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    assert_eq!(client.received(&frame), frame.len());
}

#[test]
fn reconnect_resends_resume_and_direct_v2_does_not_upgrade() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list").from_cursor(7)).unwrap();
    client.disconnected();
    let hello_request = String::from_utf8(client.take_send().unwrap()).unwrap();
    assert!(hello_request.contains("hello"));
    client.received(&hello);
    let sub = String::from_utf8(client.take_send().unwrap()).unwrap();
    assert!(sub.contains("\"cursor\":7"));
    assert!(!sub.contains("\"anchor\""));
}

#[test]
fn reconnect_before_window_keeps_the_initial_anchor_request() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list").around(Anchor::End, 10)).unwrap();
    while client.take_send().is_some() {}
    client.disconnected();
    let _ = client.take_send();
    client.received(&hello);
    let request = String::from_utf8(client.take_send().unwrap()).unwrap();
    assert!(request.contains("\"anchor\":\"end\""));
    assert!(!request.contains("\"cursor\""));
}

#[test]
fn folder_subscription_strips_resume_fields_and_uses_head_anchor() {
    let mut client = Client::<Value>::connected_v2();
    let hello_request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    assert!(matches!(hello_request.decode_json::<Request>().unwrap(), Request::Hello(_)));
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(ListView::Folders);
    sub.cursor = Some(Cursor(7));
    sub.edition = Some(3);
    client.subscribe(sub).unwrap();
    let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    let value: Value = request.decode_json().unwrap();
    assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
    assert!(value.pointer("/params/cursor").is_none());
    assert!(value.pointer("/params/edition").is_none());
}

#[test]
fn folders_reconnect_and_drop_start_fresh_and_discard_old_pages() {
    let mut client = Client::<Value>::connected_v2();
    let hello_request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    assert!(matches!(hello_request.decode_json::<Request>().unwrap(), Request::Hello(_)));
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(ListView::Folders);
    client.subscribe(sub).unwrap();
    let _ = client.take_send();

    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"folders","cursor":11,"rows":[],"hasBefore":false,
            "hasAfter":false,"edition":4
        }),
    )
    .unwrap()
    .encode();
    client.received(&window);
    assert!(matches!(client.next_change(), Some(Change::FolderWindow(_))));

    let mut page = Page::new("folders", "list", wire::PageSide::After, 1);
    page.view = Some(ListView::Folders);
    client.page(page).unwrap();
    let _old_page_request = client.take_send().unwrap();

    // A replacement head also invalidates a page that was requested from
    // the previous head, even before a transport reconnect.
    let replacement = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"folders","cursor":12,"rows":[],"hasBefore":false,
            "hasAfter":false,"edition":5
        }),
    )
    .unwrap()
    .encode();
    client.received(&replacement);
    assert!(matches!(client.next_change(), Some(Change::FolderWindow(_))));
    let mut blocked_page = Page::new("folders", "list", wire::PageSide::After, 1);
    blocked_page.view = Some(ListView::Folders);
    assert!(client.page(blocked_page).is_ok());
    assert!(client.take_send().is_none(), "deferred page must wait for stale reply");
    let stale_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&stale_page);
    assert!(client.next_change().is_none());

    let fresh_request = client.take_send().unwrap();
    let request_value: Value = Frame::from_encoded(&fresh_request).unwrap().decode_json().unwrap();
    assert_eq!(request_value.get("method"), Some(&Value::String("page".into())));
    let fresh_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&fresh_page);
    assert!(matches!(client.next_change(), Some(Change::FolderPage(_))));

    let mut page = Page::new("folders", "list", wire::PageSide::After, 1);
    page.view = Some(ListView::Folders);
    client.page(page).unwrap();
    client.disconnected();
    let _hello_request = client.take_send().unwrap();
    client.received(&hello);
    let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    let value: Value = request.decode_json().unwrap();
    assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
    assert!(value.pointer("/params/cursor").is_none());
    assert!(value.pointer("/params/edition").is_none());

    // The page was outstanding on the old head and must not reappear.
    let stale_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&stale_page);
    assert!(client.next_change().is_none());

    let dropped =
        Frame::json(FrameKind::Dropped, &serde_json::json!({"sid":"folders","cursor":12}))
            .unwrap()
            .encode();
    client.received(&dropped);
    let new_sid = match client.next_change() {
        Some(Change::Dropped { new_sid: Some(sid), cursor, .. }) => {
            assert!(cursor.is_none());
            sid
        }
        other => panic!("unexpected change: {other:?}"),
    };
    let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
    let value: Value = request.decode_json().unwrap();
    assert_eq!(value.pointer("/params/sid"), Some(&Value::String(new_sid)));
    assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
    assert!(value.pointer("/params/cursor").is_none());
    assert!(value.pointer("/params/edition").is_none());

    // A late page for the retired folder SID must not fall through the
    // generic PageResult<Value> decoder.
    let before = client.skip_counters();
    let stale_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({
            "sid":"folders","rows":[{"chatId":"old"}],
            "hasBefore":false,"hasAfter":false
        }),
    )
    .unwrap()
    .encode();
    client.received(&stale_page);
    assert!(client.next_change().is_none());
    assert_eq!(client.skip_counters().unheld_sid, before.unheld_sid + 1);
    let stale_error = Frame::json(
        FrameKind::Error,
        &serde_json::json!({"method":"page","sid":"folders","code":"invalid_page"}),
    )
    .unwrap()
    .encode();
    client.received(&stale_error);
    assert!(client.next_change().is_none(), "a retired page error is stale too");
    assert_eq!(client.skip_counters().unheld_sid, before.unheld_sid + 2);
}

#[test]
fn skip_counters_cover_unknown_kind_op_missing_seq_and_unheld_sid() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    while client.take_send().is_some() {}
    let unknown =
        Frame::new(FrameKind::Unknown(200), br#"{"sid":"s","seq":1}"#.to_vec()).unwrap().encode();
    client.received(&unknown);
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"s","ops":[{"op":"future","seq":2},{"op":"queue","bytes":1}]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    let unheld =
        Frame::json(FrameKind::Delta, &serde_json::json!({"sid":"old","ops":[]})).unwrap().encode();
    client.received(&unheld);
    let counters = client.skip_counters();
    assert_eq!(counters.unknown_kind, 1);
    assert_eq!(counters.unknown_op, 1);
    assert_eq!(counters.missing_seq, 1);
    assert_eq!(counters.unheld_sid, 1);
}

#[test]
fn malformed_window_closes_the_connection() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    let malformed = Frame::new(FrameKind::Window, b"{".to_vec()).unwrap().encode();
    client.received(&malformed);
    assert!(matches!(client.next_change(), Some(Change::Error { .. })));
    assert_eq!(client.received(&malformed), 0);
}

#[test]
fn byte_credit_is_queued_when_taken_changes_cross_quarter_window() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply {
            daemon_id: "d".into(),
            limits: Limits { credit_window: 40, ..Limits::default() },
        },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    while client.take_send().is_some() {}
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    let _ = client.next_change();
    let credit = String::from_utf8(client.take_send().unwrap()).unwrap();
    assert!(credit.contains("credit"));
}

#[test]
fn dropped_replaces_sid_and_old_frames_are_ignored() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s1", "list").from_cursor(3)).unwrap();
    while client.take_send().is_some() {}
    let dropped = Frame::json(FrameKind::Dropped, &serde_json::json!({"sid":"s1","cursor":3}))
        .unwrap()
        .encode();
    client.received(&dropped);
    let change = client.next_change().unwrap();
    let new_sid = match change {
        Change::Dropped { new_sid: Some(new_sid), .. } => new_sid,
        other => panic!("unexpected change: {other:?}"),
    };
    assert!(new_sid != "s1");
    assert!(String::from_utf8(client.take_send().unwrap()).unwrap().contains(&new_sid));
    let old_frame = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"s1","cursor":4,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&old_frame);
    assert!(client.next_change().is_none());
}

#[test]
fn page_error_releases_the_request_slot() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    while client.take_send().is_some() {}
    client.page(Page::new("s", "list", wire::PageSide::After, 1)).unwrap();
    let error = Frame::json(
        FrameKind::Error,
        &serde_json::json!({"method":"page","sid":"s","code":"invalid_page"}),
    )
    .unwrap()
    .encode();
    client.received(&error);
    let _ = client.next_change();
    assert!(client.page(Page::new("s", "list", wire::PageSide::After, 1)).is_ok());
}

#[test]
fn final_replay_frame_marks_its_operations_as_replay() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list").from_cursor(0)).unwrap();
    while client.take_send().is_some() {}
    let frame = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"s","replay":"end","ops":[{"op":"queue","seq":1,"bytes":1}]}),
    )
    .unwrap()
    .encode();
    client.received(&frame);
    assert!(matches!(client.next_change(), Some(Change::Queue { replay: true, .. })));
    assert!(matches!(client.next_change(), Some(Change::ResumeEnd { .. })));
}

#[test]
fn not_ready_keeps_the_subscription_for_a_later_window() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    while client.take_send().is_some() {}
    let error = Frame::json(
        FrameKind::Error,
        &serde_json::json!({"method":"sub","sid":"s","code":"not_ready"}),
    )
    .unwrap()
    .encode();
    client.received(&error);
    assert!(matches!(client.next_change(), Some(Change::Error { .. })));
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
}

#[test]
fn page_drops_rows_changed_while_request_was_out_and_origin_is_one_change() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("s", "list")).unwrap();
    while client.take_send().is_some() {}
    client.page(Page::new("s", "list", wire::PageSide::After, 1)).unwrap();
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"s","ops":[{"op":"summary","seq":2,"summary":{"chatId":"changed"}}]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    let _ = client.next_change();
    let page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"s","rows":[{"chatId":"changed"},{"chatId":"kept"}],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&page);
    let Change::Page(page) = client.next_change().unwrap() else { panic!("expected page") };
    assert_eq!(page.rows, vec![serde_json::json!({"chatId":"kept"})]);
    let origin = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"s","ops":[{"op":"origin","seq":3,"id":"p","state":"removed","since":3}]}),
    )
    .unwrap()
    .encode();
    client.received(&origin);
    assert!(matches!(client.next_change(), Some(Change::Origin { .. })));
}

#[test]
fn folder_delta_is_applied_without_unknown_op_skip_or_page_stale_row() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub { view: Some(ListView::Folders), ..Sub::new("s", "list") }).unwrap();
    while client.take_send().is_some() {}
    let page_request = Page {
        sid: "s".into(),
        stream: "list".into(),
        before: None,
        after: None,
        keys: None,
        view: Some(ListView::Folders),
        max_bytes: wire::MAX_PAGE_BYTES as u32,
        filter: None,
        edition: None,
        fold: None,
        turns: false,
    };
    client.page(page_request).unwrap();
    let folder = serde_json::json!({
        "origin":"local", "folder":"/work", "newest":{"origin":"local","chatId":"chat"}, "at": 3, "count": 1
    });
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"s","ops":[{"op":"folder","seq":2,"row":folder}]}),
    )
    .unwrap()
    .encode();
    let before = client.skip_counters();
    client.received(&delta);
    assert_eq!(client.skip_counters().unknown_op, before.unknown_op);
    assert!(matches!(client.next_change(), Some(Change::Folder { seq: 2, .. })));
    let page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"s","rows":[folder],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&page);
    let Change::FolderPage(page) = client.next_change().unwrap() else {
        panic!("expected folder page")
    };
    assert!(page.rows.is_empty());
}

#[test]
fn folder_and_summary_sids_advance_from_their_own_ops_not_delta_cursor() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    client.subscribe(Sub::new("summary", "list")).unwrap();
    client.subscribe(Sub { view: Some(ListView::Folders), ..Sub::new("folders", "list") }).unwrap();
    while client.take_send().is_some() {}

    let summary_window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"summary","cursor":1,"rows":[],"hasBefore":false,
            "hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    let folder_window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"folders","cursor":2,"rows":[],"hasBefore":false,
            "hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    client.received(&summary_window);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    client.received(&folder_window);
    assert!(matches!(client.next_change(), Some(Change::FolderWindow(_))));

    // The envelope cursor is deliberately stale and must not advance either
    // sid. The folder operation on a summary sid is skipped and counted.
    let summary_folder = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({
            "sid":"summary","cursor":999,"ops":[{"op":"folder","seq":4,
            "row":{"origin":"local","folder":"/work","newest":{"origin":"local","chatId":"chat"},"at":4,"count":1}}]
        }),
    )
    .unwrap()
    .encode();
    let before = client.skip_counters();
    client.received(&summary_folder);
    assert_eq!(client.skip_counters().unknown_op, before.unknown_op + 1);
    assert_eq!(client.subscriptions.get("summary").unwrap().cursor, Cursor(4));
    assert_eq!(client.subscriptions.get("folders").unwrap().cursor, Cursor(2));

    let folder_delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({
            "sid":"folders","cursor":1000,"ops":[{"op":"folder","seq":7,
            "row":{"origin":"local","folder":"/work","newest":{"origin":"local","chatId":"chat"},"at":7,"count":1}}]
        }),
    )
    .unwrap()
    .encode();
    client.received(&folder_delta);
    assert_eq!(client.subscriptions.get("summary").unwrap().cursor, Cursor(4));
    assert_eq!(client.subscriptions.get("folders").unwrap().cursor, Cursor(7));
    assert!(matches!(client.next_change(), Some(Change::Folder { seq: 7, .. })));
}

#[test]
fn mirror_api_refuses_folders_before_registering_a_sid() {
    let mut client = Client::<Value>::connected_v2();
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(ListView::Folders);
    assert!(client.subscribe_mirror(sub, std::iter::empty(), false).is_err());
    assert!(client.subscriptions.is_empty());
}

#[test]
fn mirror_walk_reconciles_and_emits_whole_after_rows() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    assert_eq!(client.received(&hello), hello.len());
    client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
    let _ = client.take_send();
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"m","cursor":4,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    let page_request = client.take_send().expect("mirror starts a walk");
    let page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({
            "sid":"m","rows":[{"chatId":"chat","origin":"local","lastActivity":9,"state":"idle"}],
            "hasBefore":false,"hasAfter":false
        }),
    )
    .unwrap()
    .encode();
    assert!(!page_request.is_empty());
    client.received(&page);
    assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
    assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
}

#[test]
fn live_mirror_emits_left_for_closed_and_summary_rows() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    let mut sub = Sub::new("m", "list");
    sub.view = Some(ListView::Live);
    client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
    while client.take_send().is_some() {}
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"m","cursor":1,"rows":[
            {"chatId":"a","origin":"local","lastActivity":1,"state":"idle"},
            {"chatId":"b","origin":"local","lastActivity":1,"state":"idle"}
        ],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    let _ = client.next_change();
    let _ = client.take_send();
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"m","ops":[
            {"op":"summary","seq":2,"summary":{"chatId":"a","origin":"local","lastActivity":2,"state":"closed"}},
            {"op":"summary","seq":3,"summary":{"chatId":"b","origin":"local","lastActivity":3}}
        ]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    assert!(matches!(client.next_change(), Some(Change::Left { .. })));
    assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
}

fn receive_changes(
    client: &mut Client<Value>,
    kind: FrameKind,
    value: Value,
) -> Vec<Change<Value>> {
    let bytes = Frame::json(kind, &value).unwrap().encode();
    assert_eq!(client.received(&bytes), bytes.len());
    std::iter::from_fn(|| client.next_change()).collect()
}

fn take_pages(client: &mut Client<Value>) -> Vec<Value> {
    std::iter::from_fn(|| client.take_send())
        .map(|bytes| Frame::from_encoded(&bytes).unwrap().decode_json::<Value>().unwrap())
        .filter(|request| request.get("method").and_then(Value::as_str) == Some("page"))
        .collect()
}

fn mirror_window(client: &mut Client<Value>) {
    let changes = receive_changes(
        client,
        FrameKind::Window,
        serde_json::json!({
            "sid":"m","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
        }),
    );
    assert!(matches!(changes.as_slice(), [Change::Window(_)]));
}

fn mirror_page_error(client: &mut Client<Value>) {
    let changes = receive_changes(
        client,
        FrameKind::Error,
        serde_json::json!({
            "method":"page","sid":"m","code":"request_failed"
        }),
    );
    assert!(matches!(changes.as_slice(), [Change::Error { .. }]));
}

fn finish_empty_walk(client: &mut Client<Value>) {
    let changes = receive_changes(
        client,
        FrameKind::Page,
        serde_json::json!({
            "sid":"m","rows":[],"hasBefore":false,"hasAfter":false
        }),
    );
    assert!(matches!(changes.as_slice(), [Change::Whole { .. }]));
}

#[test]
fn live_subscription_without_mirror_delivers_closing_summary() {
    let mut client = ready_mirror();
    let mut sub = Sub::new("plain", "list");
    sub.view = Some(ListView::Live);
    client.subscribe(sub).unwrap();
    let summary =
        serde_json::json!({"chatId":"a","origin":"local","lastActivity":2,"state":"closed"});
    let changes = receive_changes(
        &mut client,
        FrameKind::Delta,
        serde_json::json!({
            "sid":"plain","ops":[{"op":"summary","seq":2,"summary":summary}]
        }),
    );
    assert!(matches!(changes.as_slice(), [Change::Summary { sid, summary: row, .. }]
        if sid == "plain" && row == &summary));
}

#[test]
fn mirror_read_errors_allow_exactly_two_requests_per_window() {
    let mut client = ready_mirror();
    for _ in 0..3 {
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
        // Ordinary changes are not page progress and cannot restart reads.
        let changes =
            receive_changes(&mut client, FrameKind::Delta, serde_json::json!({"sid":"m","ops":[]}));
        assert!(changes.is_empty());
        assert!(take_pages(&mut client).is_empty());
    }
}

#[test]
fn mirror_read_success_between_errors_allows_immediate_head_walk() {
    let mut client = ready_mirror();
    mirror_window(&mut client);
    assert_eq!(take_pages(&mut client).len(), 1);
    mirror_page_error(&mut client);
    assert_eq!(take_pages(&mut client).len(), 1);
    let changes = receive_changes(
        &mut client,
        FrameKind::Page,
        serde_json::json!({
            "sid":"m","rows":[],"hasBefore":false,"hasAfter":true,
            "afterKey":{"chatId":"a","origin":"local","lastActivity":1}
        }),
    );
    assert!(changes.is_empty());
    assert_eq!(take_pages(&mut client).len(), 1);
    mirror_page_error(&mut client);
    let retry = take_pages(&mut client);
    assert_eq!(retry.len(), 1);
    assert!(retry.first().unwrap().pointer("/params/after").is_none());
    mirror_page_error(&mut client);
    assert!(take_pages(&mut client).is_empty());
}

#[test]
fn mirror_read_stop_preserves_wanted_until_window_or_want() {
    for next_window in [true, false] {
        let mut client = ready_mirror();
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        let key = ListKey {
            last_activity: 1,
            chat_id: "wanted".into(),
            origin: "local".into(),
            past: false,
        };
        client.want("m", [key]).unwrap();
        assert!(take_pages(&mut client).is_empty());
        mirror_page_error(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
        if next_window {
            mirror_window(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            finish_empty_walk(&mut client);
        } else {
            client.want("m", std::iter::empty()).unwrap();
        }
        let wanted = take_pages(&mut client);
        assert_eq!(wanted.len(), 1);
        assert_eq!(
            wanted.first().unwrap().pointer("/params/keys/0/chatId"),
            Some(&Value::String("wanted".into()))
        );
    }
}

#[test]
fn mirror_wanted_error_retries_from_head_then_stops_without_progress() {
    let mut client = ready_mirror();
    mirror_window(&mut client);
    assert_eq!(take_pages(&mut client).len(), 1);
    finish_empty_walk(&mut client);
    let key =
        ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into(), past: false };
    client.want("m", [key]).unwrap();
    assert_eq!(take_pages(&mut client).len(), 1);
    mirror_page_error(&mut client);
    let retry = take_pages(&mut client);
    assert_eq!(retry.len(), 1);
    assert!(retry.first().unwrap().pointer("/params/keys").is_none());
    mirror_page_error(&mut client);
    assert!(take_pages(&mut client).is_empty());
    client.want("m", std::iter::empty()).unwrap();
    let wanted = take_pages(&mut client);
    assert_eq!(wanted.len(), 1);
    assert_eq!(
        wanted.first().unwrap().pointer("/params/keys/0/chatId"),
        Some(&Value::String("wanted".into()))
    );
    // Explicit want permits a read, not a fresh automatic retry allowance.
    mirror_page_error(&mut client);
    assert!(take_pages(&mut client).is_empty());
}

fn request_caller_page(client: &mut Client<Value>) {
    let mut page = Page::new("m", "list", wire::PageSide::After, 0);
    page.after = None;
    client.page(page).unwrap();
    assert_eq!(take_pages(client).len(), 1);
}

#[test]
fn caller_page_error_preserves_mirror_retry_allowance() {
    let mut client = ready_mirror();
    mirror_window(&mut client);
    assert_eq!(take_pages(&mut client).len(), 1);
    finish_empty_walk(&mut client);
    request_caller_page(&mut client);
    mirror_page_error(&mut client);
    assert!(take_pages(&mut client).is_empty());

    let key =
        ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into(), past: false };
    client.want("m", [key]).unwrap();
    assert_eq!(take_pages(&mut client).len(), 1);
    mirror_page_error(&mut client);
    let retry = take_pages(&mut client);
    assert_eq!(retry.len(), 1);
    assert!(retry.first().unwrap().pointer("/params/keys").is_none());
    assert!(retry.first().unwrap().pointer("/params/after").is_none());
    mirror_page_error(&mut client);
    assert!(take_pages(&mut client).is_empty());
}

#[test]
fn caller_page_error_releases_deferred_walk_without_resetting_allowance() {
    for prior_errors in 0..=2 {
        let mut client = ready_mirror();
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        let key = ListKey {
            last_activity: 1,
            chat_id: "wanted".into(),
            origin: "local".into(),
            past: false,
        };
        client.want("m", [key]).unwrap();
        assert!(take_pages(&mut client).is_empty());
        for error in 0..prior_errors {
            mirror_page_error(&mut client);
            assert_eq!(take_pages(&mut client).len(), usize::from(error == 0));
        }

        client.disconnected();
        let changes = receive_changes(
            &mut client,
            FrameKind::Hello,
            serde_json::to_value(wire::HelloReply {
                daemon_id: "d".into(),
                limits: Limits::default(),
            })
            .unwrap(),
        );
        assert!(changes.is_empty());
        assert!(take_pages(&mut client).is_empty());
        request_caller_page(&mut client);
        let changes = receive_changes(
            &mut client,
            FrameKind::Delta,
            serde_json::json!({"sid":"m","replay":"end","ops":[]}),
        );
        assert!(matches!(changes.as_slice(), [Change::ResumeEnd { .. }]));
        assert!(take_pages(&mut client).is_empty());

        mirror_page_error(&mut client);
        let walk = take_pages(&mut client);
        assert_eq!(walk.len(), usize::from(prior_errors < 2));
        if let Some(page) = walk.first() {
            assert!(page.pointer("/params/keys").is_none());
            assert!(page.pointer("/params/after").is_none());
        }
        for error in prior_errors..2 {
            mirror_page_error(&mut client);
            assert_eq!(take_pages(&mut client).len(), usize::from(error == 0));
        }
        // Stopping clears the deferred walk but preserves wanted keys.
        client.want("m", std::iter::empty()).unwrap();
        let wanted = take_pages(&mut client);
        assert_eq!(wanted.len(), 1);
        assert_eq!(
            wanted.first().unwrap().pointer("/params/keys/0/chatId"),
            Some(&Value::String("wanted".into()))
        );
    }
}

#[test]
fn mirror_request_can_select_v1_rows() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    let mut sub = Sub::new("m", "list");
    sub.rows = Some("v1".into());
    client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
    let request = client.take_send().unwrap();
    let value: Value = Frame::from_encoded(&request).unwrap().decode_json().unwrap();
    assert_eq!(value.pointer("/params/rows"), Some(&Value::String("v1".into())));
}

fn ready_mirror() -> Client<Value> {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
    let _ = client.take_send();
    client
}

#[test]
fn mirror_walk_delta_touched_row_survives_reconcile() {
    let mut client = ready_mirror();
    let a = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1,"state":"idle"});
    let b = serde_json::json!({"chatId":"b","origin":"local","lastActivity":2,"state":"idle"});
    let a_key = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1});
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"m","cursor":1,"rows":[a,b],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    let _ = client.next_change();
    let _ = client.take_send().expect("first walk page");
    let first_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"m","rows":[a],"hasBefore":false,"hasAfter":true,"afterKey":a_key}),
    )
    .unwrap()
    .encode();
    client.received(&first_page);
    let _ = client.next_change();
    let _ = client.take_send().expect("second walk page");
    let moved_b =
        serde_json::json!({"chatId":"b","origin":"local","lastActivity":3,"state":"idle"});
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"m","ops":[{"op":"summary","seq":2,"summary":moved_b}]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
    let second_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"m","rows":[],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&second_page);
    assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
    assert!(client.next_change().is_none());
}

#[test]
fn mirror_walk_delta_new_row_is_not_reconciled_away() {
    let mut client = ready_mirror();
    let _window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"m","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&_window);
    let _ = client.next_change();
    let _ = client.take_send().expect("walk page");
    let new_row =
        serde_json::json!({"chatId":"new","origin":"local","lastActivity":4,"state":"idle"});
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"m","ops":[{"op":"summary","seq":2,"summary":new_row}]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
    let page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"m","rows":[],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&page);
    assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
    assert!(client.next_change().is_none());
}

#[test]
fn mirror_walk_drops_rows_changed_while_page_was_out() {
    let mut client = ready_mirror();
    let a = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1,"state":"idle"});
    let d = serde_json::json!({"chatId":"d","origin":"local","lastActivity":1,"state":"idle"});
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"m","cursor":1,"rows":[a,d],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.received(&window);
    let _ = client.next_change();
    let _ = client.take_send().expect("walk page");
    let newer_a =
        serde_json::json!({"chatId":"a","origin":"local","lastActivity":2,"state":"idle"});
    let delta = Frame::json(
        FrameKind::Delta,
        &serde_json::json!({"sid":"m","ops":[
            {"op":"summary","seq":2,"summary":newer_a},
            {"op":"gone","seq":3,"origin":"local","chatId":"d"}
        ]}),
    )
    .unwrap()
    .encode();
    client.received(&delta);
    assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
    assert!(matches!(client.next_change(), Some(Change::Gone { chat_id, .. }) if chat_id == "d"));
    let page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({"sid":"m","rows":[a,d],"hasBefore":false,"hasAfter":false}),
    )
    .unwrap()
    .encode();
    client.received(&page);
    assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
    assert!(
        !client.subscriptions["m"]
            .mirror
            .as_ref()
            .unwrap()
            .held
            .contains_key(&("local".into(), "d".into()))
    );
}

fn finish_walk_with_rows(client: &mut Client<Value>, rows: Value) {
    let count = rows.as_array().unwrap().len();
    let changes = receive_changes(
        client,
        FrameKind::Page,
        serde_json::json!({
            "sid":"m","rows":rows,"hasBefore":false,"hasAfter":false
        }),
    );
    assert_eq!(changes.len(), count + 1);
    assert!(changes.iter().take(count).all(|change| matches!(change, Change::Summary { .. })));
    assert!(matches!(changes.last(), Some(Change::Whole { .. })));
}

#[test]
fn mirror_deleted_parent_is_not_requeued_forever() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    let mut sub = Sub::new("m", "list");
    sub.rows = Some("v1".into());
    client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
    let _ = client.take_send();
    let mut parent = Summary::new("parent");
    parent.state = "idle".into();
    let mut child = Summary::new("child");
    child.state = "waiting".into();
    child.parent = Some(parent.key());
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"m","cursor":1,
            "rows":[serde_json::to_value(&parent).unwrap(),serde_json::to_value(&child).unwrap()],
            "hasBefore":false,"hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    client.received(&window);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    let _ = client.take_send().expect("first walk page");
    finish_walk_with_rows(&mut client, serde_json::json!([parent, child]));

    let gone = receive_changes(
        &mut client,
        FrameKind::Delta,
        serde_json::json!({
            "sid":"m","ops":[{"op":"gone","seq":2,"origin":"local","chatId":"parent"}]
        }),
    );
    assert!(matches!(gone.as_slice(), [Change::Gone { chat_id, .. }] if chat_id == "parent"));
    let reads = take_pages(&mut client);
    assert_eq!(reads.len(), 1);
    assert_eq!(reads[0].pointer("/params/keys/0/chatId"), Some(&Value::String("child".into())));

    let child_page = Frame::json(
        FrameKind::Page,
        &serde_json::json!({
            "sid":"m","rows":[serde_json::to_value(&child).unwrap()],
            "hasBefore":false,"hasAfter":false
        }),
    )
    .unwrap()
    .encode();
    assert_eq!(client.received(&child_page), child_page.len());
    let changes: Vec<_> = std::iter::from_fn(|| client.next_change()).collect();
    assert!(matches!(changes.as_slice(), [Change::Summary { .. }]));
    assert!(take_pages(&mut client).is_empty());
}

#[test]
fn mirror_missing_parent_answer_stops_repeated_child_reads() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    let mut sub = Sub::new("m", "list");
    sub.rows = Some("v1".into());
    client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
    let _ = client.take_send();

    let mut child = Summary::new("child");
    child.state = "waiting".into();
    child.parent = Some(RowKey::new("local", "missing-parent"));
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"m","cursor":1,"rows":[serde_json::to_value(&child).unwrap()],
            "hasBefore":false,"hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    client.received(&window);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    let _ = client.take_send().expect("first walk page");
    finish_walk_with_rows(&mut client, serde_json::json!([child]));
    let parent_read = take_pages(&mut client);
    assert_eq!(parent_read.len(), 1);
    assert_eq!(
        parent_read[0].pointer("/params/keys/0/chatId"),
        Some(&Value::String("missing-parent".into()))
    );

    let missing = Frame::json(
        FrameKind::Page,
        &serde_json::json!({
            "sid":"m","rows":[],"missing":[{"origin":"local","chatId":"missing-parent","lastActivity":0}],
            "hasBefore":false,"hasAfter":false
        }),
    )
    .unwrap()
    .encode();
    client.received(&missing);
    assert!(client.next_change().is_none());

    for seq in 2..=3 {
        child.last_activity = seq;
        let changes = receive_changes(
            &mut client,
            FrameKind::Delta,
            serde_json::json!({
                "sid":"m","ops":[{"op":"summary","seq":seq,"summary":serde_json::to_value(&child).unwrap()}]
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Summary { .. }]));
        assert!(take_pages(&mut client).is_empty());
    }
}

#[test]
#[cfg_attr(miri, ignore = "500 held rows of safe code, over 10 minutes under Miri; no FFI call")]
fn mirror_parent_refresh_batches_only_its_held_children() {
    for total in [20, 500] {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        while client.take_send().is_some() {}
        let mut sub = Sub::new("m", "list");
        sub.rows = Some("v1".into());
        client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
        let _ = client.take_send();

        let mut parent = Summary::new("parent");
        parent.state = "idle".into();
        let mut rows = vec![serde_json::to_value(&parent).unwrap()];
        for index in 0..total {
            let mut row = Summary::new(format!("chat-{index}"));
            row.state = "idle".into();
            if index < 3 {
                row.parent = Some(parent.key());
            }
            rows.push(serde_json::to_value(row).unwrap());
        }
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"m","cursor":1,"rows":rows,
                "hasBefore":false,"hasAfter":false,"edition":1
            }),
        )
        .unwrap()
        .encode();
        client.received(&window);
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
        let _ = client.take_send().expect("first walk page");
        finish_walk_with_rows(&mut client, serde_json::json!(rows));

        let mut archived = parent;
        archived.archived = true;
        let changes = receive_changes(
            &mut client,
            FrameKind::Delta,
            serde_json::json!({
                "sid":"m","ops":[{"op":"summary","seq":2,"summary":archived}]
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Summary { .. }]));
        let reads = take_pages(&mut client);
        assert_eq!(reads.len(), 1);
        assert_eq!(
            reads[0].pointer("/params/keys").and_then(Value::as_array).map(Vec::len),
            Some(3)
        );
    }
}

#[test]
#[cfg_attr(miri, ignore = "4,096 keys of safe code, over 10 minutes under Miri; no FFI call")]
fn caller_wanted_keys_have_priority_over_internal_parents() {
    let mut client = ready_mirror();
    {
        let mirror = client.subscriptions.get_mut("m").unwrap().mirror.as_mut().unwrap();
        for index in 0..4096 {
            let id = ("local".to_owned(), format!("parent-{index}"));
            let key = ListKey {
                last_activity: index as u64,
                chat_id: id.1.clone(),
                origin: id.0.clone(),
                past: false,
            };
            mirror.wanted.insert(id.clone(), key);
            mirror.internal_wanted.insert(id);
        }
    }
    let caller_key =
        ListKey { last_activity: 1, chat_id: "caller".into(), origin: "local".into(), past: false };
    client.want("m", [caller_key.clone()]).unwrap();
    let mirror = client.subscriptions["m"].mirror.as_ref().unwrap();
    assert!(mirror.caller_wanted.contains(&Client::<Value>::row_identity(&caller_key)));
    assert!(mirror.wanted.contains_key(&Client::<Value>::row_identity(&caller_key)));
    assert_eq!(mirror.wanted.len(), 4096);

    let mut all_caller = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    all_caller.received(&hello);
    while all_caller.take_send().is_some() {}
    all_caller.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
    let _ = all_caller.take_send();
    {
        let mirror = all_caller.subscriptions.get_mut("m").unwrap().mirror.as_mut().unwrap();
        for index in 0..4096 {
            let id = ("local".to_owned(), format!("caller-{index}"));
            let key = ListKey {
                last_activity: index as u64,
                chat_id: id.1.clone(),
                origin: id.0.clone(),
                past: false,
            };
            mirror.wanted.insert(id.clone(), key);
            mirror.caller_wanted.insert(id);
        }
    }
    let extra =
        ListKey { last_activity: 0, chat_id: "extra".into(), origin: "local".into(), past: false };
    assert!(all_caller.want("m", [extra]).is_err());
}

#[test]
fn wanted_page_rest_is_requested_until_answered() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), true).unwrap();
    let _ = client.take_send();
    let key1 =
        ListKey { last_activity: 1, chat_id: "a".into(), origin: "local".into(), past: false };
    let key2 =
        ListKey { last_activity: 2, chat_id: "b".into(), origin: "local".into(), past: false };
    client.want("m", [key1, key2.clone()]).unwrap();
    let _ = client.take_send().expect("wanted read");
    let partial = Frame::json(
        FrameKind::Page,
        &serde_json::json!({
            "sid":"m","rows":[{"chatId":"a","origin":"local","lastActivity":1,"state":"idle"}],
            "hasBefore":false,"hasAfter":false,"rest":[key2]
        }),
    )
    .unwrap()
    .encode();
    client.received(&partial);
    let _ = client.next_change();
    let retry = client.take_send().expect("rest is retried");
    let retry_frame = Frame::from_encoded(&retry).unwrap();
    let retry_value: Value = retry_frame.decode_json().unwrap();
    assert_eq!(retry_value.pointer("/params/keys/0/chatId"), Some(&Value::String("b".into())));
}

#[test]
fn wanted_page_error_requeues_its_keys() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), true).unwrap();
    let _ = client.take_send();
    let key =
        ListKey { last_activity: 1, chat_id: "a".into(), origin: "local".into(), past: false };
    client.want("m", [key]).unwrap();
    let _ = client.take_send().expect("wanted page");
    let error = Frame::json(
        FrameKind::Error,
        &serde_json::json!({"method":"page","sid":"m","code":"request_failed"}),
    )
    .unwrap()
    .encode();
    client.received(&error);
    assert!(matches!(client.next_change(), Some(Change::Error { .. })));
    let retry = client.take_send().expect("retry walks from the head");
    let value: Value = Frame::from_encoded(&retry).unwrap().decode_json().unwrap();
    assert!(value.pointer("/params/keys").is_none());
    finish_empty_walk(&mut client);
    let wanted = take_pages(&mut client);
    assert_eq!(wanted.len(), 1);
    assert_eq!(
        wanted.first().unwrap().pointer("/params/keys/0/chatId"),
        Some(&Value::String("a".into()))
    );
}

#[test]
fn v1_row_overlays_typed_fields_and_spawned_by() {
    let mut parent = Summary::new("parent");
    parent.state = "idle".into();
    let mut child = Summary::new("child");
    child.state = "waiting".into();
    child.parent = Some(parent.key());
    child.extra =
        serde_json::value::RawValue::from_string(r#"{"sessionId":"old","custom":true}"#.into())
            .unwrap();
    let row = v1_row(&child, OriginState::Stale, Some(&parent));
    assert_eq!(row.get("sessionId"), Some(&Value::String("child".into())));
    assert_eq!(row.get("unread"), Some(&Value::Bool(false)));
    assert_eq!(row.get("spawnedBy"), Some(&Value::String("parent".into())));
    assert_eq!(row.get("stale"), Some(&Value::Bool(true)));
    assert_eq!(row.get("custom"), Some(&Value::Bool(true)));
}

#[test]
fn mirror_v1_rows_convert_window_and_keep_parent_facts_bounded() {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}

    let mut parent = Summary::new("parent");
    parent.state = "idle".into();
    parent.title = "Parent".into();
    let mut child = Summary::new("child");
    child.state = "waiting".into();
    child.parent = Some(parent.key());
    let mut sub = Sub::new("m", "list");
    sub.rows = Some("v1".into());
    sub.view = Some(ListView::Live);
    client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
    let _ = client.take_send();
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({
            "sid":"m","cursor":1,
            "rows":[serde_json::to_value(&parent).unwrap(),serde_json::to_value(&child).unwrap()],
            "hasBefore":false,"hasAfter":false,"edition":1
        }),
    )
    .unwrap()
    .encode();
    client.received(&window);
    let Some(Change::Window(window)) = client.next_change() else { panic!("window") };
    assert_eq!(window.rows[0].get("sessionId"), Some(&Value::String("parent".into())));
    assert_eq!(window.rows[1].get("spawnedBy"), Some(&Value::String("parent".into())));
    assert_eq!(window.rows[1].get("status"), Some(&Value::String("waiting".into())));
    let mirror = client.subscriptions["m"].mirror.as_ref().unwrap();
    assert_eq!(mirror.parent_facts.len(), 2);
    assert!(
        mirror.parent_children[&(String::from("local"), String::from("parent"))]
            .contains(&(String::from("local"), String::from("child")))
    );
}

#[cfg(feature = "tokio")]
#[tokio::test]
async fn tokio_driver_preserves_multiple_frames() {
    use tokio::io::{AsyncWriteExt, duplex};
    let (mut tx, rx) = duplex(4096);
    let (_output_reader, output_writer) = duplex(4096);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel(8);
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .unwrap()
    .encode();
    let window = Frame::json(
        FrameKind::Window,
        &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap()
    .encode();
    client.subscribe(Sub::new("s", "list")).unwrap();
    let task = tokio::spawn(tokio_driver::drive(client, rx, output_writer, out_tx));
    tx.write_all(&hello).await.unwrap();
    tx.write_all(&window).await.unwrap();
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), out_rx.recv())
        .await
        .unwrap()
        .unwrap();
    drop(tx);
    let _ = task.await;
}

#[cfg(feature = "tokio")]
#[tokio::test]
async fn tokio_driver_returns_fallback_transport_and_held_bytes() {
    use tokio::io::{AsyncWriteExt, duplex, sink};
    let (mut input, reader) = duplex(4096);
    let (out_tx, _out_rx) = tokio::sync::mpsc::channel(2);
    let task =
        tokio::spawn(tokio_driver::drive(Client::<Value>::new(["list"]), reader, sink(), out_tx));
    input
        .write_all(
            br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601}}
tail"#,
        )
        .await
        .unwrap();
    let exit = task.await.unwrap().unwrap();
    let tokio_driver::DriveExit::Fallback { bytes, .. } = exit else {
        panic!("driver did not return fallback transport")
    };
    assert_eq!(bytes, b"tail");
}
