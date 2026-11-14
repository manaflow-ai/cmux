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
