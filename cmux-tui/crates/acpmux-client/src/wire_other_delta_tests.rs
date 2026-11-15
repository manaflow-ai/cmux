use super::*;
use acpmux_list_types::RowKey;
use acpmux_list_types::folders::FolderRow;

#[test]
fn every_delta_op_has_one_round_tripping_shape() {
    let ops = vec![
        DeltaOp::<serde_json::Value>::Gone {
            seq: 1,
            origin: "local".into(),
            chat_id: "gone".into(),
        },
        DeltaOp::Queue { seq: 2, bytes: 3 },
        DeltaOp::Origin {
            seq: 3,
            origin: Origin { id: "peer".into(), state: OriginState::Down, since: 4, extra: None },
        },
    ];
    let frame = delta_frame(&DeltaFrame {
        sid: "s".into(),
        replay: Some(ReplayMark::End),
        ops: ops.clone(),
    })
    .unwrap();
    let decoded: DeltaFrame<serde_json::Value> = frame.decode_json().unwrap();
    assert_eq!(decoded.ops, ops);
}

#[test]
fn folders_view_and_deltas_round_trip() {
    let row = FolderRow {
        origin: "local".into(),
        folder: "/work".into(),
        newest: RowKey::new("local", "chat-7"),
        at: 19,
        count: 3,
    };
    let request = Sub { view: Some(ListView::Folders), ..Sub::new("s", "list") };
    let value = serde_json::to_value(&request).unwrap();
    assert_eq!(value.get("view"), Some(&serde_json::json!("folders")));
    assert!(validate_mirror_view(Some(ListView::Folders)).is_err());

    let ops = vec![
        DeltaOp::<serde_json::Value>::Folder { seq: 4, row },
        DeltaOp::FolderGone { seq: 5, origin: "local".into(), folder: "/work".into() },
    ];
    let frame = delta_frame(&DeltaFrame {
        sid: "s".into(),
        replay: Some(ReplayMark::End),
        ops: ops.clone(),
    })
    .unwrap();
    let decoded: DeltaFrame<serde_json::Value> = frame.decode_json().unwrap();
    assert_eq!(decoded.ops, ops);
}

#[test]
fn chat_ops_round_trip_in_their_own_delta() {
    let row = RawJson::from_bytes(br#"{"id":7,"rev":1,"body":{"text":"a\"b"}}"#).unwrap();
    let item = QueueItem { id: "p".into(), text: "hi".into(), len: 2, held: false, at: 9 };
    let ops = vec![
        ChatOp::Row { seq: 3, row: row.clone(), body_len: Some(9) },
        ChatOp::Text { seq: 3, row_id: 7, text: RawJson::from_bytes(br#""\n\u0001""#).unwrap() },
        ChatOp::Patch { seq: 4, row },
        ChatOp::Queue { seq: 4, entry: Some(item.clone()), removed: None, count: 1, head: None },
        ChatOp::Queue { seq: 4, entry: None, removed: Some("q".into()), count: 0, head: None },
        ChatOp::Queue {
            seq: 4,
            entry: None,
            removed: None,
            count: 1,
            head: Some(QueueHead { entries: vec![item], count: 1 }),
        },
    ];
    let delta = ChatDelta { sid: "s".into(), replay: Some(ReplayMark::End), ops };
    let frame = Frame::json(FrameKind::Delta, &delta).unwrap();
    // Stored bytes go out as they are: the escape is not decoded and escaped again.
    assert!(std::str::from_utf8(frame.payload()).unwrap().contains(r#""a\"b""#));
    let decoded: ChatDelta = frame.decode_json().unwrap();
    assert_eq!(decoded, delta);
}

#[test]
fn a_blob_reply_is_a_head_a_newline_and_the_stored_bytes() {
    let head = BlobHead {
        id: "b".into(),
        start: 4,
        len: 3,
        total: 10,
        next: None,
        open: true,
        generation: Some("0123456789abcdef".into()),
        fixed: Some(8),
    };
    let frame = blob_frame(&head, b"\\\"\n").unwrap();
    assert_eq!(frame.kind, FrameKind::Blob);
    let (decoded, bytes) = decode_blob(&frame).unwrap();
    assert_eq!(decoded, head);
    assert_eq!(bytes, b"\\\"\n");
    let request: Request = serde_json::from_value(serde_json::json!({
        "method": "blob",
        "params": {"id": "b", "stream": "chat:c", "edition": 2, "rowId": 7, "len": 10}
    }))
    .unwrap();
    assert!(matches!(request, Request::Blob(Blob { row_id: Some(7), .. })));
}

#[test]
fn folder_position_keeps_a_full_bound_sized_name() {
    let key = FolderPosition { at: 7, origin: "o".into(), folder: "x".repeat(1024) };
    let value = serde_json::to_value(&key).unwrap();
    let decoded: FolderPosition = serde_json::from_value(value).unwrap();
    assert_eq!(decoded, key);
}

#[test]
fn keyed_summary_pages_keep_the_old_json_shape() {
    let page = serde_json::json!({
        "sid":"s", "stream":"list", "keys":[{"lastActivity":4,"chatId":"c","origin":"local"}]
    });
    let decoded: Page = serde_json::from_value(page).unwrap();
    assert!(matches!(decoded.keys.as_deref(), Some([PageKey::Summary(_)])));
    let legacy = vec![ListKey { last_activity: 4, chat_id: "c".into(), origin: "local".into() }];
    assert_eq!(
        serde_json::to_vec(decoded.keys.as_ref().unwrap()).unwrap(),
        serde_json::to_vec(&legacy).unwrap(),
        "summary keys retain their pre-folders wire bytes"
    );
}
