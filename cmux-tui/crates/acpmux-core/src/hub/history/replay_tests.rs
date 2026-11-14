use super::*;

fn gone(seq: u64, bytes: usize) -> ListItem {
    ListItem::Gone { seq, origin: "local".into(), chat_id: "x".repeat(bytes) }
}

#[test]
fn replay_uses_small_frames_without_losing_operations() {
    let mut history = History::new();
    for seq in 1..=500 {
        history.append(&gone(seq, 1024)).unwrap();
    }
    let snapshot = history.snapshot_after(0);
    let mut cursor = 0;
    while cursor < 500 {
        let span = snapshot.after_frame(cursor, 500, 256 * 1024).unwrap();
        assert!(span.bytes.len() <= 64 * 1024);
        assert!(span.bytes.capacity() <= 64 * 1024);
        let expected = history.after_frame(cursor, span.last_seq, span.bytes.len()).unwrap();
        assert_eq!(span.bytes, expected.bytes);
        assert!(span.last_seq > cursor);
        cursor = span.last_seq;
    }
    assert_eq!(cursor, 500);
}

#[test]
fn replay_preserves_large_operations_and_the_callers_hard_budget() {
    let mut history = History::new();
    history.append(&gone(1, 16)).unwrap();
    history.append(&gone(2, 96 * 1024)).unwrap();
    history.append(&gone(3, 16)).unwrap();
    let snapshot = history.snapshot_after(0);
    let first = snapshot.after_frame(0, 3, 256 * 1024).unwrap();
    assert_eq!(first.last_seq, 1);
    let large = snapshot.after_frame(1, 3, 256 * 1024).unwrap();
    assert_eq!(large.last_seq, 2);
    assert!(large.bytes.len() > 64 * 1024);
    let exact = snapshot.after_frame(1, 3, large.bytes.len()).unwrap();
    assert_eq!(exact.bytes, large.bytes);
    assert!(snapshot.after_frame(1, 3, large.bytes.len() - 1).is_none());
    let last = snapshot.after_frame(2, 3, 256 * 1024).unwrap();
    assert_eq!(last.last_seq, 3);
    for span in [first, large, last] {
        let expected = history.after_frame(span.last_seq - 1, span.last_seq, 256 * 1024).unwrap();
        assert_eq!(span.bytes, expected.bytes);
    }
}
