use super::*;

#[test]
fn sub_and_page_are_shared_shapes() {
    let sub = Sub::new("s1", "list").from_cursor(42);
    let text = serde_json::to_string(&sub).unwrap();
    assert_eq!(text, r#"{"sid":"s1","stream":"list","cursor":42,"window":100}"#);
    let anchored = Sub::new("s1", "list").around(Anchor::End, 100);
    assert_eq!(
        serde_json::to_value(anchored).unwrap().get("anchor"),
        Some(&serde_json::json!("end"))
    );
    let anchored =
        Sub::new("s1", "list").around(Anchor::Row { row_id: 11, side: AnchorSide::Around }, 100);
    assert_eq!(
        serde_json::to_value(anchored).unwrap().get("anchor"),
        Some(&serde_json::json!({"rowId": 11, "side": "around"}))
    );
    let page = Page::new("s1", "list", PageSide::After, 11);
    assert_eq!(serde_json::to_value(&page).unwrap().get("after"), Some(&serde_json::json!(11)));
    assert_eq!(
        serde_json::to_value(page).unwrap().get("maxBytes"),
        Some(&serde_json::json!(262_144))
    );
}

#[test]
fn act_wire_round_trips_without_changing_v1_shapes() {
    let act = Act::new("chat:demo", "append", "a-1", serde_json::json!({"text":"hello"})).since(7);
    let value = serde_json::to_value(Request::Act(act.clone())).unwrap();
    assert_eq!(value["method"], "act");
    assert_eq!(value["params"]["chat"], "chat:demo");
    assert_eq!(value["params"]["since"], 7);
    assert!(
        matches!(serde_json::from_value::<Request>(value), Ok(Request::Act(decoded)) if decoded == act)
    );
}

#[test]
fn act_validation_bounds_id_op_and_body() {
    let valid = Act::new("chat:demo", "append", "a", serde_json::json!({"text":"ok"}));
    assert!(valid.validate().is_ok());
    assert!(Act::new("chat:demo", "append", "", serde_json::Value::Null).validate().is_err());
    assert!(
        Act::new("chat:demo", "append", "x".repeat(MAX_ACT_ID_BYTES + 1), serde_json::Value::Null)
            .validate()
            .is_err()
    );
    assert!(
        Act::new("chat:demo", "x".repeat(MAX_ACT_OP_BYTES + 1), "x", serde_json::Value::Null)
            .validate()
            .is_err()
    );
    assert!(
        Act::new(
            "chat:demo",
            "append",
            "x",
            serde_json::Value::String("x".repeat(MAX_DAEMON_LINE_BYTES))
        )
        .validate()
        .is_err()
    );
}

#[test]
fn ack_and_error_use_compact_camel_case_fields() {
    assert_eq!(
        serde_json::to_string(&Ack { id: "a".into(), seq: 9 }).unwrap(),
        r#"{"id":"a","seq":9}"#
    );
    assert_eq!(
        serde_json::to_string(&Error {
            id: Some("a".into()),
            code: "id_reuse".into(),
            message: "different body".into(),
        })
        .unwrap(),
        r#"{"id":"a","code":"id_reuse","message":"different body"}"#
    );
}

#[test]
fn a_page_of_turns_round_trips_and_is_left_out_when_false() {
    let mut page = Page::new("s1", "chat:c", PageSide::Before, 11);
    assert!(serde_json::to_value(&page).unwrap().get("turns").is_none());
    page.turns = true;
    page.edition = Some(3);
    let text = serde_json::to_string(&page).unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&text).unwrap()["turns"], true);
    let back: Page = serde_json::from_str(&text).unwrap();
    assert!(back.turns && back.fold.is_none());
    assert_eq!(serde_json::to_string(&back).unwrap(), text);
    let old: Page = serde_json::from_str(r#"{"sid":"s1","stream":"chat:c","before":11}"#).unwrap();
    assert!(!old.turns);
}

#[test]
fn old_page_results_default_cold_unread_and_false_stays_off_wire() {
    let old = serde_json::json!({"sid":"s","rows":[],"hasBefore":false,"hasAfter":false});
    let page: PageResult<serde_json::Value> = serde_json::from_value(old).unwrap();
    assert!(!page.cold_unread);
    assert!(serde_json::to_value(page).unwrap().get("coldUnread").is_none());
}

#[test]
fn decoder_handles_chunks_and_rejects_oversized_frames() {
    let frame = Frame::json(FrameKind::Window, &serde_json::json!({"seq": 7})).unwrap();
    let encoded = frame.encode();
    let mut decoder = FrameDecoder::default();
    assert!(decoder.push(encoded.get(..2).unwrap()).unwrap().is_empty());
    assert_eq!(decoder.push(encoded.get(2..).unwrap()).unwrap(), vec![frame]);
    assert!(matches!(
        Frame::new(FrameKind::Delta, vec![0; MAX_FRAME_BYTES]),
        Err(FrameError::TooLarge { .. })
    ));
}
