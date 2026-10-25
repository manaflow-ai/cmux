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
        "input": {"scriptPath": "/tmp/wf.js", "args": {"pr": 24789}}}]}})
}

fn launched(id: &str, transcript_dir: &str) -> Value {
    json!({"type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "Workflow launched in background. Task ID: wx2"}]},
        "tool_use_result": {"status": "async_launched", "taskId": "wx2", "taskType": "local_workflow",
            "workflowName": "probe", "runId": "wf_4fe", "summary": "Two tiny agents", "transcriptDir": transcript_dir,
            "scriptPath": "/home/me/.claude/projects/-w/s1/workflows/scripts/probe-wf_4fe.js"}})
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
    // What a resume names again: the script path Claude Code returned; the args go only as a digest.
    assert_eq!(named[0]["runId"], "wf_4fe");
    assert_eq!(
        named[0]["scriptPath"],
        "/home/me/.claude/projects/-w/s1/workflows/scripts/probe-wf_4fe.js"
    );
    assert_eq!(named[0]["argsDigest"], digest_of(&json!({"pr": 24789})).await);
    assert!(named[0].get("args").is_none(), "args never go out");

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

/// An agent that failed before it started did not start, as the journal
/// counts it; a state this acpmux does not know goes out as Claude names it.
#[tokio::test]
async fn a_workflow_counts_only_agents_that_started() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    let items = json!([
        {"type": "workflow_agent", "index": 1, "label": "fix:1", "state": "error", "blocked": true, "queuedAt": 5},
        {"type": "workflow_agent", "index": 2, "label": "fix:2", "state": "cancelled", "startedAt": 9},
    ]);
    let out = updates(&t.inbound(&snapshot(items)).await);
    let update = of_kind(&out, "subagent_progress");
    assert_eq!(update[0]["agents"], json!({"done": 0, "started": 1, "failed": 1}));
    let rows = update[0]["workflowAgents"].as_array().unwrap();
    assert_eq!(
        (rows[0]["state"].clone(), rows[1]["state"].clone()),
        (json!("blocked"), json!("cancelled"))
    );
}

/// A workflow's end sends its final usage and every agent whole before the
/// end itself, so a reader of recent history alone still has each agent.
#[tokio::test]
async fn a_workflow_ends_with_its_final_usage_and_every_agent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    t.inbound(&launched("toolu_w", "/nonexistent")).await;
    let agent = json!({"type": "workflow_agent", "index": 1, "label": "review:#1", "state": "done",
        "phaseTitle": "Review", "startedAt": 10, "resultPreview": "SHIP"});
    t.inbound(&snapshot(json!([phase(1, "Review"), agent]))).await;
    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "wx2", "tool_use_id": "toolu_w",
        "status": "completed", "usage": {"total_tokens": 52000, "tool_uses": 9, "duration_ms": 61000}});
    let out = updates(&t.inbound(&done).await);
    let kinds: Vec<&str> = out.iter().filter_map(|(_, u)| u["sessionUpdate"].as_str()).collect();
    assert_eq!(kinds, vec!["subagent_progress", "subagent_state_update"], "{out:?}");
    let last = &out[0].1;
    assert_eq!((last["tokens"].clone(), last["toolUses"].clone()), (json!(52000), json!(9)));
    assert_eq!(last["workflowAgentsFull"], json!(true));
    // What a resume names comes again with the end, for a reader of recent history alone.
    assert_eq!(last["runId"], "wf_4fe");
    assert_eq!(
        last["scriptPath"],
        "/home/me/.claude/projects/-w/s1/workflows/scripts/probe-wf_4fe.js"
    );
    assert_eq!(last["argsDigest"], digest_of(&json!({"pr": 24789})).await);
    assert!(last.get("args").is_none(), "args never go out");
    assert_eq!(last["phases"], json!([{"index": 1, "title": "Review"}]));
    assert_eq!(
        last["workflowAgents"],
        json!([{"index": 1, "label": "review:#1", "state": "completed", "phase": "Review",
            "startedAt": 10, "result": "SHIP"}])
    );
}

