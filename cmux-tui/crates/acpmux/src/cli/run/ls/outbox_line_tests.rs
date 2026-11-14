use super::*;

#[test]
fn ls_ends_with_the_messages_still_queued() {
    assert_eq!(outbox_line(&json!({"outboxPending": 0})), None);
    assert_eq!(outbox_line(&json!({})), None);
    assert_eq!(
        outbox_line(&json!({"outboxPending": 2})).as_deref(),
        Some("2 messages queued here, not delivered yet (acpmux send --status)")
    );
}
