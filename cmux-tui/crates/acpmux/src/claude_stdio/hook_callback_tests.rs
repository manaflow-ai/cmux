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

/// The answer to the pre-tool callback `rid`: on Unix the repo-sync callback answers it off
/// the reader, so it comes once [`Translator::replies_ready`] fires.
async fn answer_to(t: &Translator, rid: &str) -> Value {
    #[cfg(unix)]
    return reply_for(t, rid, std::time::Duration::from_secs(10), &mut Vec::new())
        .await
        .expect("answered");
    #[cfg(not(unix))]
    t.take_stdin_replies().await.remove(0)
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
        // A lease file is shared with other holders: never truncate it.
        .truncate(false)
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
    t.plugin_hook_home.set(root.path().into()).unwrap();
    let mut call = sync_call("sync", &repo);
    call["request"]["input"]["tool_name"] = json!("Bash");
    call["request"]["input"]["tool_input"] = json!({"command": "acpmux ls"});
    call["request"]["input"]["agent_id"] = json!("child");
    let mut others = Vec::new();
    let out = t.inbound(&call).await;
    assert!(out.is_empty());
    let short = std::time::Duration::from_millis(100);
    assert!(reply_for(&t, "sync", short, &mut others).await.is_none(), "it waits for the sync");
    sync.complete().unwrap();
    let reply = reply_for(&t, "sync", std::time::Duration::from_secs(10), &mut others).await;
    let reply = reply.expect("answered once the sync is done");
    // The tool runs, so the same reply carries the plugin's decision.
    let mark = reply.pointer("/response/response/hookSpecificOutput/updatedInput/command");
    assert!(mark.unwrap().as_str().unwrap().ends_with(":child\nacpmux ls"));

    // A failed sync's marker keeps its denial (the settled design), with no plugin input.
    drop(Sync::begin(&repo).unwrap());
    call["request_id"] = json!("sync-2");
    t.inbound(&call).await;
    let reply = reply_for(&t, "sync-2", std::time::Duration::from_secs(10), &mut others).await;
    let reply = reply.expect("answered");
    assert!(reply.pointer("/response/response/hookSpecificOutput/updatedInput").is_none());
    assert_eq!(reply["response"]["response"]["hookSpecificOutput"]["permissionDecision"], "deny");
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

/// The answer goes out by its bound whatever the check does, denying the tool past it, and a
/// check that ran out of its own budget on a lock, with no marker saying "syncing", lets the
/// tool run. The bounds the
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
    assert_eq!(
        stuck["hookSpecificOutput"]["permissionDecision"], "deny",
        "past its bound the tool is denied: {stuck}"
    );

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

/// A repository sync that never finishes still gets an answer before the callback's deadline:
/// the barrier's denial (it fails closed), off the reader, with the miss counted in
/// `gauges.hookAnswers`. The deadline is shortened, as the blocking wait holds a paused clock
/// still.
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
    let reply = answer_to(&t, "stalled").await;
    let took = started.elapsed();
    sync.complete().unwrap();
    assert!(took >= deadline && took < cmux_git::native_hook::WAIT, "{took:?}");
    // Fails closed: a stalled barrier denies the tool, never lets it run unchecked.
    let decision = &reply["response"]["response"]["hookSpecificOutput"];
    assert_eq!(decision["permissionDecision"], "deny", "{reply}");
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
            let reply = answer_to(&t, "mark").await;
            let mark = reply.pointer("/response/response/hookSpecificOutput/updatedInput/command");
            if plugin {
                assert!(mark.unwrap().as_str().unwrap().ends_with(":child\nacpmux ls"));
            } else {
                assert!(mark.is_none());
            }
            call["request"]["input"]["tool_name"] = json!("mcp__acpmux__send");
            call["request"]["input"]["tool_use_id"] = json!("toolu_1");
            t.inbound(&call).await;
            assert_eq!(answer_to(&t, "mark").await["response"]["response"], json!({}));
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
