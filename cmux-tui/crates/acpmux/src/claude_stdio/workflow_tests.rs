//! Claude's dynamic workflows and background agents as a chat's live
//! subagents (Lawrence 2026-10-14: the GUI lists them like Claude Code's task
//! panel). A Workflow tool call is a background subagent of kind `workflow`;
//! Claude's `task_progress` lines become `subagent_progress` updates with the
//! tokens, elapsed time, current step and, for a workflow, its agent counts
//! (read from the run's `journal.jsonl`); its `task_notification` ends it.
//! The lines are trimmed from a Claude Code 2.1.299 stream-json run.

use super::*;
use crate::subagents::SubagentTree;

fn updates(msgs: &[Message]) -> Vec<(String, Value)> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { method: m, params: Some(p) } if m == method::SESSION_UPDATE => {
                Some((p["sessionId"].as_str().unwrap_or("").to_owned(), p["update"].clone()))
            }
            _ => None,
        })
        .collect()
}

fn of_kind<'a>(out: &'a [(String, Value)], kind: &str) -> Vec<&'a Value> {
    out.iter().filter(|(_, u)| u["sessionUpdate"] == kind).map(|(_, u)| u).collect()
}

fn workflow_call(id: &str) -> Value {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": id, "name": "Workflow",
        "input": {"scriptPath": "/tmp/wf.js"}}]}})
}

fn launched(id: &str, transcript_dir: &str) -> Value {
    json!({"type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "Workflow launched in background. Task ID: wx2"}]},
        "tool_use_result": {"status": "async_launched", "taskId": "wx2", "taskType": "local_workflow",
            "workflowName": "probe", "runId": "wf_4fe", "summary": "Two tiny agents", "transcriptDir": transcript_dir}})
}

/// A run's transcript dir whose journal says `started` agents started and `done` returned.
fn journal(started: usize, done: usize) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-wf-{}-{started}-{done}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut lines = vec![json!({"type": "launched"})];
    lines.extend((0..started).map(|n| json!({"type": "started", "agentId": format!("a{n}"), "label": format!("n{n}"), "phase": "Count"})));
    lines.extend(
        (0..done).map(|n| json!({"type": "result", "agentId": format!("a{n}"), "result": "1"})),
    );
    let text: Vec<String> = lines.iter().map(Value::to_string).collect();
    std::fs::write(dir.join("journal.jsonl"), text.join("\n") + "\n").unwrap();
    dir
}

#[tokio::test]
async fn a_workflow_runs_as_a_background_subagent_with_its_progress() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let out = updates(&t.inbound(&workflow_call("toolu_w")).await);
    let spawned = of_kind(&out, "subagent_spawned");
    assert_eq!(spawned.len(), 1, "{out:?}");
    assert_eq!(spawned[0]["subagentSessionId"], "acp-1/toolu_w");
    assert_eq!(spawned[0]["_meta"]["claude"]["subagentType"], "workflow");

    // The launch result returns at once; the workflow keeps running.
    let dir = journal(3, 1);
    let out = updates(&t.inbound(&launched("toolu_w", dir.to_str().unwrap())).await);
    assert!(of_kind(&out, "subagent_state_update").is_empty(), "{out:?}");
    let named = of_kind(&out, "subagent_progress");
    assert_eq!(named.len(), 1, "{out:?}");
    assert_eq!(named[0]["name"], "probe");
    assert_eq!(named[0]["task"], "Two tiny agents");

    let started = json!({"type": "system", "subtype": "task_started", "task_id": "wx2", "tool_use_id": "toolu_w",
        "description": "Two tiny agents", "task_type": "local_workflow"});
    t.inbound(&started).await;
    let progress = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2", "tool_use_id": "toolu_w",
        "description": "Count: n2", "usage": {"total_tokens": 19738, "tool_uses": 4, "duration_ms": 3212},
        "last_tool_name": "n2", "summary": "Two tiny agents"});
    let out = updates(&t.inbound(&progress).await);
    let progress = of_kind(&out, "subagent_progress");
    assert_eq!(progress.len(), 1, "{out:?}");
    assert_eq!(
        *progress[0],
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "acp-1/toolu_w",
            "tokens": 19738, "toolUses": 4, "elapsedMs": 3212, "action": "Count: n2",
            "agents": {"done": 1, "started": 3}})
    );

    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "wx2", "tool_use_id": "toolu_w",
        "status": "completed", "output_file": "", "summary": "Dynamic workflow \"Two tiny agents\" completed",
        "usage": {"total_tokens": 19738, "tool_uses": 4, "duration_ms": 3196}});
    let out = updates(&t.inbound(&done).await);
    let ended = of_kind(&out, "subagent_state_update");
    assert_eq!(ended.len(), 1, "{out:?}");
    assert_eq!(ended[0]["state"], "completed");
    let _ = std::fs::remove_dir_all(dir);
}

