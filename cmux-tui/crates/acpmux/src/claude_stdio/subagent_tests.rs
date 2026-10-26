//! Claude's Agent (Task) tool becomes a native ACP subagent session: a
//! `subagent_spawned` update, the child's own lines under its session id,
//! and a `subagent_state_update` when the tool returns.

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

fn spawn_line(id: &str, parent: Option<&str>) -> Value {
    json!({
        "type": "assistant",
        "parent_tool_use_id": parent,
        "message": {"content": [{"type": "tool_use", "id": id, "name": "Agent", "input": {
            "description": "Branch A", "prompt": "Look at the tests", "subagent_type": "Explore"
        }}]}
    })
}

#[tokio::test]
async fn an_agent_tool_call_spawns_a_subagent_session() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let out = updates(&t.inbound(&spawn_line("toolu_1", None)).await);
    assert_eq!(out.len(), 2, "{out:?}");
    assert_eq!(out[1].1["sessionUpdate"], "tool_call");
    assert_eq!(out[0].0, "acp-1");
    assert_eq!(
        out[0].1,
        json!({
            "sessionUpdate": "subagent_spawned",
            "subagentSessionId": "acp-1/toolu_1",
            "name": "Branch A",
            "task": "Branch A",
            "prompt": "Look at the tests",
            "capabilities": {},
            "_meta": {"claude": {"subagentType": "Explore", "toolUseId": "toolu_1"}}
        })
    );
}

#[tokio::test]
async fn a_subagents_lines_stream_under_its_own_session() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let text = json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "reading"}}});
    let read = json!({"type": "assistant", "parent_tool_use_id": "toolu_1", "message": {"content": [{"type": "tool_use", "id": "toolu_2", "name": "Read", "input": {"file_path": "/a/b.rs"}}]}});
    let result = json!({"type": "user", "parent_tool_use_id": "toolu_1", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_2", "content": "fn main() {}"}]}});
    for line in [text, read, result] {
        let out = updates(&t.inbound(&line).await);
        assert_eq!(out.len(), 1, "{out:?}");
        assert_eq!(out[0].0, "acp-1/toolu_1");
    }
}

#[tokio::test]
async fn a_nested_agent_call_spawns_under_its_parent_subagent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let out = updates(&t.inbound(&spawn_line("toolu_9", Some("toolu_1"))).await);
    assert_eq!(out[0].0, "acp-1/toolu_1");
    assert_eq!(out[0].1["subagentSessionId"], "acp-1/toolu_9");
}

#[tokio::test]
async fn the_agent_tools_result_ends_the_subagent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    t.inbound(&spawn_line("toolu_3", None)).await;
    let done = |id: &str, is_error: bool| json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "report", "is_error": is_error}]}});
    let out = updates(&t.inbound(&done("toolu_1", false)).await);
    assert_eq!(out[0].1["sessionUpdate"], "tool_call_update");
    assert_eq!(
        out[1],
        (
            "acp-1".to_owned(),
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "acp-1/toolu_1", "state": "completed"})
        )
    );
    let out = updates(&t.inbound(&done("toolu_3", true)).await);
    assert_eq!(out[1].1["state"], "failed");
}

#[tokio::test]
async fn a_cancelled_turn_cancels_its_running_subagents() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "go"}]}),
    ))
    .await;
    t.inbound(&spawn_line("toolu_1", None)).await;
    t.outbound(&Message::notification(method::SESSION_CANCEL, json!({}))).await;
    let msgs = t.inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null})).await;
    let out = updates(&msgs);
    assert_eq!(
        out,
        [(
            "acp-1".to_owned(),
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "acp-1/toolu_1", "state": "cancelled"})
        )]
    );
}

fn background_spawn_line(id: &str) -> Value {
    json!({
        "type": "assistant",
        "message": {"content": [{"type": "tool_use", "id": id, "name": "Agent", "input": {
            "description": "Branch A", "prompt": "Watch the build", "run_in_background": true
        }}]}
    })
}

fn tool_result(id: &str) -> Value {
    json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "Async agent launched"}]}})
}

fn ended(out: &[(String, Value)]) -> Vec<(String, String)> {
    out.iter()
        .filter(|(_, u)| u["sessionUpdate"] == "subagent_state_update")
        .map(|(_, u)| {
            (
                u["subagentSessionId"].as_str().unwrap_or("").to_owned(),
                u["state"].as_str().unwrap_or("").to_owned(),
            )
        })
        .collect()
}

#[tokio::test]
async fn a_background_subagent_outlives_its_launch_result() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let out = updates(&t.inbound(&background_spawn_line("toolu_1")).await);
    // Its spawn says it runs in the background, so a client keeps it running
    // past a stopped turn.
    assert_eq!(out[0].1["sessionUpdate"], "subagent_spawned");
    assert_eq!(out[0].1["background"], true, "{out:?}");
    // The launch result returns at once; the subagent keeps running.
    assert_eq!(ended(&updates(&t.inbound(&tool_result("toolu_1")).await)), vec![]);
    let text = json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "still going"}}});
    let out = updates(&t.inbound(&text).await);
    assert_eq!(out[0].0, "acp-1/toolu_1");
    // Its task notification ends it.
    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "t1", "tool_use_id": "toolu_1", "status": "completed", "output_file": "", "summary": "done"});
    let out = updates(&t.inbound(&done).await);
    assert_eq!(ended(&out), vec![("acp-1/toolu_1".to_owned(), "completed".to_owned())]);
    assert_eq!(out[0].0, "acp-1");
}

