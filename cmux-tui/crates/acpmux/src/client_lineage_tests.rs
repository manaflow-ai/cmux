use super::*;

#[test]
fn a_session_new_names_the_env_tool_call_once() {
    let p = json!({"cwd": "/tmp", "_meta": {"acpmux": {"name": "kid"}}});
    let sent = with_spawn_tool_call(p.clone(), Some("toolu_7".into()));
    assert_eq!(sent["_meta"]["acpmux"]["spawnToolCallId"], "toolu_7");
    assert_eq!(sent["_meta"]["acpmux"]["name"], "kid");
    assert_eq!(with_spawn_tool_call(p.clone(), None), p);
    assert_eq!(with_spawn_tool_call(p.clone(), Some(String::new())), p);
    let named = json!({"_meta": {"acpmux": {"spawnToolCallId": "mine"}}});
    let sent = with_spawn_tool_call(named, Some("env".into()));
    assert_eq!(sent["_meta"]["acpmux"]["spawnToolCallId"], "mine");
    let bare = with_spawn_tool_call(json!({"cwd": "/tmp"}), Some("t".into()));
    assert_eq!(bare["_meta"]["acpmux"]["spawnToolCallId"], "t");
}

#[test]
fn a_parentless_session_new_asks_for_no_parent() {
    let sent = parentless(json!({"cwd": "/tmp", "_meta": {"acpmux": {"ephemeral": true}}}));
    assert_eq!(sent["_meta"]["acpmux"]["parent"], Value::Null);
    assert!(sent["_meta"]["acpmux"].as_object().unwrap().contains_key("parent"));
    assert_eq!(sent["_meta"]["acpmux"]["ephemeral"], true);
}

/// The tag request goes only to a daemon that records no lineage: the CLI path of a
/// proven caller makes none, and a root the daemon made (an unproven caller) is never
/// tagged under the env's session.
#[test]
fn only_a_daemon_without_lineage_gets_the_spawned_by_tag() {
    let recorded = json!({"sessionId": "c", "_meta": {"acpmux": {"parent": "p"}}});
    assert!(!reply_lacks_lineage(&recorded));
    let root = json!({"sessionId": "c", "_meta": {"acpmux": {"parent": null}}});
    assert!(!reply_lacks_lineage(&root), "a new daemon's root is final");
    let older_daemon = json!({"sessionId": "c", "_meta": {"acpmux": {"name": "c"}}});
    assert!(reply_lacks_lineage(&older_daemon));
    assert!(reply_lacks_lineage(&json!({"sessionId": "c"})));
    let on_a_peer = json!({"sessionId": "c", "peer": "box", "_meta": {"acpmux": {"parent": null}}});
    assert!(reply_lacks_lineage(&on_a_peer));
}