/// A `task_progress` line whose snapshot (`workflow_progress`) holds `items`,
/// trimmed from a Claude Code 2.1.309 run.
fn snapshot(items: Value) -> Value {
    json!({"type": "system", "subtype": "task_progress", "task_id": "wx2", "tool_use_id": "toolu_w",
        "description": "Review: review:#1", "usage": {"total_tokens": 4000, "tool_uses": 3, "duration_ms": 5000},
        "last_tool_name": "review:#1", "summary": "Review two PRs", "workflow_progress": items})
}

fn phase(index: u64, title: &str) -> Value {
    json!({"type": "workflow_phase", "index": index, "title": title})
}

/// Each snapshot repeats the whole run; the update sends the phases once and
/// then, of each agent, only what changed, with the counts the snapshot gives.
#[tokio::test]
async fn a_workflow_sends_its_phases_and_agents_then_only_what_changed() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    // A journal that disagrees: once a snapshot came, its counts are the run's.
    let dir = journal(9, 9);
    t.inbound(&launched("toolu_w", dir.to_str().unwrap())).await;
    let running = json!({"type": "workflow_agent", "index": 1, "label": "review:#1", "state": "progress",
        "phaseIndex": 1, "phaseTitle": "Review", "agentId": "a01", "agentType": "workflow-subagent",
        "model": "claude-opus-5-5", "tokens": 1200, "toolCalls": 2, "durationMs": 4000.4,
        "queuedAt": 1000, "startedAt": 1100, "lastProgressAt": 5000, "attempt": 1,
        "lastToolName": "Bash", "lastToolSummary": "gh pr view 1",
        "promptPreview": "You are an independent   reviewer\nfor PR #1"});
    let queued = json!({"type": "workflow_agent", "index": 2, "label": "review:#2", "state": "start",
        "phaseIndex": 1, "phaseTitle": "Review", "queuedAt": 1000});
    let out = updates(
        &t.inbound(&snapshot(json!([phase(1, "Review"), phase(2, "Land"), running, queued]))).await,
    );
    let first = of_kind(&out, "subagent_progress");
    assert_eq!(first.len(), 1, "{out:?}");
    assert_eq!(
        first[0]["phases"],
        json!([{"index": 1, "title": "Review"}, {"index": 2, "title": "Land"}])
    );
    assert_eq!(first[0]["agents"], json!({"done": 0, "started": 1, "queued": 1}));
    assert_eq!(
        first[0]["workflowAgents"],
        json!([
            {"index": 1, "label": "review:#1", "state": "running", "phase": "Review", "phaseIndex": 1,
             "agentId": "a01", "kind": "workflow-subagent", "model": "claude-opus-5-5", "tokens": 1200,
             "toolUses": 2, "elapsedMs": 4000, "queuedAt": 1000, "startedAt": 1100, "lastProgressAt": 5000,
             "attempt": 1, "action": "gh pr view 1", "prompt": "You are an independent reviewer for PR #1"},
            {"index": 2, "label": "review:#2", "state": "queued", "phase": "Review", "phaseIndex": 1,
             "queuedAt": 1000},
        ])
    );

    // The first agent returns and the second starts: only those fields go out.
    let returned = json!({"type": "workflow_agent", "index": 1, "label": "review:#1", "state": "done",
        "phaseIndex": 1, "phaseTitle": "Review", "agentId": "a01", "agentType": "workflow-subagent",
        "model": "claude-opus-5-5", "tokens": 1500, "toolCalls": 2, "durationMs": 4000.4,
        "queuedAt": 1000, "startedAt": 1100, "lastProgressAt": 5000, "attempt": 1,
        "lastToolName": "Bash", "lastToolSummary": "gh pr view 1",
        "promptPreview": "You are an independent   reviewer\nfor PR #1", "resultPreview": "Verdict: SHIP"});
    let started = json!({"type": "workflow_agent", "index": 2, "label": "review:#2", "state": "progress",
        "phaseIndex": 1, "phaseTitle": "Review", "queuedAt": 1000, "startedAt": 5100});
    let items = json!([phase(1, "Review"), phase(2, "Land"), returned, started]);
    let out = updates(&t.inbound(&snapshot(items.clone())).await);
    let second = of_kind(&out, "subagent_progress");
    assert!(second[0].get("phases").is_none(), "unchanged phases went out again: {out:?}");
    assert_eq!(second[0]["agents"], json!({"done": 1, "started": 2}));
    assert_eq!(
        second[0]["workflowAgents"],
        json!([
            {"index": 1, "state": "completed", "tokens": 1500, "result": "Verdict: SHIP"},
            {"index": 2, "state": "running", "startedAt": 5100},
        ])
    );

    // The same run again changes nothing.
    let out = updates(&t.inbound(&snapshot(items)).await);
    let third = of_kind(&out, "subagent_progress");
    assert!(third[0].get("workflowAgents").is_none(), "{out:?}");
    assert_eq!(third[0]["agents"], json!({"done": 1, "started": 2}));
    let _ = std::fs::remove_dir_all(dir);
}

