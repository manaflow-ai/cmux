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
    t.plugin_hook_home.set(root.path().into()).unwrap();
    let mut call = callback("sync", hook_callback::SYNC_CALLBACK, "PreToolUse");
    call["request"]["input"]["tool_name"] = json!("Bash");
    call["request"]["input"]["tool_input"] = json!({"command": "acpmux ls"});
    call["request"]["input"]["agent_id"] = json!("child");
    call["request"]["input"]["cwd"] = json!(repo);
    let pending = t.answer_hook_callback("sync", &call["request"]);
    tokio::pin!(pending);
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), &mut pending).await.is_err()
    );
    sync.complete().unwrap();
    pending.await;
    let replies = t.take_stdin_replies().await;
    assert_eq!(replies.len(), 1);
    let mark = replies[0].pointer("/response/response/hookSpecificOutput/updatedInput/command");
    assert!(mark.unwrap().as_str().unwrap().ends_with(":child\nacpmux ls"));

    drop(Sync::begin(&repo).unwrap());
    t.answer_hook_callback("sync", &call["request"]).await;
    let replies = t.take_stdin_replies().await;
    assert_eq!(replies.len(), 1);
    assert!(replies[0].pointer("/response/response/hookSpecificOutput/updatedInput").is_none());
    assert_eq!(
        replies[0]["response"]["response"]["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        outbound::initialize_request(false)["hooks"]["PreToolUse"][0]["hookCallbackIds"][0],
        hook_callback::SYNC_CALLBACK
    );
}

/// A repository sync that never finishes still gets an answer before the callback's deadline:
/// the safe default (`{}`, the tool runs), with the miss counted in `gauges.hookAnswers`. The
/// deadline is shortened, as the blocking wait holds a paused clock still.
#[cfg(unix)]
#[tokio::test]
async fn a_stalled_sync_fails_closed_at_its_deadline() {
    use cmux_git::sync_barrier::Sync;
    use std::time::Duration;
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().canonicalize().unwrap().join("repo");
    let sync = Sync::begin(&repo).unwrap();
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let mut call = callback("stalled", hook_callback::SYNC_CALLBACK, "PreToolUse");
    call["request"]["input"]["tool_name"] = json!("Read");
    call["request"]["input"]["cwd"] = json!(repo);
    let answers = crate::gauges::hook_answers();
    let misses = answers.misses();
    let started = std::time::Instant::now();
    let deadline = Duration::from_millis(200);
    let answer = t.answer_hook_callback("stalled", &call["request"]);
    hook_callback::DEADLINE.scope(deadline, answer).await;
    let took = started.elapsed();
    sync.complete().unwrap();
    assert!(took >= deadline && took < cmux_git::native_hook::WAIT, "{took:?}");
    // Fails closed: a stalled barrier denies the tool, never lets it run unchecked.
    let replies = t.take_stdin_replies().await;
    assert_eq!(replies.len(), 1, "{replies:?}");
    let decision = &replies[0]["response"]["response"]["hookSpecificOutput"];
    assert_eq!(decision["permissionDecision"], "deny", "{replies:?}");
    // Other tests in this process may miss too: at least this one.
    assert!(answers.misses() > misses);
    let status = crate::gauges::global().status();
    assert!(status["hookAnswers"]["misses"].as_u64().unwrap() > misses, "{status}");
    assert!(status["hookAnswers"]["count"].as_u64().unwrap() >= 1, "{status}");
}

/// Every callback's deadline falls before the timeout Claude Code is given for it, and a stalled
/// tool answer gives way to the default at it.
#[tokio::test(start_paused = true)]
async fn a_stalled_tool_answer_gives_way_at_its_deadline() {
    #[cfg(unix)]
    let sync = [hook_callback::SYNC_TIMEOUT_S];
    #[cfg(not(unix))]
    let sync: [u64; 0] = [];
    for timeout in
        [hook_callback::STOP_TIMEOUT_S, hook_callback::TOOL_TIMEOUT_S].into_iter().chain(sync)
    {
        assert!(hook_callback::deadline(timeout) < std::time::Duration::from_secs(timeout));
    }
    let misses = crate::gauges::hook_answers().misses();
    let started = tokio::time::Instant::now();
    let stalled = std::future::pending::<Option<Value>>();
    let deadline = hook_callback::deadline(hook_callback::TOOL_TIMEOUT_S);
    assert_eq!(hook_callback::within(deadline, stalled, None).await, None);
    assert_eq!(started.elapsed(), deadline);
    assert!(crate::gauges::hook_answers().misses() > misses);
}

