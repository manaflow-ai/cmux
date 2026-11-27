use super::*;

#[test]
fn notices_include_tool_inbox_and_host_records() {
    for kind in ["notice", "inbox_notice"] {
        assert!(is_notice(&json!({"kind": "user_message", "msg": {
            "_meta": {"provenance": {"kind": kind}}, "text": "build finished"}})));
    }
    assert!(is_notice(&json!({"kind": "host_notice", "msg": {"text": "resized"}})));
    assert!(!is_notice(&json!({"kind": "user_message", "msg": {"text": "hello"}})));
    assert!(!is_notice(&json!({"kind": "permission_request", "msg": {}})));
}
