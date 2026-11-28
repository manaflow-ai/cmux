use super::*;

#[test]
fn snapshot_reserves_only_the_requested_suffix_across_wraps() {
    let mut history = History::with_capacity(4096);
    for seq in 1..300 {
        history.append(&gone(seq)).unwrap();
    }
    let last = history.last_seq().unwrap();
    for cursor in history.first - 1..=last {
        let snapshot = history.snapshot_after(cursor);
        let expected = history.after(cursor, last).unwrap();
        assert_eq!(snapshot.bytes.as_ref(), expected);
        assert_eq!(snapshot.reserved_bytes, expected.len(), "cursor {cursor}");
    }
}

#[test]
fn replay_frames_match_live_ring_operations() {
    let mut history = History::with_capacity(4096);
    for seq in 1..300 {
        history.append(&gone(seq)).unwrap();
    }
    let first = history.first - 1;
    let last = history.last_seq().unwrap();
    let snapshot = history.snapshot_after(first);
    let mut cursor = first;
    while cursor < last {
        let span = snapshot.after_frame(cursor, last, 512).unwrap();
        let expected = history.after_frame(cursor, last, 512).unwrap();
        assert_eq!(span.bytes, expected.bytes);
        assert_eq!(span.last_seq, expected.last_seq);
        cursor = span.last_seq;
    }
}

fn gone(seq: u64) -> ListItem {
    ListItem::Gone { seq, origin: "remote".into(), chat_id: format!("id-{seq}") }
}

#[test]
fn wrapping_and_byte_eviction_preserve_consecutive_ops() {
    let mut history = History::with_capacity(230);
    let buffers = (history.bytes.as_ptr(), history.entries.as_ptr());
    for seq in 1..1000 {
        history.append(&gone(seq)).unwrap();
        assert!(history.used <= 230);
        assert_eq!((history.bytes.as_ptr(), history.entries.as_ptr()), buffers);
        let first = history.first;
        assert!(history.after(first.saturating_sub(2), seq).is_none() || first == 1);
        let items = decode(history.after(first - 1, seq).unwrap()).unwrap();
        assert_eq!(items.len(), history.len);
        for (offset, item) in items.into_iter().enumerate() {
            match item {
                ListItem::Gone { seq, origin, chat_id } => {
                    assert_eq!(seq, first + offset as u64);
                    assert_eq!(origin, "remote");
                    assert_eq!(chat_id, format!("id-{seq}"));
                }
                _ => panic!("expected gone"),
            }
        }
    }
}

#[test]
fn exact_full_buffer_and_partial_replay_keep_the_byte_span() {
    let mut probe = History::new();
    probe.append(&gone(1)).unwrap();
    let mut history = History::with_capacity(2 * probe.used);
    history.append(&gone(1)).unwrap();
    history.append(&gone(2)).unwrap();
    assert_eq!(history.used, history.bytes.len());
    let snapshot = history.snapshot_after(0);
    assert_eq!(snapshot.reserved_bytes, history.used);
    assert_eq!(snapshot.bytes.as_ref(), history.after(0, 2).unwrap());
    assert_eq!(decode(history.after(0, 2).unwrap()).unwrap().len(), 2);
    assert_eq!(decode(history.after(1, 2).unwrap()).unwrap().len(), 1);
    history.append(&gone(3)).unwrap();
    assert!(history.after(0, 3).is_none());
    assert_eq!(decode(history.after(1, 3).unwrap()).unwrap().len(), 2);
    let snapshot = history.snapshot_after(1);
    assert_eq!(snapshot.reserved_bytes, history.used);
    assert_eq!(snapshot.bytes.as_ref(), history.after(1, 3).unwrap());
}