/// An agent that failed, one the person skipped and one served from a resumed
/// run's journal each say so.
#[tokio::test]
async fn a_workflow_agent_says_how_it_ended() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    let agent = |index: u64, extra: Value| {
        let mut item = json!({"type": "workflow_agent", "index": index, "label": format!("fix:{index}"),
            "startedAt": 10});
        for (key, value) in extra.as_object().unwrap() {
            item[key] = value.clone();
        }
        item
    };
    let items = json!([
        agent(1, json!({"state": "error", "error": "503 no non-exhausted claude accounts"})),
        agent(2, json!({"state": "error", "skipped": true})),
        agent(3, json!({"state": "done", "cached": true})),
        agent(4, json!({"state": "progress", "attempt": 2, "lastAttemptReason": "stalled"})),
    ]);
    let out = updates(&t.inbound(&snapshot(items)).await);
    let update = of_kind(&out, "subagent_progress");
    let rows = update[0]["workflowAgents"].as_array().unwrap();
    let field = |i: usize, key: &str| rows[i][key].clone();
    assert_eq!(field(0, "state"), "failed");
    assert_eq!(field(0, "error"), "503 no non-exhausted claude accounts");
    assert_eq!(field(1, "state"), "skipped");
    assert_eq!((field(2, "state"), field(2, "cached")), (json!("completed"), json!(true)));
    assert_eq!((field(3, "attempt"), field(3, "retryReason")), (json!(2), json!("stalled")));
    assert_eq!(update[0]["agents"], json!({"done": 1, "started": 4, "failed": 2}));
}

