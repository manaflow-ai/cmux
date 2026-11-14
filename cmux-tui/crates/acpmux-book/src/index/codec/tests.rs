use super::*;

#[test]
fn pre_peer_form_records_still_decode() {
    // Fields of 5b's length-prefixed record, followed by its text object.
    let mut bytes = 7u64.to_le_bytes().to_vec();
    bytes.push(0);
    key(&mut bytes, &RowKey::new("local", "old")).unwrap();
    bytes.push(0);
    bytes.extend_from_slice(br#"{"title":"old","harness":"claude","state":"closed","lastActivity":42,"unread":0,"workspace":null,"pinned":false,"extra":{"name":"old"}}"#);
    let row = match decode(&bytes).unwrap() {
        LogRecord::Row(row) => row,
        LogRecord::Origin(_) => panic!("expected a row record"),
    };
    assert_eq!(row.seq, 7);
    assert_eq!(row.summary.chat_id, "old");
    assert!(row.summary.peer_form.is_none());
    assert!(!row.summary.archived);
    assert_eq!(row.summary.extra.get(), r#"{"name":"old"}"#);
}
