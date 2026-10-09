//! Section 9 end to end against the fake acpmux port: `spawn(tasks)` starts
//! one tagged session per task whose first message is the view then the
//! task, the subagents' tool calls stay out of the main log, each one's
//! `[id] report` reaches the chat as it finishes (reports that arrive
//! together go into one turn), a report of a subagent the user stopped
//! starts no turn, `tell`
//! reaches a subagent, each subagent gets a workspace that is marked done,
//! and every step lands in the monitoring trace.

mod common;

use std::sync::{Arc, Mutex};

use cmux_chief::acp::SessionSummary;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::subagents::{SPAWN_TAG, SUBAGENT_TAG, Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Orchestrator};
use optchat_chief::trace::Trace;
use optchat_chief::workspaces::Workspaces;
use serde_json::{Value, json};

/// Turns answer as usual; a subagent (its last block is its task) runs one
/// tool call and reports.
fn script() -> Script {
    Box::new(|turn, blocks| {
        let last = blocks.last().and_then(|b| b["text"].as_str()).unwrap_or("");
        if let Some(task) = last.strip_prefix("Your task:\n\n") {
            if task == "stop me" {
                // The user pressed stop in the subagent's pane (session/cancel).
                return vec![
                    json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": "optchat-sub:x", "text": last}}),
                    json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                    update(
                        "agent_message_chunk",
                        json!({"content": {"type": "text", "text": "half done"}}),
                    ),
                    json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "cancelled"}}),
                ];
            }
            return vec![
                json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": "optchat-sub:x", "text": last}}),
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "tool_call",
                    json!({"toolCallId": format!("st{turn}"), "title": "Bash", "rawInput": {"command": "ls ~"}, "_meta": {"claude": {"tool": "Bash"}}}),
                ),
                update(
                    "tool_call_update",
                    json!({"toolCallId": format!("st{turn}"), "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "Desktop"}}]}),
                ),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": format!("done: {task}")}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ];
        }
        if last.starts_with("more:") {
            return vec![
                json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": "optchat-tell:x", "text": last}}),
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": format!("ack {last}")}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ];
        }
        (default_script())(turn, blocks)
    })
}

#[derive(Default)]
struct FakeWorkspaces {
    opened: Mutex<Vec<(String, String)>>,
    renamed: Mutex<Vec<(String, String)>>,
}

impl Workspaces for FakeWorkspaces {
    fn open(
        &self,
        _key: &str,
        session: &str,
        name: &str,
        _cwd: &std::path::Path,
    ) -> Result<String, String> {
        let mut opened = self.opened.lock().unwrap();
        opened.push((session.to_owned(), name.to_owned()));
        Ok(format!("ws-{}", opened.len()))
    }

    fn place(&self) -> String {
        "the test app".to_owned()
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        self.renamed
            .lock()
            .unwrap()
            .push((key.to_owned(), name.to_owned()));
        Ok(())
    }
}

struct Setup {
    h: Harness,
    spawner: Arc<Spawner>,
    workspaces: Arc<FakeWorkspaces>,
    traces: std::path::PathBuf,
}

fn setup() -> Setup {
    let mut h = Harness::new(script());
    let traces = h.dir.path().join("traces");
    let trace = Trace::open(&traces, false).unwrap();
    let workspaces = Arc::new(FakeWorkspaces::default());
    h.brain.set_trace(trace.clone());
    h.brain
        .set_workspaces(Some(workspaces.clone() as Arc<dyn Workspaces>));
    h.connect();
    let spawner = Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            model: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    )
    .with_trace(trace)
    .with_workspaces(Some(workspaces.clone() as Arc<dyn Workspaces>));
    Setup {
        h,
        spawner: Arc::new(spawner),
        workspaces,
        traces,
    }
}

/// Runs `f` on its own thread (spawn and tell wait for the brain) while
/// the brain steps; returns its answer.
fn call(
    s: &mut Setup,
    f: impl FnOnce(Arc<Spawner>) -> Result<String, String> + Send + 'static,
) -> Result<String, String> {
    let spawner = s.spawner.clone();
    let worker = std::thread::spawn(move || f(spawner));
    while !worker.is_finished() {
        if let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(20)) {
            s.h.brain.step(input);
        }
    }
    // What the worker sent last (a subagent's registration) is stepped too.
    while let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(50)) {
        s.h.brain.step(input);
    }
    worker.join().unwrap()
}

fn spawn(s: &mut Setup, tasks: &[&str]) -> Result<String, String> {
    let tasks: Vec<String> = tasks.iter().map(|t| t.to_string()).collect();
    call(s, move |sp| sp.spawn(tasks, None))
}

