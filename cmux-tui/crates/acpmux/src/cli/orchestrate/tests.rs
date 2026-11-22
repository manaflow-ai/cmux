use super::*;

#[test]
fn wait_exit_code_reports_permissions_then_failed_turns() {
    assert_eq!(session_exit_code(&json!({"pendingPermissions": 1})), 2);
    assert_eq!(
        session_exit_code(&json!({"pendingPermissions": 1, "lastTurn": {"status": "failed"}})),
        2
    );
    assert_eq!(session_exit_code(&json!({"lastTurn": {"status": "failed"}})), 1);
    assert_eq!(session_exit_code(&json!({"lastTurn": {"status": "completed"}})), 0);
    assert_eq!(session_exit_code(&json!({})), 0);
}

#[test]
fn cursor_parsing() {
    assert_eq!(parse_cursor("abc:12", "abc").unwrap(), 12);
    assert_eq!(parse_cursor("12", "abc").unwrap(), 12);
    assert!(parse_cursor("other:12", "abc").is_err());
    assert!(parse_cursor("abc:x", "abc").is_err());
}

#[test]
fn suppresses_read_payloads_only() {
    let mut sup = ReadSuppressor::default();
    let announce = json!({"kind": "tool_call", "msg": {"params": {"update": {"toolCallId": "t1", "kind": "read", "title": "Read a.txt"}}}});
    sup.apply(announce);
    let update = json!({"kind": "tool_call_update", "msg": {"params": {"update": {"toolCallId": "t1", "content": [{"type": "content", "content": {"type": "text", "text": "secret"}}], "rawOutput": "secret"}}}});
    let out = sup.apply(update);
    assert_eq!(out.pointer("/msg/params/update/rawOutput").unwrap(), "[read output suppressed]");
    assert!(
        out.pointer("/msg/params/update/content/0/content/text")
            .unwrap()
            .as_str()
            .unwrap()
            .contains("suppressed")
    );
    let live = json!({"sessionId": "s", "update": {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "rawOutput": "secret"}});
    let out = sup.apply_update(live);
    assert_eq!(out.pointer("/update/rawOutput").unwrap(), "[read output suppressed]");
    assert_eq!(out["sessionId"], "s");
    let exec = json!({"kind": "tool_call_update", "msg": {"params": {"update": {"toolCallId": "t2", "kind": "execute", "rawOutput": "kept"}}}});
    assert_eq!(sup.apply(exec).pointer("/msg/params/update/rawOutput").unwrap(), "kept");
    let raw = json!({"kind": "claude.user", "msg": {"tool_use_result": {"file": {"content": "secret"}}, "message": {"content": [{"type": "tool_result", "content": "secret"}]}}});
    let out = sup.apply(raw);
    assert_eq!(
        out.pointer("/msg/tool_use_result/file/content").unwrap(),
        "[read output suppressed]"
    );
    assert_eq!(out.pointer("/msg/message/content/0/content").unwrap(), "[read output suppressed]");
}

#[test]
fn matcher_hits_lines() {
    let m = Matcher::Regex(regex::Regex::new(r"tests? pass").unwrap());
    assert_eq!(m.hit("build ok\nall tests pass\n").as_deref(), Some("all tests pass"));
    assert!(Matcher::Text("fail".into()).hit("ok").is_none());
}
