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

/// The answer to `rid` among the stdin replies, waiting on [`Translator::replies_ready`] until
/// `within` passes. Replies to other requests are kept in `others`.
#[cfg(unix)]
async fn reply_for(
    t: &Translator,
    rid: &str,
    within: std::time::Duration,
    others: &mut Vec<Value>,
) -> Option<Value> {
    let ready = t.replies_ready();
    let deadline = tokio::time::Instant::now() + within;
    loop {
        for reply in t.take_stdin_replies().await {
            if reply["response"]["request_id"] == rid {
                return Some(reply);
            }
            others.push(reply);
        }
        if let Some(i) = others.iter().position(|r| r["response"]["request_id"] == rid) {
            return Some(others.remove(i));
        }
        if tokio::time::timeout_at(deadline, ready.notified()).await.is_err() {
            return None;
        }
    }
}

#[cfg(unix)]
fn sync_call(rid: &str, cwd: &std::path::Path) -> Value {
    let mut call = callback(rid, hook_callback::SYNC_CALLBACK, "PreToolUse");
    call["request"]["input"]["cwd"] = json!(cwd);
    call
}

/// A held lock on `folder`'s creation lease, as another process holds it (its own open file).
#[cfg(unix)]
fn hold_creation_lease(folder: &std::path::Path) -> cmux_file_lock::FileLock {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(cmux_git::sync_barrier::creation_lock_path(folder))
        .unwrap();
    match cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive) {
        Ok(lock) => lock,
        Err(_) => panic!("the creation lease is free"),
    }
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn registered_pre_tool_callback_waits_and_failed_sync_returns_denial() {
    use cmux_git::sync_barrier::Sync;
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    let sync = Sync::begin(&repo).unwrap();
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let mut others = Vec::new();
    let out = t.inbound(&sync_call("sync", &repo)).await;
    assert!(out.is_empty());
    let short = std::time::Duration::from_millis(100);
    assert!(reply_for(&t, "sync", short, &mut others).await.is_none(), "it waits for the sync");
    sync.complete().unwrap();
    let reply = reply_for(&t, "sync", std::time::Duration::from_secs(10), &mut others).await;
    assert_eq!(reply.expect("answered once the sync is done")["response"]["response"], json!({}));

    // A failed sync's marker keeps its denial (the settled design).
    drop(Sync::begin(&repo).unwrap());
    t.inbound(&sync_call("sync-2", &repo)).await;
    let reply = reply_for(&t, "sync-2", std::time::Duration::from_secs(10), &mut others).await;
    assert_eq!(
        reply.expect("answered")["response"]["response"]["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        outbound::initialize_request(false)["hooks"]["PreToolUse"][0]["hookCallbackIds"][0],
        hook_callback::SYNC_CALLBACK
    );
}

/// One repo-sync check stuck on a lock never holds up any other line: the reader returns at
/// once, and a second callback (another sync check, and a plain hook) is answered while the
/// first still waits. Before, the check ran inline on the stdout reader, so every later line,
/// and every other hook's answer, waited behind it.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_repo_sync_check_never_delays_another_callbacks_answer() {
    let root = tempfile::tempdir().unwrap();
    let base = root.path().canonicalize().unwrap();
    let (stuck, free) = (base.join("stuck"), base.join("free"));
    let held = hold_creation_lease(&stuck);
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let mut others = Vec::new();

    let started = std::time::Instant::now();
    t.inbound(&sync_call("slow", &stuck)).await;
    assert!(started.elapsed() < std::time::Duration::from_millis(500), "the reader went on");
    t.inbound(&sync_call("fast", &free)).await;
    t.inbound(&callback("plain", "cb-Stop", "Stop")).await;
    let within = std::time::Duration::from_secs(5);
    let fast = reply_for(&t, "fast", within, &mut others).await;
    assert_eq!(fast.expect("the second sync check is answered")["response"]["response"], json!({}));
    assert!(reply_for(&t, "plain", within, &mut others).await.is_some());
    assert!(
        reply_for(&t, "slow", std::time::Duration::from_millis(50), &mut others).await.is_none(),
        "the stuck check still waits"
    );
    drop(held);
    let slow = reply_for(&t, "slow", std::time::Duration::from_secs(10), &mut others).await;
    assert_eq!(slow.expect("answered once the lease is free")["response"]["response"], json!({}));
}

/// The answer goes out by its bound whatever the check does, and a check that ran out of its
/// own budget on a lock, with no marker saying "syncing", lets the tool run. The bounds the
/// registered callback uses stay well under Claude Code's 90 s wait.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_repo_sync_answer_never_exceeds_its_bound() {
    use cmux_git::native_hook::Readiness;
    use std::time::{Duration, Instant};
    let hard = Duration::from_millis(200);

    let started = Instant::now();
    let stuck = hook_callback::bounded_sync_answer(hard, || {
        std::thread::sleep(Duration::from_secs(3));
        Readiness::NotReady("never seen".into())
    })
    .await;
    assert!(started.elapsed() < Duration::from_secs(1), "took {:?}", started.elapsed());
    assert_eq!(stuck, json!({}), "past its bound the tool runs");

    // The real check, its lock held past its budget: undecided, so `{}`, within the budget.
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    let _held = hold_creation_lease(&repo);
    let input = json!({"cwd": repo, "hook_event_name": "PreToolUse"});
    let started = Instant::now();
    let answer = hook_callback::bounded_sync_answer(Duration::from_secs(5), move || {
        cmux_git::native_hook::check("claude", "PreToolUse", &input, Duration::from_millis(200))
    })
    .await;
    assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
    assert_eq!(answer, json!({}));

    let denied =
        hook_callback::bounded_sync_answer(hard, || Readiness::NotReady("sync failed".into()))
            .await;
    assert_eq!(denied["hookSpecificOutput"]["permissionDecision"], "deny");
    assert!(hook_callback::SYNC_HARD_BOUND <= Duration::from_secs(45));
    assert!(hook_callback::SYNC_BUDGET < hook_callback::SYNC_HARD_BOUND);
}