#[tokio::test]
async fn a_subagent_moved_to_the_background_ends_by_its_task() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let started = json!({"type": "system", "subtype": "task_started", "task_id": "t1", "tool_use_id": "toolu_1", "description": "Branch A", "is_backgrounded": false});
    t.inbound(&started).await;
    let moved = json!({"type": "system", "subtype": "task_updated", "task_id": "t1", "patch": {"is_backgrounded": true}});
    // Moved to the background, it says so.
    let out = updates(&t.inbound(&moved).await);
    assert_eq!(
        out.iter().map(|(_, u)| u.clone()).collect::<Vec<_>>(),
        vec![
            json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "acp-1/toolu_1", "background": true})
        ]
    );
    assert_eq!(ended(&updates(&t.inbound(&tool_result("toolu_1")).await)), vec![]);
    // A stopped task (by task id alone) is a cancelled subagent.
    let stopped = json!({"type": "system", "subtype": "task_notification", "task_id": "t1", "status": "stopped", "output_file": "", "summary": ""});
    let out = updates(&t.inbound(&stopped).await);
    assert_eq!(ended(&out), vec![("acp-1/toolu_1".to_owned(), "cancelled".to_owned())]);
}

/// A subagent's text and tool call, as Claude writes them under its Agent call's id.
fn late_lines(parent: &str) -> [Value; 2] {
    [
        json!({"type": "stream_event", "parent_tool_use_id": parent, "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "one more thing"}}}),
        json!({"type": "assistant", "parent_tool_use_id": parent, "message": {"content": [{"type": "tool_use", "id": "toolu_late", "name": "Read", "input": {"file_path": "/a/b.rs"}}]}}),
    ]
}

#[tokio::test]
async fn a_background_subagents_late_line_stays_its_own() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&background_spawn_line("toolu_1")).await;
    t.inbound(&tool_result("toolu_1")).await;
    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "t1", "tool_use_id": "toolu_1", "status": "completed", "output_file": "", "summary": "done"});
    t.inbound(&done).await;
    // A line it writes after its task notification is still its own, never the main agent's.
    for line in late_lines("toolu_1") {
        let out = updates(&t.inbound(&line).await);
        assert_eq!(out.len(), 1, "{out:?}");
        assert_eq!(out[0].0, "acp-1/toolu_1", "{out:?}");
    }
}

#[tokio::test]
async fn a_cancelled_subagents_late_line_stays_its_own() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "go"}]}),
    ))
    .await;
    t.inbound(&spawn_line("toolu_1", None)).await;
    t.outbound(&Message::notification(method::SESSION_CANCEL, json!({}))).await;
    t.inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null})).await;
    // A line it writes after the stopped turn ended it is still its own.
    for line in late_lines("toolu_1") {
        let out = updates(&t.inbound(&line).await);
        assert_eq!(out.len(), 1, "{out:?}");
        assert_eq!(out[0].0, "acp-1/toolu_1", "{out:?}");
    }
}