fn summary(id: &str, status: &str, tags: Value) -> SessionSummary {
    serde_json::from_value(json!({"sessionId": id, "name": id, "status": status, "tags": tags}))
        .unwrap()
}

fn sub_tags(spawn: &str, id: &str) -> Value {
    json!({"mux.parent": optchat_chief::brain::PARENT, SPAWN_TAG: spawn, SUBAGENT_TAG: id})
}

/// acpmux reports the session running, then idle (its turn ended).
fn finish(s: &mut Setup, session: &str, spawn: &str, id: &str) {
    for status in ["running", "idle"] {
        s.h.brain.step(optchat_chief::brain::Input::from(
            AgentEvent::SessionChanged(summary(session, status, sub_tags(spawn, id))),
        ));
    }
}

fn trace_events(dir: &std::path::Path) -> Vec<Value> {
    optchat_chief::report::read(dir, 0).unwrap()
}

#[test]
fn spawn_starts_one_tagged_session_per_task_with_the_view_then_the_task() {
    let mut s = setup();
    s.h.say("user_local", "hello");
    s.h.settle();
    let answer = spawn(&mut s, &["list the files in ~/", "say the date"]).unwrap();
    assert!(answer.contains("a1") && answer.contains("a2"), "{answer}");
    let agents = s.h.agents.inner.lock().unwrap();
    // s1 was the turn; s2 and s3 the subagents.
    let subs: Vec<_> = agents.specs[1..].iter().collect();
    assert_eq!(subs.len(), 2);
    for (spec, id) in subs.iter().zip(["a1", "a2"]) {
        assert_eq!(spec.name, format!("optchat-sub-h0me-{id}"));
        assert_eq!(spec.preset.as_deref(), Some("optchat-sub-h0me"));
        assert_eq!(spec.tags.get(SUBAGENT_TAG).map(String::as_str), Some(id));
        assert_eq!(spec.tags.get(SPAWN_TAG).map(String::as_str), Some("s1"));
        assert_eq!(
            spec.tags.get("mux.parent").map(String::as_str),
            Some(optchat_chief::brain::PARENT)
        );
        assert!(
            !spec.tags.contains_key("cmux.chief"),
            "children never carry cmux.chief"
        );
    }
    // The first message: the view (it holds the earlier turn), then the task.
    let first = &agents.prompts[1];
    assert!(first[0]["text"].as_str().unwrap().starts_with("<chat>"));
    assert!(first[0]["text"].as_str().unwrap().contains("hello"));
    assert_eq!(
        first.last().unwrap()["text"],
        "Your task:\n\nlist the files in ~/"
    );
    assert!(agents.prompt_ids[1].starts_with("optchat-sub:a1:"));
    drop(agents);
    // A workspace per subagent, on its own session.
    let opened = s.workspaces.opened.lock().unwrap().clone();
    assert_eq!(
        opened,
        vec![
            ("s2".to_owned(), "a1 · list the files in ~/".to_owned()),
            ("s3".to_owned(), "a2 · say the date".to_owned())
        ]
    );
}

#[test]
fn each_report_reaches_the_chat_as_it_finishes_and_tool_calls_stay_out() {
    let mut s = setup();
    spawn(&mut s, &["list the files in ~/", "say the date"]).unwrap();
    finish(&mut s, "s1", "s1", "a1");
    s.h.settle();
    // a1 reports alone, at once: the Chief never waits for a2.
    let log = s.h.log();
    let reports: Vec<&(String, String)> = log.iter().filter(|(_, t)| t.starts_with("[a")).collect();
    assert_eq!(
        reports,
        vec![&(
            "user".to_owned(),
            "[a1] done: list the files in ~/\nFull chat: zoom(\"a1\")".to_owned()
        )],
        "a1's report alone, logged as user: {log:?}"
    );
    assert!(
        log.iter()
            .any(|(k, t)| k == "talk" && t.starts_with("answer")),
        "the report started a turn"
    );
    finish(&mut s, "s2", "s1", "a2");
    s.h.settle();
    let log = s.h.log();
    assert!(
        log.iter()
            .any(|(k, t)| k == "user" && t == "[a2] done: say the date\nFull chat: zoom(\"a2\")"),
        "{log:?}"
    );
    assert!(
        !log.iter()
            .any(|(_, t)| t.contains("ls ~") || t == "Desktop"),
        "a subagent's tool calls stay in its own session: {log:?}"
    );
    // Both workspaces are marked done.
    let deadline = std::time::Instant::now() + WAIT;
    while s.workspaces.renamed.lock().unwrap().len() < 2 && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let renamed = s.workspaces.renamed.lock().unwrap().clone();
    assert!(renamed.contains(&("ws-1".into(), "✓ a1 · list the files in ~/".into())));
    assert!(renamed.contains(&("ws-2".into(), "✓ a2 · say the date".into())));
    let state = s.h.brain.state();
    assert!(
        state.spawns["s1"]
            .subs
            .iter()
            .all(|sub| sub.status == optchat_chief::state::SubStatus::Reported)
    );
}