#[test]
fn raw_frame_span_inserts_only_operation_separators_and_stops_at_the_cap() {
    let mut history = History::new();
    history.append(&gone(1)).unwrap();
    history.append(&gone(2)).unwrap();
    assert!(history.after_frame(0, 2, 1).is_none());
    let one_size = history.after(0, 1).unwrap().len();
    let one = history.after_frame(0, 2, one_size).unwrap();
    assert!(one.is_valid());
    assert_eq!(one.last_seq, 1);
    let parsed: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(one.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(parsed.len(), 1);
    let both = history.after_frame(0, 2, usize::MAX).unwrap();
    assert!(both.is_valid());
    assert_eq!(both.last_seq, 2);
    let parsed: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(both.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(parsed.len(), 2);
}

#[test]
fn copied_span_validation_survives_overwrite_and_detects_damaged_bytes() {
    let mut history = History::with_capacity(230);
    history.append(&gone(1)).unwrap();
    let copied = history.after_frame(0, 1, 230).unwrap();
    // Damage the ring after the copy. Validation owns its bytes and may
    // run while the writer replaces or evicts the original record.
    let first = history.entries.get(history.head).unwrap().start;
    *history.bytes.get_mut(first).unwrap() = b'!';
    let damaged = history.after_frame(0, 1, 230).unwrap();
    assert!(copied.is_valid());
    assert!(!damaged.is_valid());
    for seq in 2..100 {
        history.append(&gone(seq)).unwrap();
    }
    assert!(copied.is_valid());
    assert!(!damaged.is_valid());
}

#[test]
fn a_full_ring_replays_in_bounded_complete_operation_spans() {
    let mut history = History::new();
    let mut last = 0;
    while history.first_seq().is_none_or(|first| first == 1) {
        last += 1;
        history.append(&gone(last)).unwrap();
    }
    assert!(history.used > CREDIT_WINDOW_BYTES - 100);
    let mut cursor = history.first_seq().unwrap() - 1;
    let mut frames = 0;
    let mut rows = 0;
    while cursor < last {
        let span = history.after_frame(cursor, last, 256 * 1024).unwrap();
        assert!(span.is_valid());
        assert!(span.bytes.len() <= 256 * 1024);
        let ops: Vec<serde_json::Value> =
            serde_json::from_str(&format!("[{}]", String::from_utf8(span.bytes).unwrap())).unwrap();
        for (offset, op) in ops.iter().enumerate() {
            assert_eq!(op["seq"], cursor + offset as u64 + 1);
        }
        assert_eq!(span.last_seq, cursor + ops.len() as u64);
        cursor = span.last_seq;
        rows += ops.len();
        frames += 1;
    }
    assert_eq!(rows, history.len());
    assert!(frames >= 4);
}

#[test]
fn summary_bytes_release_rows_and_round_trip_escaped_keys() {
    let mut history = History::new();
    let mut summary = Summary::new("chat\"\n雪");
    summary.origin = "peer\\two".into();
    summary.extra =
        serde_json::value::RawValue::from_string(r#"{"nested": [1, true, {"x": "y"}]}"#.into())
            .unwrap();
    let row = Arc::new(summary);
    let weak = Arc::downgrade(&row);
    history.append(&ListItem::Summary(SummaryEvent { seq: 19, summary: row.clone() })).unwrap();
    drop(row);
    assert!(weak.upgrade().is_none());
    let items = decode(history.after(18, 19).unwrap()).unwrap();
    let ListItem::Summary(event) = items.first().unwrap() else { panic!("summary") };
    assert_eq!(event.seq, 19);
    assert_eq!(event.summary.chat_id, "chat\"\n雪");
    assert_eq!(event.summary.origin, "peer\\two");
    assert_eq!(event.summary.extra.get(), r#"{"nested": [1, true, {"x": "y"}]}"#);
    assert!(history.after(17, 19).is_none());
    assert!(history.after(19, 19).unwrap().is_empty());
}

#[test]
fn peer_history_keeps_only_local_rows_and_writes_valid_raw_ops() {
    let mut history = PeerHistory::new(0);
    let mut local = Summary::new("local-chat");
    local.origin = "local".into();
    local.peer_form = Some(
        serde_json::value::RawValue::from_string(
            r#"{"chatId":"local-chat","title":"masked"}"#.into(),
        )
        .unwrap(),
    );
    let mut remote = Summary::new("remote-chat");
    remote.origin = "other".into();
    history.append(1, Some(&remote)).unwrap();
    history.append(2, Some(&local)).unwrap();
    history.append_gone(3, "other", "remote-chat").unwrap();
    history.append_gone(4, "local", "local-chat").unwrap();

    let span = history.after_frame(0, 4, usize::MAX).unwrap();
    assert!(span.is_valid());
    let values: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(span.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(values.len(), 2);
    assert_eq!(values[0]["seq"], 2);
    assert_eq!(values[0]["summary"]["title"], "masked");
    assert_eq!(values[1]["seq"], 4);
    assert_eq!(values[1]["origin"], "local");
}

#[test]
fn peer_history_floor_requires_a_window_before_creation() {
    let mut history = PeerHistory::new(10);
    assert!(!history.can_resume(5));
    assert!(history.after_frame(5, 10, usize::MAX).is_none());
    let end = history.after_frame(10, 10, usize::MAX).unwrap();
    assert!(end.bytes.is_empty());
    assert_eq!(end.last_seq, 10);

    let remote = Summary::new("remote-only");
    let mut remote = remote;
    remote.origin = "remote".into();
    history.append(11, Some(&remote)).unwrap();
    history.append_gone(12, "remote", "remote-only").unwrap();
    assert!(history.after_frame(5, 12, usize::MAX).is_none());
    assert!(history.after_frame(10, 12, usize::MAX).unwrap().bytes.is_empty());
}

#[test]
fn peer_history_floor_advances_when_entries_are_evicted() {
    let mut history = PeerHistory::with_capacity(0, 128);
    for seq in 1..32 {
        history.append_gone(seq, "local", &format!("chat-{seq}")).unwrap();
    }
    assert!(history.floor > 0);
    let floor = history.floor;
    assert!(history.after_frame(floor.saturating_sub(1), history.last, usize::MAX).is_none());
    assert!(history.can_resume(floor));
}

#[test]
fn failed_or_discontinuous_append_never_leaves_a_resumable_gap() {
    let mut history = History::with_capacity(128);
    history.append(&gone(1)).unwrap();
    let row = Arc::new(Summary::new("too-large-for-test-ring"));
    assert!(history.append(&ListItem::Summary(SummaryEvent { seq: 2, summary: row })).is_err());
    assert!(history.after(0, 2).is_none());
    history.append(&gone(3)).unwrap();
    assert!(history.after(1, 3).is_none());
    assert_eq!(decode(history.after(2, 3).unwrap()).unwrap().len(), 1);
    history.append(&gone(5)).unwrap();
    assert!(history.after(3, 5).is_none());
    assert_eq!(decode(history.after(4, 5).unwrap()).unwrap().len(), 1);
}
