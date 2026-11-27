//! Claude Code's `hook_callback` control requests (`hook_callback.rs`).

use super::*;

fn callback(rid: &str, callback_id: &str, event: &str) -> Value {
    json!({"type": "control_request", "request_id": rid, "request": {
        "subtype": "hook_callback", "callback_id": callback_id, "tool_use_id": "t-1",
        "input": {"session_id": "s", "cwd": "/work", "hook_event_name": event}}})
}

/// A callback gets a success with an empty hook output: carry on as if no hook ran. An error
/// leaves Claude Code's turn waiting (2.1.310 never sent its result after an error to `Stop`).
#[tokio::test]
async fn a_hook_callback_is_answered_with_no_decision() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    for (rid, event) in [("h1", "Stop"), ("h2", "PreToolUse"), ("h3", "UserPromptSubmit")] {
        let out = t.inbound(&callback(rid, &format!("cb-{event}"), event)).await;
        assert!(out.is_empty(), "nothing for the hub: {out:?}");
        let replies = t.take_stdin_replies().await;
        assert_eq!(
            replies,
            vec![json!({"type": "control_response", "response": {
                "subtype": "success", "request_id": rid, "response": {}}})]
        );
    }
}

/// Other control requests acpmux does not support keep the error reply.
#[tokio::test]
async fn other_unsupported_control_requests_keep_the_error() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&json!({"type": "control_request", "request_id": "m1",
        "request": {"subtype": "mcp_message", "server_name": "x", "message": {}}}))
        .await;
    let replies = t.take_stdin_replies().await;
    assert_eq!(replies[0]["response"]["subtype"], "error");
    assert_eq!(replies[0]["response"]["request_id"], "m1");
}

#[cfg(unix)]
#[tokio::test]
async fn registered_pre_tool_callback_waits_and_failed_sync_returns_denial() {
    use cmux_git::sync_barrier::Sync;
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    let sync = Sync::begin(&repo).unwrap();
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let mut call = callback("sync", hook_callback::SYNC_CALLBACK, "PreToolUse");
    call["request"]["input"]["cwd"] = json!(repo);
    let pending = t.answer_hook_callback("sync", &call["request"]);
    tokio::pin!(pending);
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), &mut pending).await.is_err()
    );
    sync.complete().unwrap();
    pending.await;
    assert_eq!(t.take_stdin_replies().await[0]["response"]["response"], json!({}));

    drop(Sync::begin(&repo).unwrap());
    t.answer_hook_callback("sync", &call["request"]).await;
    let replies = t.take_stdin_replies().await;
    assert_eq!(
        replies[0]["response"]["response"]["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        outbound::initialize_request(false)["hooks"]["PreToolUse"][0]["hookCallbackIds"][0],
        hook_callback::SYNC_CALLBACK
    );
}