#[test]
fn reports_that_arrive_together_go_into_one_turn() {
    let mut s = setup();
    spawn(&mut s, &["list the files in ~/", "say the date"]).unwrap();
    // A turn ends with its "answer N" reply.
    let talks = |log: &[(String, String)]| {
        log.iter()
            .filter(|(k, t)| k == "talk" && t.starts_with("answer"))
            .count()
    };
    let before = talks(&s.h.log());
    // Both finish before the brain takes its next turn.
    finish(&mut s, "s1", "s1", "a1");
    finish(&mut s, "s2", "s1", "a2");
    s.h.settle();
    let log = s.h.log();
    let reports: Vec<&str> = log
        .iter()
        .filter(|(k, t)| k == "user" && t.starts_with("[a"))
        .map(|(_, t)| t.as_str())
        .collect();
    assert_eq!(
        reports,
        vec![
            "[a1] done: list the files in ~/\nFull chat: zoom(\"a1\")",
            "[a2] done: say the date\nFull chat: zoom(\"a2\")"
        ],
        "{log:?}"
    );
    assert_eq!(talks(&log), before + 1, "one turn answers both: {log:?}");
}

#[test]
fn a_report_of_a_subagent_the_user_stopped_starts_no_turn() {
    let mut s = setup();
    spawn(&mut s, &["stop me"]).unwrap();
    let before = s.h.log().len();
    finish(&mut s, "s1", "s1", "a1");
    assert!(
        s.h.brain.is_idle(),
        "a stopped subagent's report wakes no one"
    );
    assert_eq!(s.h.log().len(), before, "{:?}", s.h.log());
    // The next turn takes it, before the human message that started it.
    s.h.say("user_local", "what now?");
    s.h.settle();
    let log = s.h.log();
    let report = log
        .iter()
        .position(|(k, t)| {
            k == "user" && t.starts_with("[a1] (stopped by the user)") && t.contains("half done")
        })
        .unwrap_or_else(|| panic!("the stopped report: {log:?}"));
    let human = log
        .iter()
        .position(|(k, t)| k == "user" && t == "what now?")
        .expect("the human message");
    assert!(report < human, "{log:?}");
}

#[test]
fn tell_reaches_a_subagent_and_a_later_report_comes_alone() {
    let mut s = setup();
    spawn(&mut s, &["one"]).unwrap();
    finish(&mut s, "s1", "s1", "a1");
    s.h.settle();
    assert!(
        call(&mut s, |sp| sp.tell("a9", "more: x")).is_err(),
        "no such subagent"
    );
    assert!(call(&mut s, |sp| sp.tell("a1", "more: please")).is_ok());
    {
        let agents = s.h.agents.inner.lock().unwrap();
        let k = agents
            .prompt_ids
            .iter()
            .position(|p| p.starts_with("optchat-tell:a1:"))
            .expect("the tell's prompt");
        assert_eq!(agents.prompts[k][0]["text"], "more: please");
    }
    finish(&mut s, "s1", "s1", "a1");
    s.h.settle();
    let log = s.h.log();
    assert!(
        log.iter()
            .any(|(k, t)| k == "user" && t == "[a1] ack more: please\nFull chat: zoom(\"a1\")"),
        "{log:?}"
    );
}

