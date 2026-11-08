//! A workflow agent's background shell lists under that agent (cmux#36269: Session Info and
//! Background tasks nest a workflow agent's commands under its row). Claude Code's task_started
//! for such a shell says only `owned_by_subagent: true`, with no `parent_task_id` (a plain
//! subagent's names its task) and no `parent_tool_use_id` (Claude Code 2.1.312, seen in a real
//! run's log). The agent is the one whose transcript in the run's dir (`agent-<id>.jsonl`) has
//! the Bash call, so the shell's update goes to the workflow's session with `workflowAgentId`.

use super::*;

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

fn shells(out: &[(String, Value)]) -> Vec<(String, Value)> {
    out.iter().filter(|(_, u)| u["sessionUpdate"] == "background_task_update").cloned().collect()
}

/// A run's transcript dir with one transcript per agent, each holding its tool calls' ids.
fn run_dir(name: &str, agents: &[(&str, &[&str])]) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-wf-shell-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("journal.jsonl"), "{\"type\":\"launched\"}\n").unwrap();
    for (agent, calls) in agents {
        write_calls(&dir, agent, calls);
    }
    dir
}

/// An agent's transcript as Claude Code writes it: one compact JSON line per message.
fn write_calls(dir: &std::path::Path, agent: &str, calls: &[&str]) {
    let lines: Vec<String> = calls
        .iter()
        .map(|id| {
            json!({"type": "assistant", "agentId": agent, "isSidechain": true, "message": {"content": [
                {"type": "tool_use", "id": id, "name": "Bash", "input": {"command": "cargo test"}}]}})
            .to_string()
        })
        .collect();
    std::fs::write(dir.join(format!("agent-{agent}.jsonl")), lines.join("\n") + "\n").unwrap();
    std::fs::write(dir.join(format!("agent-{agent}.meta.json")), "{}").unwrap();
}

async fn workflow(t: &Translator, dir: &std::path::Path) {
    t.inbound(&json!({"type": "assistant", "message": {"content": [{"type": "tool_use",
        "id": "toolu_wf", "name": "Workflow", "input": {"scriptPath": "/tmp/wf.js"}}]}}))
        .await;
    t.inbound(&json!({"type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_wf", "content": "launched"}]},
        "tool_use_result": {"status": "async_launched", "taskId": "wx2", "taskType": "local_workflow",
            "runId": "wf_4fe", "transcriptDir": dir.to_str().unwrap()}}))
        .await;
}

/// A workflow agent's background shell starting, as Claude Code 2.1.312 sends it.
fn agent_shell(tool: &str) -> Value {
    json!({"type": "system", "subtype": "task_started", "task_id": "b1", "tool_use_id": tool,
        "description": "Run the tests", "task_type": "local_bash", "is_backgrounded": true,
        "owned_by_subagent": true, "run_id": "0mw3-1", "session_id": "s1"})
}

#[tokio::test]
async fn a_workflow_agents_shell_goes_to_its_workflow_naming_its_agent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let dir = run_dir("named", &[("a437d46d", &["toolu_other"]), ("a5e1bb51", &["toolu_sh"])]);
    workflow(&t, &dir).await;
    let out = shells(&updates(&t.inbound(&agent_shell("toolu_sh")).await));
    assert_eq!(out.len(), 1, "{out:?}");
    let (sid, update) = &out[0];
    assert_eq!(sid, "acp-1/toolu_wf", "the workflow's session: the hub lists it as its subagent's");
    assert_eq!(update["state"], "running");
    assert_eq!(update["workflowAgentId"], "a5e1bb51");
    // Its end names them too.
    let end = json!({"type": "system", "subtype": "task_notification", "task_id": "b1",
        "tool_use_id": "toolu_sh", "status": "completed", "summary": "done"});
    let out = shells(&updates(&t.inbound(&end).await));
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].0, "acp-1/toolu_wf");
    assert_eq!(out[0].1["state"], "completed");
    assert_eq!(out[0].1["workflowAgentId"], "a5e1bb51");
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn a_shell_whose_call_is_not_written_yet_is_named_on_the_runs_next_snapshot() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let dir = run_dir("late", &[("a437d46d", &["toolu_other"])]);
    workflow(&t, &dir).await;
    // The agent's transcript does not hold the call yet: the only running workflow's shell.
    let out = shells(&updates(&t.inbound(&agent_shell("toolu_sh")).await));
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].0, "acp-1/toolu_wf");
    assert!(out[0].1.get("workflowAgentId").is_none(), "{out:?}");
    // A usage-only progress line reads no transcript.
    write_calls(&dir, "a5e1bb51", &["toolu_sh"]);
    let usage = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2",
        "tool_use_id": "toolu_wf", "usage": {"total_tokens": 10}});
    assert!(shells(&updates(&t.inbound(&usage).await)).is_empty());
    // The run's snapshot: the shell goes out again naming its agent, once.
    let snapshot = json!({"type": "system", "subtype": "task_progress", "task_id": "wx2",
        "tool_use_id": "toolu_wf", "workflow_progress": [], "usage": {"total_tokens": 11}});
    let out = shells(&updates(&t.inbound(&snapshot).await));
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].0, "acp-1/toolu_wf");
    assert_eq!(out[0].1["state"], "running");
    assert_eq!(out[0].1["workflowAgentId"], "a5e1bb51");
    assert!(shells(&updates(&t.inbound(&snapshot).await)).is_empty(), "named once");
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn a_plain_subagents_shell_and_the_chats_own_are_not_looked_up() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let dir = run_dir("plain", &[("a5e1bb51", &["toolu_sub", "toolu_own"])]);
    workflow(&t, &dir).await;
    // A plain subagent's shell names its agent's task: it stays where its line put it.
    let mut sub = agent_shell("toolu_sub");
    sub["parent_task_id"] = json!("a8cb9dc7");
    let out = shells(&updates(&t.inbound(&sub).await));
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].0, "acp-1");
    assert!(out[0].1.get("workflowAgentId").is_none(), "{out:?}");
    // The chat's own shell is not a subagent's.
    let mut own = agent_shell("toolu_own");
    own["task_id"] = json!("b2");
    own.as_object_mut().unwrap().remove("owned_by_subagent");
    let out = shells(&updates(&t.inbound(&own).await));
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0].0, "acp-1");
    assert!(out[0].1.get("workflowAgentId").is_none(), "{out:?}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn an_agents_call_is_found_only_as_a_call_id() {
    let dir = run_dir("ids", &[("a1", &["toolu_x"])]);
    // A result naming the call (`tool_use_id`) is not the agent's own call.
    std::fs::write(
        dir.join("agent-a2.jsonl"),
        json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_y"}]}})
            .to_string(),
    )
    .unwrap();
    assert_eq!(background_shells::agent_of_call(&dir, "toolu_x").as_deref(), Some("a1"));
    assert_eq!(background_shells::agent_of_call(&dir, "toolu_y"), None);
    assert_eq!(background_shells::agent_of_call(&dir.join("missing"), "toolu_x"), None);
    let _ = std::fs::remove_dir_all(dir);
}