/// Claude Code sends no notification after it pauses a workflow (its agents
/// stop; a resume is a new task with the same run id): the pause ends the
/// subagent, saying so, and nothing of the run is kept.
#[tokio::test]
async fn a_paused_workflow_ends_as_paused() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    t.inbound(&launched("toolu_w", "/nonexistent")).await;
    let paused = json!({"type": "system", "subtype": "task_updated", "task_id": "wx2",
        "patch": {"status": "paused"}});
    let out = updates(&t.inbound(&paused).await);
    let ended = of_kind(&out, "subagent_state_update");
    assert_eq!(ended.len(), 1, "{out:?}");
    assert_eq!(
        (ended[0]["state"].clone(), ended[0]["reason"].clone()),
        (json!("cancelled"), json!("paused"))
    );
    // The run is gone: a late progress line and a late notification send nothing.
    assert!(updates(&t.inbound(&snapshot(json!([phase(1, "Review")]))).await).is_empty());
    let late = json!({"type": "system", "subtype": "task_notification", "task_id": "wx2", "status": "stopped"});
    assert!(updates(&t.inbound(&late).await).is_empty());

    // A notification that names no status still ends its task, as completed.
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    let bare = json!({"type": "system", "subtype": "task_notification", "tool_use_id": "toolu_w"});
    let out = updates(&t.inbound(&bare).await);
    assert_eq!(of_kind(&out, "subagent_state_update")[0]["state"], "completed", "{out:?}");

    let mut tree = SubagentTree::default();
    let mut spawn = json!({"sessionId": "acp-1", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "acp-1/toolu_w", "name": "Workflow"}});
    tree.annotate(&mut spawn);
    let mut end = json!({"sessionId": "acp-1", "update": ended[0].clone()});
    tree.annotate(&mut end);
    assert_eq!(end["_meta"]["acpmux"]["subagents"][0]["reason"], json!("paused"));
}

/// A plain background agent ends only with its notification, which carries its result: a
/// task_updated saying it completed does not end it first.
#[tokio::test]
async fn a_plain_background_agent_ends_only_with_its_notification() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let call = json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_a", "name": "Agent",
        "input": {"description": "Watch the build", "prompt": "Watch it", "run_in_background": true}}]}});
    t.inbound(&call).await;
    t.inbound(&json!({"type": "system", "subtype": "task_started", "task_id": "a1", "tool_use_id": "toolu_a",
        "is_backgrounded": true}))
        .await;
    for status in ["completed", "failed", "killed", "paused"] {
        let updated = json!({"type": "system", "subtype": "task_updated", "task_id": "a1", "patch": {"status": status}});
        let out = updates(&t.inbound(&updated).await);
        assert!(of_kind(&out, "subagent_state_update").is_empty(), "{status}: {out:?}");
    }
    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "a1", "status": "completed"});
    let out = updates(&t.inbound(&done).await);
    assert_eq!(of_kind(&out, "subagent_state_update")[0]["state"], "completed", "{out:?}");
}

/// A secret behind a long blank run is masked whole: the preview folds the blanks before it cuts
/// and masks, so no part of the token reaches the preview.
#[tokio::test]
async fn a_preview_never_shows_part_of_a_secret() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&workflow_call("toolu_w")).await;
    // Built here, not written out, so the repository holds no token-shaped string.
    let token = format!("gh{}_{}", "p", "Q7ZJ4XK2MD5P3WRT8N6C1VBH9YLFGSA0TEUI");
    let prompt = format!("{}{token} and more", " ".repeat(5000));
    let items = json!([{"type": "workflow_agent", "index": 1, "label": "a", "state": "progress",
        "startedAt": 1, "promptPreview": prompt}]);
    let out = updates(&t.inbound(&snapshot(items)).await);
    let shown = of_kind(&out, "subagent_progress")[0]["workflowAgents"][0]["prompt"].clone();
    let shown = shown.as_str().unwrap();
    assert!(!shown.contains("Q7ZJ4XK2"), "{shown}");
    assert!(shown.starts_with("[GitHub Personal Access Token]"), "{shown}");

    // Past what a preview reads, a word is left out whole, never shown in part.
    let flood = format!("{}{token}", " ".repeat(1_000_000));
    let items = json!([{"type": "workflow_agent", "index": 2, "label": "b", "state": "progress",
        "startedAt": 1, "promptPreview": flood}]);
    let out = updates(&t.inbound(&snapshot(items)).await);
    let agent = &of_kind(&out, "subagent_progress")[0]["workflowAgents"][0];
    assert!(agent.get("prompt").is_none_or(|p| !p.to_string().contains("Q7ZJ")), "{agent}");
}

