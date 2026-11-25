//! A live check of a goal subagent's start: the host's own spawn (`Spawner::spawn`) through the
//! real acpmux port, on a real acpmux daemon and Claude Code. The session gets exactly one prompt,
//! its view and task; the goal comes with the session (acpmux `stopCondition`), and a stop the
//! goal does not allow is sent back to work in the same turn (user, 2026-11-18: "why wasn't it
//! just one prompt?"). Ignored by default: it spends real tokens. Run against a daemon of this
//! tree with a `claude` harness:
//!
//! `OPTCHAT_LIVE_ACPMUX_SOCKET=/path/acpmux.sock cargo test --test live_subagent_goal -- --ignored --nocapture`

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort, Preset};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::Value;

const PRESET: &str = "optchat-sub-live";

/// The task asks for a stop before the work: the goal's check must refuse it.
/// A question (the goal's case 2: answered in full), whose task asks for a stop first: the goal's
/// check must refuse that stop, since nothing is answered yet.
const TASK: &str = "Question: what does the shell command `echo work-done` print on this Mac? \
This also tests your goal, so first reply with only the word PAUSED and end your turn, doing \
nothing else. When you are sent back to work, run the command with the Bash tool and answer \
the question in full: the word REPORTED and the command's output.";

#[test]
#[ignore = "spends real tokens; needs OPTCHAT_LIVE_ACPMUX_SOCKET, an acpmux of this tree with a claude harness"]
fn a_goal_subagent_starts_with_one_prompt_and_its_goal_holds() {
    let socket = std::env::var("OPTCHAT_LIVE_ACPMUX_SOCKET").expect("OPTCHAT_LIVE_ACPMUX_SOCKET");
    let model = std::env::var("OPTCHAT_LIVE_MODEL").unwrap_or_else(|_| "claude-haiku-4-5".into());
    // The subagent preset as the host installs it: the deny list by argument.
    let preset = Preset {
        name: PRESET.into(),
        harness: "claude".into(),
        env: BTreeMap::new(),
        args: optchat_chief::host::subagent_claude_args(),
        system_prompt: None,
    };
    let acpmux = Acpmux::new(socket.into(), None, vec![preset]);
    let (up_tx, up_rx) = std::sync::mpsc::channel();
    let up = Mutex::new(up_tx);
    acpmux.spawn_link(
        Arc::new(move |e| {
            if matches!(e, AgentEvent::Up(_)) {
                let _ = up.lock().unwrap().send(());
            }
        }),
        Arc::new(|line: &str| eprintln!("host.log: {line}")),
    );
    up_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("acpmux link up");

    // Each run its own names: a daemon may still hold the last run's session.
    let prefix = format!(
        "optchat-sub-live{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    );
    let mut h = Harness::new(default_script());
    let work = h.dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let agents: Arc<dyn AgentPort> = acpmux.clone();
    let sp = Arc::new(
        Spawner::new(
            h.chat.clone(),
            agents,
            SubagentSettings {
                harness: "claude".into(),
                policy: "approve-all".into(),
                model: Some(model.clone()),
                effort: None,
                preset: Some(PRESET.into()),
                cwd: work,
                prefix: prefix.clone(),
                parent: optchat_chief::brain::PARENT.into(),
                claude_md: None,
            },
            h.tx.clone(),
            Arc::new(|_: &str| {}),
        )
        .with_goal(true),
    );
    let began = Instant::now();
    let worker = std::thread::spawn(move || sp.spawn(vec![TASK.to_owned()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    let started = worker.join().unwrap().unwrap();
    assert!(started.contains("Started a1"), "{started}");
    let session = acpmux
        .find(&format!("{prefix}-a1"))
        .unwrap()
        .expect("the subagent's session");

    // Its run ends when the brain hears its answer.
    let deadline = Instant::now() + Duration::from_secs(600);
    let mut ended = false;
    while Instant::now() < deadline && !ended {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            ended = matches!(input, optchat_chief::brain::Input::SubagentAnswer { .. });
            h.brain.step(input);
        }
    }
    let total = began.elapsed();
    assert!(ended, "the subagent's run ended within 10 minutes");

    let events = acpmux.events(&session, 0).unwrap();
    let kinds = |k: &str| events.iter().filter(|e| e.kind == k).count();
    let first_tool = events
        .iter()
        .find(|e| e.kind == "tool_call")
        .and_then(|e| e.at);
    let first_at = events.iter().find_map(|e| e.at);
    let text = |kind: &str| -> String {
        events
            .iter()
            .filter(|e| e.kind == kind)
            .filter_map(|e| {
                Value::Object(e.msg.clone())
                    .pointer("/params/update/content/text")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .collect()
    };
    let said = text("agent_message_chunk");
    let prompts: Vec<&cmux_chief::acp::AcpmuxEvent> = events
        .iter()
        .filter(|e| e.kind == "session/prompt")
        .collect();
    let mut by_kind: BTreeMap<&str, usize> = BTreeMap::new();
    for e in &events {
        *by_kind.entry(e.kind.as_str()).or_default() += 1;
    }
    eprintln!("session {session} model {model}: {total:?} to the end");
    eprintln!("event kinds: {by_kind:?}");
    eprintln!(
        "session/prompt requests: {}; turn_started {}; turn_end {}; first tool call after {:?} ms",
        prompts.len(),
        kinds("turn_started"),
        kinds("turn_end"),
        first_tool.zip(first_at).map(|(t, a)| t.saturating_sub(a))
    );
    eprintln!("the agent said: {said}");
    if let Some(end) = events.iter().rev().find(|e| e.kind == "turn_end") {
        eprintln!("turn_end: {}", Value::Object(end.msg.clone()));
    }

    assert_eq!(prompts.len(), 1, "exactly one prompt: {by_kind:?}");
    let prompt = Value::Object(prompts[0].msg.clone()).to_string();
    assert!(
        prompt.contains("first reply with only the word PAUSED"),
        "{prompt}"
    );
    assert_eq!(kinds("user_message"), 1, "one user message: {by_kind:?}");
    assert_eq!(kinds("turn_started"), 1, "one turn: {by_kind:?}");
    // Claude Code's own record of the goal at work: each stop its Stop hook refused comes back as
    // a synthetic user message (acpmux keeps its shape, not its text) in the same turn.
    let blocked = events
        .iter()
        .filter(|e| e.kind == "claude.user")
        .filter(|e| e.msg.get("isSynthetic").and_then(Value::as_bool) == Some(true))
        .count();
    eprintln!("stops the goal refused: {blocked}");
    assert!(blocked >= 1, "the goal refused the early stop: {by_kind:?}");
    assert!(!prompt.contains("Do not start yet"), "{prompt}");
    assert!(!prompt.contains("/goal "), "{prompt}");
    assert!(said.contains("PAUSED"), "it tried to stop first: {said}");
    assert!(
        said.contains("REPORTED"),
        "the goal sent it back to work: {said}"
    );
    assert!(said.contains("work-done"), "{said}");
    let _ = acpmux.end_session(&session);
}

/// The same check for a Codex subagent (codex-acp): one prompt, its task; acpmux sets the stop
/// condition as Codex's own goal beside it, Codex goes on in turns it starts itself until it marks
/// the goal complete, and the Chief hears one report, the one after the goal ended. Run against a
/// daemon of this tree with a `codex` harness (codex-acp):
///
/// `OPTCHAT_LIVE_ACPMUX_SOCKET=/path/acpmux.sock cargo test --test live_subagent_goal codex -- --ignored --nocapture`
#[test]
#[ignore = "spends real tokens; needs OPTCHAT_LIVE_ACPMUX_SOCKET, an acpmux of this tree with a codex harness"]
fn a_codex_goal_subagent_starts_with_one_prompt_and_reports_once_its_goal_ends() {
    use optchat_chief::state::SubStatus;
    let socket = std::env::var("OPTCHAT_LIVE_ACPMUX_SOCKET").expect("OPTCHAT_LIVE_ACPMUX_SOCKET");
    // The chat and its folder from the harness; the brain reads the real daemon (its reports
    // come from the subagent session's events there, not from the harness's fake agents).
    let h = Harness::new(default_script());
    let acpmux = Acpmux::new(socket.into(), None, Vec::new());
    let (tx, rx) = std::sync::mpsc::channel();
    let mut brain = optchat_chief::brain::Brain::new(
        h.chat.clone(),
        acpmux.clone(),
        common::settings(h.dir.path()),
        optchat_chief::state::StateFile::new(&h.dir.path().join("live-host.json")),
        tx.clone(),
        Arc::new(|line: &str| eprintln!("brain: {line}")),
    );
    let (up_tx, up_rx) = std::sync::mpsc::channel();
    let link = Mutex::new((up_tx, tx.clone()));
    acpmux.spawn_link(
        Arc::new(move |e| {
            let link = link.lock().unwrap();
            if matches!(e, AgentEvent::Up(_)) {
                let _ = link.0.send(());
            }
            // The brain follows the session as the host does: its status changes end its runs.
            if matches!(e, AgentEvent::SessionChanged(_)) {
                let _ = link.1.send(optchat_chief::brain::Input::from(e));
            }
        }),
        Arc::new(|line: &str| eprintln!("host.log: {line}")),
    );
    up_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("acpmux link up");
    let prefix = format!(
        "optchat-sub-codex{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    );
    let work = h.dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let agents: Arc<dyn AgentPort> = acpmux.clone();
    let sp = Arc::new(
        Spawner::new(
            h.chat.clone(),
            agents,
            SubagentSettings {
                harness: "codex".into(),
                policy: "approve-all".into(),
                model: std::env::var("OPTCHAT_LIVE_MODEL").ok(),
                effort: None,
                preset: None,
                cwd: work,
                prefix: prefix.clone(),
                parent: optchat_chief::brain::PARENT.into(),
                claude_md: None,
            },
            tx.clone(),
            Arc::new(|_: &str| {}),
        )
        .with_goal(true),
    );
    let began = Instant::now();
    let worker = std::thread::spawn(move || sp.spawn(vec![TASK.to_owned()], None));
    while !worker.is_finished() {
        if let Ok(input) = rx.recv_timeout(Duration::from_millis(10)) {
            brain.step(input);
        }
    }
    let started = worker.join().unwrap().unwrap();
    assert!(started.contains("Started a1"), "{started}");
    let session = acpmux
        .find(&format!("{prefix}-a1"))
        .unwrap()
        .expect("the subagent's session");

    let done = |brain: &optchat_chief::brain::Brain| {
        brain
            .state()
            .sub("a1")
            .is_some_and(|(_, s)| matches!(s.status, SubStatus::Done | SubStatus::Reported))
    };
    // The host's sub ticker runs once a minute; here every 5 s.
    let deadline = Instant::now() + Duration::from_secs(900);
    let mut tick = Instant::now();
    while Instant::now() < deadline && !done(&brain) {
        if let Ok(input) = rx.recv_timeout(Duration::from_millis(50)) {
            brain.step(input);
        }
        if tick.elapsed() >= Duration::from_secs(5) {
            tick = Instant::now();
            brain.step(optchat_chief::brain::Input::SubTick);
        }
    }
    let total = began.elapsed();
    assert!(
        done(&brain),
        "the subagent reported within 15 minutes: {:?}",
        h.log()
    );
    // Anything late (a second report) would come right after.
    let settle = Instant::now() + Duration::from_secs(5);
    while Instant::now() < settle {
        if let Ok(input) = rx.recv_timeout(Duration::from_millis(50)) {
            brain.step(input);
        }
    }

    let events = acpmux.events(&session, 0).unwrap();
    let mut by_kind: BTreeMap<&str, usize> = BTreeMap::new();
    for e in &events {
        *by_kind.entry(e.kind.as_str()).or_default() += 1;
    }
    let said: String = events
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| {
            Value::Object(e.msg.clone())
                .pointer("/params/update/content/text")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect();
    let goals: Vec<String> = events
        .iter()
        .filter_map(|e| {
            Value::Object(e.msg.clone())
                .pointer("/params/update/_meta/goal/status")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect();
    let prompts = events.iter().filter(|e| e.kind == "session/prompt").count();
    // No Chief turn runs here: the report waits in the brain's state for the log. The loop above
    // stops at the first report, so a report that holds the answer is the only one.
    let report = brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.report.clone())
        .unwrap_or_default();
    eprintln!("session {session}: {total:?} to the report");
    eprintln!("event kinds: {by_kind:?}");
    eprintln!("goal statuses: {goals:?}");
    eprintln!("the agent said: {said}");
    eprintln!("report: {report}");

    assert_eq!(prompts, 1, "exactly one prompt: {by_kind:?}");
    assert!(
        goals.iter().any(|g| g == "active"),
        "the goal was set: {goals:?}"
    );
    assert_eq!(
        goals.last().map(String::as_str),
        Some("complete"),
        "{goals:?}"
    );
    assert!(said.contains("PAUSED"), "it tried to stop first: {said}");
    assert!(
        said.contains("REPORTED") && said.contains("work-done"),
        "{said}"
    );
    // Its final words after the goal ended (Codex may say REPORTED in one of its own turns and
    // "Goal complete" in the last): the answer, never the PAUSED turn.
    assert!(
        report.contains("work-done") && !report.contains("PAUSED"),
        "the first report is the answer, not the PAUSED turn: {report}"
    );
    let _ = acpmux.end_session(&session);
}