/// Claude sends a workflow's usage every 16 ms while its agents stream: a line
/// with no snapshot sends nothing within a second of the last update, and one
/// with a snapshot always sends.
#[tokio::test]
async fn a_workflow_sends_usage_alone_at_most_once_a_second() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    let usage = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2", "tool_use_id": "toolu_w",
        "description": "Review: review:#1", "usage": {"total_tokens": 4100, "tool_uses": 3, "duration_ms": 5016}});
    assert_eq!(of_kind(&updates(&t.inbound(&usage).await), "subagent_progress").len(), 1);
    assert!(of_kind(&updates(&t.inbound(&usage).await), "subagent_progress").is_empty());
    let items = json!([phase(1, "Review")]);
    assert_eq!(of_kind(&updates(&t.inbound(&snapshot(items)).await), "subagent_progress").len(), 1);
}

/// The hub's subagent model carries the run's id, phases and agent changes.
#[test]
fn workflow_agents_reach_clients_in_the_subagent_model() {
    let mut tree = SubagentTree::default();
    let mut spawn = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "acp-1/toolu_w", "name": "Workflow", "task": "Workflow"}});
    tree.annotate(&mut spawn);
    let mut progress = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_progress",
        "subagentSessionId": "acp-1/toolu_w", "runId": "wf_4fe", "phases": [{"index": 1, "title": "Review"}],
        "workflowAgents": [{"index": 1, "state": "running", "label": "review:#1"}]}});
    tree.annotate(&mut progress);
    assert_eq!(
        progress["_meta"]["acpmux"]["subagents"],
        json!([{"id": "acp-1/toolu_w", "parent": null, "state": "running", "runId": "wf_4fe",
            "phases": [{"index": 1, "title": "Review"}],
            "workflowAgents": [{"index": 1, "state": "running", "label": "review:#1"}]}])
    );
}

#[tokio::test]
async fn a_workflow_whose_script_fails_its_check_ends_failed() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    let rejected = json!({"type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_w", "content": "SyntaxError"}]},
        "tool_use_result": {"status": "async_launched", "taskId": "wx3", "error": "SyntaxError: Unexpected token"}});
    let out = updates(&t.inbound(&rejected).await);
    let ended = of_kind(&out, "subagent_state_update");
    assert_eq!(ended.len(), 1, "{out:?}");
    assert_eq!(ended[0]["state"], "failed");
}

#[tokio::test]
async fn a_background_agent_reports_its_progress() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let call = json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_a", "name": "Agent",
        "input": {"description": "Watch the build", "prompt": "Watch it", "run_in_background": true}}]}});
    t.inbound(&call).await;
    let progress = json!({"type": "system", "subtype": "task_progress", "task_id": "a1", "tool_use_id": "toolu_a",
        "description": "Watch the build", "subagent_type": "general-purpose",
        "usage": {"total_tokens": 5100, "tool_uses": 2, "duration_ms": 61000}, "last_tool_name": "Bash"});
    let out = updates(&t.inbound(&progress).await);
    let progress = of_kind(&out, "subagent_progress");
    assert_eq!(
        progress.first().map(|v| (*v).clone()),
        Some(json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "acp-1/toolu_a",
            "tokens": 5100, "toolUses": 2, "elapsedMs": 61000, "action": "Bash"})),
        "{out:?}"
    );
    // A progress summary (agentProgressSummaries) is the better action.
    let summarized = json!({"type": "system", "subtype": "task_progress", "task_id": "a1", "tool_use_id": "toolu_a",
        "description": "Watch the build", "usage": {"total_tokens": 6000, "tool_uses": 3, "duration_ms": 90000},
        "last_tool_name": "Bash", "summary": "Waiting on the macOS job"});
    let out = updates(&t.inbound(&summarized).await);
    assert_eq!(of_kind(&out, "subagent_progress")[0]["action"], "Waiting on the macOS job");
}