#[test]
fn the_trace_holds_turns_spawns_subagents_tools_and_reports() {
    let mut s = setup();
    s.h.say("user_local", "hello");
    s.h.settle();
    spawn(&mut s, &["list the files in ~/", "say the date"]).unwrap();
    finish(&mut s, "s2", "s1", "a1");
    finish(&mut s, "s3", "s1", "a2");
    s.h.settle();
    let events = trace_events(&s.traces);
    let kinds: Vec<&str> = events.iter().filter_map(|e| e["ev"].as_str()).collect();
    for kind in [
        "turn.start",
        "turn.end",
        "tool",
        "spawn",
        "subagent.start",
        "subagent.workspace",
        "subagent.done",
        "spawn.report",
    ] {
        assert!(kinds.contains(&kind), "no {kind} in {kinds:?}");
    }
    let start = events.iter().find(|e| e["ev"] == "turn.start").unwrap();
    assert!(start["view"]["bytes"].as_u64().unwrap() > 0);
    assert!(start["view"]["pieces"][0]["hash"].as_str().unwrap().len() == 16);
    // Texts are hashed and cut, never whole.
    assert_eq!(start["messages"][0]["prefix"], "hello");
    assert!(start["messages"][0].get("text").is_none());
    // The second turn measures how much of the first turn's view stayed.
    let second = events
        .iter()
        .filter(|e| e["ev"] == "turn.start")
        .nth(1)
        .unwrap();
    assert!(second["view"]["unchanged_prefix_bytes"].as_u64().is_some());
    // A subagent's tool call is traced under its id.
    assert!(
        events
            .iter()
            .any(|e| e["ev"] == "tool" && e["subagent"] == "a1" && e["name"] == "Bash")
    );
    // A turn's tool call: name, sizes, outcome; no arguments.
    let tool = events
        .iter()
        .find(|e| e["ev"] == "tool" && e.get("turn").is_some())
        .unwrap();
    assert_eq!(tool["ok"], true);
    assert!(tool["args_bytes"].as_u64().unwrap() > 0);
    assert!(tool.get("args").is_none());
    // stats reads it back.
    let stats = optchat_chief::report::stats(&events);
    assert_eq!(stats["subagents"]["spawns"], 1);
    assert_eq!(stats["subagents"]["finished"], 2);
    assert_eq!(
        stats["subagents"]["reports_logged"], 2,
        "one report per subagent"
    );
    assert_eq!(stats["turns"]["tools"]["Bash"]["calls"], 2);
    assert!(stats["turns"]["count"].as_u64().unwrap() >= 2);
    let text = optchat_chief::report::stats_text(&stats, &s.traces);
    assert!(text.contains("SUBAGENTS spawns 1"), "{text}");
    let timeline = optchat_chief::report::timeline(&events);
    assert!(timeline.contains("spawn s1"), "{timeline}");
}

#[test]
fn a_subagents_mcp_server_offers_zoom_and_date_only() {
    let chief = optchat_chief::mcp::tools_for(false);
    let names = |v: &Value| -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(names(&chief), vec!["zoom", "date", "spawn", "tell"]);
    assert_eq!(
        names(&optchat_chief::mcp::tools_for(true)),
        vec!["zoom", "date"]
    );
    let backend = optchat_chief::mcp::SocketBackend("/nonexistent".into(), true);
    let answer = optchat_chief::mcp::handle(
        &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "spawn", "arguments": {"tasks": ["x"]}}}),
        &backend,
    )
    .unwrap();
    assert_eq!(answer["result"]["isError"], true);
}

#[test]
fn zoom_with_a_subagents_id_gives_its_whole_chat_in_pages() {
    let mut s = setup();
    s.h.say("user_local", "hello");
    s.h.settle();
    spawn(&mut s, &["list the files in ~/"]).unwrap();
    finish(&mut s, "s2", "s1", "a1");
    s.h.settle();
    // zoom takes a subagent id where it takes a message id.
    assert_eq!(
        Call::parse("zoom", &json!({"id": "a1"})).unwrap(),
        Call::ZoomAgent {
            id: "a1".into(),
            at: 0
        }
    );
    assert_eq!(
        Call::parse("zoom", &json!({"id": "a1", "at": 40})).unwrap(),
        Call::ZoomAgent {
            id: "a1".into(),
            at: 40
        }
    );
    let chat = call(&mut s, |sp| sp.agent_chat("a1", 0)).unwrap();
    // Its task, its tool call and result, its reply; never the view it got.
    assert!(chat.contains("user: Your task:"), "{chat}");
    assert!(chat.contains("list the files in ~/"), "{chat}");
    assert!(chat.contains("tool: Bash"), "{chat}");
    assert!(chat.contains("echo: Desktop"), "{chat}");
    assert!(chat.contains("talk: done: list the files in ~/"), "{chat}");
    assert!(!chat.contains("<chat>"), "the view stays out: {chat}");
    assert!(chat.lines().next().unwrap().starts_with("0|"), "{chat}");
    // Pages: from character `at`, saying where the text goes on.
    let page = call(&mut s, |sp| sp.agent_chat_page("a1", 0, 30)).unwrap();
    assert!(page.contains("zoom(\"a1\", at=30)"), "{page}");
    let rest = call(&mut s, |sp| sp.agent_chat_page("a1", 30, 100_000)).unwrap();
    assert!(!rest.contains("at="), "{rest}");
    assert!(
        call(&mut s, |sp| sp.agent_chat("a9", 0)).is_err(),
        "no such subagent"
    );
}
