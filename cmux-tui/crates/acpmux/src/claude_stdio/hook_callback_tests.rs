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
                    assert_eq!(
                        ids,
                        [hook_callback::SYNC_CALLBACK, policy_gate::GATE_CALLBACK],
                        "{tool}: {hooks}"
                    );
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

/// Harness magic `continue` on: a goal chat's later stop goes to the check again while its folder
/// changes, and ends the turn once a stop finds nothing changed; the turn's counts ride on the
/// prompt result's `_meta.harnessMagic.continue`.
#[tokio::test]
async fn continue_sends_a_goal_on_while_its_folder_changes() {
    crate::hub::stop_condition::CONTINUE_FOR_TEST.with(|on| on.set(true));
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
            .args(args)
            .output()
            .unwrap()
    };
    git(&["init", "-q"]);
    std::fs::write(root.join("a.txt"), "one\n").unwrap();
    git(&["add", "a.txt"]);
    git(&["commit", "-q", "-m", "one"]);

    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.stop_condition.store(true, Ordering::Relaxed);
    let stop = |active: bool| {
        let mut call = callback("stop", hook_callback::STOP_CALLBACK, "Stop");
        call["request"]["input"]["stop_hook_active"] = json!(active);
        call["request"]["input"]["cwd"] = json!(root);
        call
    };
    let answer = |reply: Vec<Value>| reply[0]["response"]["response"].clone();
    t.inbound(&stop(false)).await;
    assert_eq!(answer(t.take_stdin_replies().await), json!({}), "the first stop is the check's");
    std::fs::write(root.join("a.txt"), "two\n").unwrap();
    t.inbound(&stop(true)).await;
    assert_eq!(answer(t.take_stdin_replies().await), json!({}), "work moved: the check again");
    t.inbound(&stop(true)).await;
    let ended = answer(t.take_stdin_replies().await);
    assert_eq!(ended["continue"], false, "nothing changed: the turn ends: {ended}");
    let counts = t.stop_continue.lock().await.turn_ended();
    assert_eq!((counts.continued, counts.spin_stopped), (1, 1));
    crate::hub::stop_condition::CONTINUE_FOR_TEST.with(|on| on.set(false));
}
