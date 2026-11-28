use super::*;

#[test]
fn a_new_daemon_says_until_when_it_may_be_restored() {
    let v = json!({"sessionId": "abc", "purged": false, "deleted": true, "restorableUntil": 1_000});
    let line = kill_line(true, false, &v);
    assert!(line.starts_with("deleted; restorable until "), "{line}");
    assert!(line.contains("acpmux session undelete abc"), "{line}");
}

#[test]
fn an_older_daemon_deleted_at_once_and_the_line_says_so() {
    // An older daemon's reply to `{purge: true, grace: true}`: it ignored `grace`.
    let v = json!({"sessionId": "abc", "purged": true});
    assert!(kill_line(true, false, &v).contains("deleted the chat at once"));
    assert_eq!(kill_line(true, true, &v), "purged");
    assert_eq!(kill_line(false, false, &json!({"purged": false})), "closed");
}

#[test]
fn the_list_names_each_deleted_chat() {
    let v = json!({"sessions": [{"sessionId": "abc", "name": "lane", "restorableUntil": 5}]});
    let text = render(&v);
    assert!(text.starts_with("lane\tabc\trestorable until "), "{text}");
    assert_eq!(render(&json!({"sessions": []})), "no deleted chats\n");
}