/// Claude Code sends a subagent's model output as whole `assistant` lines, with
/// no stream events (Leo: "why subagents have so little talking?"): its text
/// and thinking go to its own session as message and thought chunks, before
/// the tool calls the same line makes. A subagent that does stream its text
/// is not sent it twice, and the chat's own lines stay streamed only.
#[tokio::test]
async fn a_subagents_whole_assistant_lines_carry_its_text_and_thinking() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let line = json!({"type": "assistant", "parent_tool_use_id": "toolu_1", "message": {"id": "msg_1", "content": [
        {"type": "thinking", "thinking": "Which hook?"},
        {"type": "text", "text": "Checking the merge hook."},
        {"type": "tool_use", "id": "toolu_2", "name": "Read", "input": {"file_path": "/a/b.rs"}}
    ]}});
    let out = updates(&t.inbound(&line).await);
    let kinds: Vec<_> = out
        .iter()
        .map(|(sid, u)| (sid.as_str(), u["sessionUpdate"].as_str().unwrap_or("")))
        .collect();
    assert_eq!(
        kinds,
        [
            ("acp-1/toolu_1", "agent_thought_chunk"),
            ("acp-1/toolu_1", "agent_message_chunk"),
            ("acp-1/toolu_1", "tool_call")
        ],
        "{out:?}"
    );
    assert_eq!(out[1].1["content"]["text"], "Checking the merge hook.");
    assert_eq!(out[1].1["messageId"], "msg_1");

    // A subagent whose text streams: its whole line adds no second copy.
    t.inbound(&spawn_line("toolu_3", None)).await;
    let delta = json!({"type": "stream_event", "parent_tool_use_id": "toolu_3", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Reading"}}});
    t.inbound(&delta).await;
    let whole = json!({"type": "assistant", "parent_tool_use_id": "toolu_3", "message": {"content": [{"type": "text", "text": "Reading"}]}});
    assert!(updates(&t.inbound(&whole).await).is_empty());

    // The chat's own whole lines: its text came as stream events.
    let own = json!({"type": "assistant", "parent_tool_use_id": null, "message": {"content": [{"type": "text", "text": "Done."}]}});
    assert!(updates(&t.inbound(&own).await).is_empty());
}

/// Claude Code's end of a background agent the SR2 gateway refused (hb-acpmux's own chat,
/// 2026-10-26): `task_id` is the agent id SendMessage resumes it by.
fn failed_503(task: &str, tool: &str) -> Value {
    json!({"type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tool, "status": "failed",
           "output_file": "", "summary": "Agent terminated early due to an API error: API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary. (error type server_error, HTTP 503, model sent to the API: claude-opus-5-5)"})
}

/// Leo, 2026-10-26: "this needs to retry :(". A failed subagent's end says why and names the
/// agent to resume, and SendMessage's resume makes that same subagent run again.
#[tokio::test]
async fn a_failed_agent_says_why_and_its_resume_runs_it_again() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&background_spawn_line("toolu_1")).await;
    t.inbound(&tool_result("toolu_1")).await;
    let started = json!({"type": "system", "subtype": "task_started", "task_id": "a8e1b68b93aac9d16", "tool_use_id": "toolu_1", "is_backgrounded": true});
    t.inbound(&started).await;
    let out = updates(&t.inbound(&failed_503("a8e1b68b93aac9d16", "toolu_1")).await);
    let end = &out.iter().find(|(_, u)| u["sessionUpdate"] == "subagent_state_update").unwrap().1;
    assert_eq!(end["state"], "failed");
    assert_eq!(end["agentId"], "a8e1b68b93aac9d16");
    assert!(end["error"].as_str().unwrap().contains("503 no non-exhausted"), "{end}");
    // SendMessage resumes it: its task starts again under the SendMessage call.
    let resumed = json!({"type": "system", "subtype": "task_started", "task_id": "a8e1b68b93aac9d16", "tool_use_id": "toolu_send", "is_backgrounded": true});
    let out = updates(&t.inbound(&resumed).await);
    assert_eq!(
        out.iter().map(|(_, u)| u.clone()).collect::<Vec<_>>(),
        vec![
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "acp-1/toolu_1", "state": "running", "agentId": "a8e1b68b93aac9d16"})
        ]
    );
    // Its lines still stream under its own session, and its next end, by the SendMessage
    // call's id, ends that subagent.
    let lines = late_lines("toolu_1");
    assert_eq!(updates(&t.inbound(&lines[0]).await)[0].0, "acp-1/toolu_1");
    let done = json!({"type": "system", "subtype": "task_notification", "task_id": "a8e1b68b93aac9d16", "tool_use_id": "toolu_send", "status": "completed", "output_file": "", "summary": "done"});
    let out = updates(&t.inbound(&done).await);
    assert_eq!(ended(&out), vec![("acp-1/toolu_1".to_owned(), "completed".to_owned())]);
    // A completed end names no agent to resume.
    assert!(out.iter().all(|(_, u)| u.get("agentId").is_none()), "{out:?}");
}

/// A foreground agent whose call fails says why too, and names the agent its task named.
#[tokio::test]
async fn a_failed_foreground_agent_says_why() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let started = json!({"type": "system", "subtype": "task_started", "task_id": "a1", "tool_use_id": "toolu_1", "is_backgrounded": false});
    t.inbound(&started).await;
    let failed = json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_1", "is_error": true,
                        "content": "Agent terminated early due to an API error: API Error: 529 overloaded_error"}]}});
    let out = updates(&t.inbound(&failed).await);
    assert_eq!(out[1].1["state"], "failed");
    assert_eq!(out[1].1["agentId"], "a1");
    assert!(out[1].1["error"].as_str().unwrap().contains("529"), "{out:?}");
}

/// Past `MAX_FAILED_AGENTS` failures the oldest is forgotten, never the newer ones: a resume of
/// a newer one still says it runs again, and one forgotten still streams as its own.
#[tokio::test]
async fn failed_agents_past_the_limit_forget_only_the_oldest() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    for n in 0..=MAX_FAILED_AGENTS {
        let (tool, task) = (format!("toolu_{n}"), format!("a{n}"));
        t.inbound(&background_spawn_line(&tool)).await;
        t.inbound(&failed_503(&task, &tool)).await;
    }
    let resume = |task: &str| json!({"type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": "toolu_send", "is_backgrounded": true});
    assert!(updates(&t.inbound(&resume("a0")).await).is_empty(), "the oldest is forgotten");
    let out = updates(&t.inbound(&resume("a1")).await);
    assert_eq!(out[0].1["state"], "running", "{out:?}");
    assert_eq!(out[0].1["subagentSessionId"], "acp-1/toolu_1");
    let lines = late_lines("toolu_0");
    assert_eq!(updates(&t.inbound(&lines[0]).await)[0].0, "acp-1/toolu_0");
}