/// The digest a launch sends for `args`, read from a launch of a Workflow call with them.
async fn digest_of(args: &Value) -> Value {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(
        &json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_d",
        "name": "Workflow", "input": {"scriptPath": "/tmp/wf.js", "args": args}}]}}),
    )
    .await;
    let out = updates(&t.inbound(&launched("toolu_d", "/nonexistent")).await);
    of_kind(&out, "subagent_progress")[0]["argsDigest"].clone()
}

/// A workflow's args never go to a pane, whatever they hold (an env map, a base64 blob, a key named
/// like a credential or not): only a digest, which says whether two runs had the same args.
#[tokio::test]
async fn a_workflows_args_go_out_only_as_a_digest() {
    let launch = |args: Value| async move {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        t.inbound(&json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_w",
            "name": "Workflow", "input": {"scriptPath": "/tmp/wf.js", "args": args}}]}}))
            .await;
        let out = updates(&t.inbound(&launched("toolu_w", "/nonexistent")).await);
        of_kind(&out, "subagent_progress")[0].clone()
    };
    for args in [json!({"pr": 7}), json!({"env": {"FOO": "s3cr3t"}}), json!({"blob": "c2VjcmV0"})] {
        let update = launch(args.clone()).await;
        assert!(update.get("args").is_none(), "{update}");
        assert_eq!(update["argsDigest"], digest_of(&args).await);
        assert_eq!(update["argsDigest"].as_str().map(str::len), Some(32));
        assert!(!update.to_string().contains("s3cr3t") && !update.to_string().contains("c2VjcmV0"));
    }
    assert_ne!(digest_of(&json!({"pr": 7})).await, digest_of(&json!({"pr": 8})).await);
    // Keyed by this daemon: not the plain SHA-256 a guess could be tested against.
    let plain: String = crate::sha256::sha256_hex(json!({"pr": 7}).to_string().as_bytes())
        .chars()
        .take(32)
        .collect();
    assert_ne!(digest_of(&json!({"pr": 7})).await, json!(plain));
    // No args, no digest.
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(
        &json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_w",
        "name": "Workflow", "input": {"scriptPath": "/tmp/wf.js"}}]}}),
    )
    .await;
    let out = updates(&t.inbound(&launched("toolu_w", "/nonexistent")).await);
    assert!(of_kind(&out, "subagent_progress")[0].get("argsDigest").is_none());
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

/// The event log keeps how many items a big workflow snapshot held, not the
/// items: each repeats every agent so far (`logged_line`). A small one, and
/// any other line, is kept whole.
#[test]
fn the_log_keeps_a_big_workflow_snapshot_size_not_its_agents() {
    let agents: Vec<Value> = (0..17)
        .map(|n| json!({"type": "workflow_agent", "index": n, "label": format!("review:#{n}")}))
        .collect();
    let snapshot = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2",
        "usage": {"total_tokens": 19738}, "workflow_progress": agents});
    let Message::Notification { method, params: Some(kept) } = logged_line(&snapshot) else {
        panic!("not a notification")
    };
    assert_eq!(method, "claude.system.task_progress");
    assert_eq!(
        kept,
        json!({"type": "system", "subtype": "task_progress", "task_id": "wx2",
            "usage": {"total_tokens": 19738}, "_acpmux": {"workflowProgressItems": 17}})
    );
    let small = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2",
        "workflow_progress": [{"type": "workflow_phase", "index": 1, "title": "Review"}]});
    let Message::Notification { params: Some(kept), .. } = logged_line(&small) else {
        panic!("not a notification")
    };
    assert_eq!(kept, small);
    let line =
        json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}});
    let Message::Notification { method, params: Some(kept) } = logged_line(&line) else {
        panic!("not a notification")
    };
    assert_eq!((method.as_str(), kept), ("claude.assistant", line));
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
