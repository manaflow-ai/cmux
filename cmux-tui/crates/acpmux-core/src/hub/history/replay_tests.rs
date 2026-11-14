use super::*;

#[test]
fn replay_reuses_only_one_buffer_and_releases_it_with_the_snapshot() {
    let mut history = History::new();
    for seq in 1..=500 {
        history
            .append(&ListItem::Gone { seq, origin: "local".into(), chat_id: "x".repeat(1024) })
            .unwrap();
    }
    let snapshot = history.snapshot_after(0);
    snapshot.prepare_frame_buffer();
    let allocation = snapshot.frame_buffer.lock().unwrap().as_ptr();
    let weak = Arc::downgrade(&snapshot.frame_buffer);
    let first = snapshot.after_frame(0, 500, 256 * 1024).unwrap();
    assert_eq!(first.bytes.as_ptr(), allocation);
    assert_eq!(snapshot.frame_buffer.lock().unwrap().capacity(), 0);
    let cursor = first.last_seq;
    let expected = history.after_frame(0, cursor, 256 * 1024).unwrap();
    assert_eq!(first.bytes, expected.bytes);
    drop(first);
    assert_eq!(snapshot.frame_buffer.lock().unwrap().as_ptr(), allocation);
    let second = snapshot.after_frame(cursor, 500, 256 * 1024).unwrap();
    assert_eq!(second.bytes.as_ptr(), allocation);
    drop(snapshot);
    assert!(weak.upgrade().is_none(), "an in-flight span kept the spare pool alive");
    drop(second);
    assert!(weak.upgrade().is_none());
}