/// Local session tools and the goal opt in independently. All the installed handlers run over
/// Claude's existing control stream, including at the second attempted stop of a goal.
#[tokio::test]
async fn session_hook_callbacks_use_the_control_stream() {
    let home = tempfile::tempdir().unwrap();
    for plugin in [false, true] {
        for goal in [false, true] {
            let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
            if plugin {
                t.plugin_hook_home.set(home.path().into()).unwrap();
            }
            t.stop_condition.store(goal, Ordering::Relaxed);
            let init = Message::request(1, method::INITIALIZE, json!({}));
            let Outbound::LinesThenReply(lines, _) = t.outbound(&init).await else {
                panic!("initialize must write Claude's hook registration");
            };
            let hooks = &lines[0]["request"]["hooks"];
            for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStop", "Stop"]
            {
                let id = if event == "Stop" {
                    hook_callback::STOP_CALLBACK
                } else {
                    hook_callback::TOOL_CALLBACK
                };
                let mut entries = hooks[event].as_array().into_iter().flatten();
                assert_eq!(
                    entries.clone().filter(|e| e["hookCallbackIds"] == json!([id])).count(),
                    usize::from(if event == "Stop" {
                        goal
                    } else {
                        plugin && !(cfg!(unix) && event == "PreToolUse")
                    }),
                    "{event}: {hooks}"
                );
                assert!(entries.all(|e| e.get("command").is_none()));
            }
            // On Unix the same wildcard sync callback serves the plugin. The independently
            // cancellable policy gate keeps its own fail-closed matcher and time budget.
            #[cfg(unix)]
            let pre_tool = {
                for tool in ["Bash", "Edit", "Write", "mcp__acpmux__send"] {
                    let ids: Vec<_> = hooks["PreToolUse"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter(|e| {
                            e["matcher"].as_str().unwrap().split('|').any(|p| p == "*" || p == tool)
                        })
                        .flat_map(|e| e["hookCallbackIds"].as_array().unwrap().iter())
                        .map(|id| id.as_str().unwrap())
                        .collect();
                    // Harness magic `dedupe` (`dedupe.rs`) adds its own callback for Read and
                    // Bash, after the gate, unless the setting or its kill switch turns it off.
                    let mut want = vec![hook_callback::SYNC_CALLBACK, policy_gate::GATE_CALLBACK];
                    if dedupe::enabled() && dedupe::DEDUPE_MATCHER.split('|').any(|p| p == tool) {
                        want.push(dedupe::DEDUPE_CALLBACK);
                    }
                    assert_eq!(ids, want, "{tool}: {hooks}");
                }
                hook_callback::SYNC_CALLBACK
            };
            #[cfg(not(unix))]
            let pre_tool = hook_callback::TOOL_CALLBACK;
            let mut call = callback("mark", pre_tool, "PreToolUse");
            call["request"]["input"]["cwd"] = json!(home.path());
            call["request"]["input"]["tool_name"] = json!("Bash");
            call["request"]["input"]["tool_input"] = json!({"command": "acpmux ls"});
            call["request"]["input"]["agent_id"] = json!("child");
            t.inbound(&call).await;
            let reply = t.take_stdin_replies().await;
            let mark =
                reply[0].pointer("/response/response/hookSpecificOutput/updatedInput/command");
            if plugin {
                assert!(mark.unwrap().as_str().unwrap().ends_with(":child\nacpmux ls"));
            } else {
                assert!(mark.is_none());
            }
            call["request"]["input"]["tool_name"] = json!("mcp__acpmux__send");
            call["request"]["input"]["tool_use_id"] = json!("toolu_1");
            t.inbound(&call).await;
            assert_eq!(t.take_stdin_replies().await[0]["response"]["response"], json!({}));
            assert_eq!(crate::subagent_call::of(home.path(), "acp-1", "toolu_1").is_some(), plugin);
            crate::subagent_call::end(home.path(), "acp-1", "toolu_1");
            let mut stop = callback("stop", hook_callback::STOP_CALLBACK, "Stop");
            stop["request"]["input"]["stop_hook_active"] = json!(true);
            t.inbound(&stop).await;
            let reply = t.take_stdin_replies().await;
            assert_eq!(
                reply[0].pointer("/response/response/continue"),
                goal.then_some(&Value::Bool(false))
            );
        }
    }
}