#[test]
fn progress_reaches_clients_in_the_subagent_model() {
    let mut tree = SubagentTree::default();
    let mut spawn = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "acp-1/toolu_w", "name": "Workflow", "task": "Workflow",
        "_meta": {"claude": {"subagentType": "workflow", "toolUseId": "toolu_w"}}}});
    tree.annotate(&mut spawn);
    let mut progress = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_progress",
        "subagentSessionId": "acp-1/toolu_w", "name": "probe", "tokens": 19738, "toolUses": 4, "elapsedMs": 3212,
        "action": "Count: n2", "agents": {"done": 1, "started": 3}}});
    tree.annotate(&mut progress);
    assert_eq!(
        progress["_meta"]["acpmux"]["subagents"],
        json!([{"id": "acp-1/toolu_w", "parent": null, "state": "running", "name": "probe", "tokens": 19738,
            "toolUses": 4, "elapsedMs": 3212, "action": "Count: n2", "agents": {"done": 1, "started": 3}}])
    );
}

#[test]
fn a_background_subagent_reaches_clients_marked_background() {
    let mut tree = SubagentTree::default();
    let mut spawn = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "acp-1/toolu_b", "name": "Watch", "task": "Watch", "background": true}});
    tree.annotate(&mut spawn);
    assert_eq!(
        spawn["_meta"]["acpmux"]["subagents"],
        json!([{"id": "acp-1/toolu_b", "parent": null, "name": "Watch", "task": "Watch", "state": "running", "background": true}])
    );
    let mut moved = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_progress",
        "subagentSessionId": "acp-1/toolu_f", "background": true}});
    tree.annotate(&mut moved);
    assert_eq!(
        moved["_meta"]["acpmux"]["subagents"],
        json!([{"id": "acp-1/toolu_f", "parent": null, "state": "running", "background": true}])
    );
}

/// The app's stop on a background agent or workflow row: `_acpmux/subagent_stop`
/// becomes Claude's `stop_task` control request for the subagent's task, and
/// Claude's answer answers the request.
#[tokio::test]
async fn stopping_a_background_subagent_stops_its_claude_task() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    t.inbound(&json!({"type": "system", "subtype": "task_started", "task_id": "wx2", "tool_use_id": "toolu_w",
        "description": "Two tiny agents", "task_type": "local_workflow"}))
        .await;
    let stop = |id: i64, child: &str| {
        Message::request(
            id,
            "_acpmux/subagent_stop",
            json!({"sessionId": "acp-1", "subagentSessionId": child}),
        )
    };
    let Outbound::Lines(lines) = t.outbound(&stop(7, "acp-1/toolu_w")).await else {
        panic!("stop answered at once instead of asking Claude")
    };
    assert_eq!(
        lines,
        vec![json!({"type": "control_request", "request_id": "stop-7",
            "request": {"subtype": "stop_task", "task_id": "wx2"}})]
    );
    let ack = json!({"type": "control_response",
        "response": {"subtype": "success", "request_id": "stop-7", "response": {}}});
    let replies: Vec<_> = t
        .inbound(&ack)
        .await
        .into_iter()
        .filter_map(|m| match m {
            Message::Response { id, error, .. } => Some((id, error)),
            _ => None,
        })
        .collect();
    assert_eq!(replies, vec![(json!(7), None)]);

    // Claude's refusal is the request's error.
    t.outbound(&stop(9, "acp-1/toolu_w")).await;
    let refused = json!({"type": "control_response",
        "response": {"subtype": "error", "request_id": "stop-9", "error": "task already finished"}});
    let errors: Vec<_> = t
        .inbound(&refused)
        .await
        .into_iter()
        .filter_map(|m| match m {
            Message::Response { id, error: Some(e), .. } => Some((id, e.message)),
            _ => None,
        })
        .collect();
    assert_eq!(errors, vec![(json!(9), "task already finished".to_owned())]);

    // A subagent this chat does not have is an error, not a stray stop.
    let Outbound::Reply(Message::Response { error: Some(_), .. }) =
        t.outbound(&stop(8, "acp-1/toolu_gone")).await
    else {
        panic!("stopping an unknown subagent did not fail")
    };
}
