//! A Claude subagent works under a goal until its task is done, on Opus 5.5
//! (user, 2026-11-10: "you should have opus 5.5 set goal/loop so it doesn't
//! stop until it's all done"). Its start is one prompt, its view and task;
//! the goal comes with the session (acpmux `stopCondition`: the prompt Stop
//! hook Claude Code's `/goal` adds). `chief.subagentGoal: false` turns the
//! goal off.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::json;

fn spawner(
    h: &Harness,
    harness: &str,
    goal: bool,
    user: Option<std::path::PathBuf>,
) -> Arc<Spawner> {
    Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: harness.into(),
                policy: "approve-all".into(),
                model: None,
                effort: None,
                preset: Some("optchat-sub-h0me".into()),
                cwd: h.dir.path().join("subagent"),
                prefix: "optchat-sub-h0me".into(),
                parent: optchat_chief::brain::PARENT.into(),
                claude_md: None,
            },
            h.tx.clone(),
            Arc::new(|_: &str| {}),
        )
        .with_user_settings(user)
        .with_goal(goal),
    )
}

fn spawn(h: &mut Harness, sp: Arc<Spawner>, task: &str) -> String {
    let task = task.to_owned();
    let worker = std::thread::spawn(move || sp.spawn(vec![task], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap().unwrap()
}

fn text(blocks: &[serde_json::Value]) -> String {
    blocks
        .iter()
        .filter_map(|b| b["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// The whole start is one prompt, the subagent's view and task: its first turn is the work.
/// The goal is set with the session (acpmux `stopCondition`, a prompt Stop hook at every start of
/// its Claude Code), not by a second `/goal` prompt after a "reply only `ready`" turn (user,
/// 2026-11-18: "why wasn't it just one prompt?").
#[test]
fn subagent_goal_a_claude_subagent_starts_with_one_prompt_under_the_goal_on_opus() {
    let mut h = Harness::new(default_script());
    let sp = spawner(&h, "claude", true, None);
    let started = spawn(&mut h, sp, "Fix the flaky test and land it.");
    assert!(started.contains("Started a1"), "{started}");
    h.agents.wait_prompts(1);
    // A second prompt would come right after the first turn ended.
    std::thread::sleep(Duration::from_millis(300));
    let inner = h.agents.inner.lock().unwrap();
    let spec = inner.specs.last().expect("a session");
    assert_eq!(
        spec.model.as_deref(),
        Some("claude-opus-5-5"),
        "a Claude subagent with no model named runs on Opus 5.5"
    );
    assert_eq!(
        spec.stop_condition.as_deref(),
        Some(optchat_chief::goal::CONDITION),
        "the goal is set with the session"
    );
    assert_eq!(inner.prompts.len(), 1, "one prompt: {:?}", inner.prompts);
    let task = text(&inner.prompts[0]);
    assert!(task.contains("Fix the flaky test and land it."), "{task}");
    assert!(!task.contains("ready"), "no handshake: {task}");
    assert!(!task.contains("Do not start yet"), "{task}");
    assert!(!task.starts_with("/goal"), "{task}");
    // The subagent knows the bar it is held to.
    assert!(task.contains(optchat_chief::goal::CONDITION), "{task}");
    assert!(
        optchat_chief::goal::CONDITION.chars().count() <= optchat_chief::goal::CONDITION_LIMIT,
        "under Claude Code's condition cap"
    );
}

/// A first turn that was cancelled (or failed) is the subagent's end: nothing follows it.
#[test]
fn subagent_goal_nothing_follows_a_cancelled_first_turn() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().answer = Some(json!({"stopReason": "cancelled"}));
    let sp = spawner(&h, "claude", true, None);
    spawn(&mut h, sp, "Copy the go file into done.");
    std::thread::sleep(Duration::from_millis(300));
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 1, "{:?}", inner.prompts);
}

#[test]
fn subagent_goal_off_by_setting_sends_only_the_task() {
    let mut h = Harness::new(default_script());
    let user = h.dir.path().join("cmux-next.json");
    std::fs::write(&user, json!({"chief": {"subagentGoal": false}}).to_string()).unwrap();
    let sp = spawner(&h, "claude", true, Some(user));
    spawn(&mut h, sp, "Fix the flaky test and land it.");
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 1, "{:?}", inner.prompts);
    let task = text(&inner.prompts[0]);
    assert!(!task.contains("/goal"), "{task}");
    assert!(!task.contains(optchat_chief::goal::CONDITION), "{task}");
    assert_eq!(inner.specs.last().unwrap().stop_condition, None);
}

#[test]
fn subagent_goal_never_on_a_codex_subagent() {
    let mut h = Harness::new(default_script());
    let sp = spawner(&h, "codex", true, None);
    spawn(&mut h, sp, "Fix the flaky test and land it.");
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 1, "{:?}", inner.prompts);
    assert_ne!(
        inner.specs.last().and_then(|s| s.model.as_deref()),
        Some("claude-opus-5-5")
    );
    assert_eq!(inner.specs.last().unwrap().stop_condition, None);
}

#[test]
fn subagent_goal_setting_reads_on_unless_false() {
    use optchat_chief::goal::on;
    assert!(on(None));
    assert!(on(Some(&json!({}))));
    assert!(on(Some(&json!({"chief": {"subagentGoal": true}}))));
    assert!(!on(Some(&json!({"chief": {"subagentGoal": false}}))));
    assert!(!on(Some(&json!({"chief.subagentGoal": false}))));
}

/// a1147's real spawn on build a8a0a78 (2026-11-12): the task came first, then
/// Claude Code refused `/goal` ("can't run while hooks are restricted
/// (disableAllHooks ...)"), because the subagent folder's project settings
/// turned every hook off. A subagent's settings leave hooks on; the Chief's
/// own turn folder keeps them off.
#[test]
fn subagent_goal_subagent_settings_leave_hooks_on() {
    use optchat_chief::prompt::Tools;
    use optchat_chief::session_dir::{SessionSetup, write, write_subagent};
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(&dir.path().join("mux"));
    paths.create().unwrap();
    let setup = SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Mcp,
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    };
    write(&paths, &setup).unwrap();
    write_subagent(&paths, &setup, "subagent").unwrap();
    let read = |path: std::path::PathBuf| -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
    };
    for name in ["settings.json", "settings.local.json"] {
        let sub = read(paths.subagent.join(".claude").join(name));
        assert_eq!(sub["disableAllHooks"], json!(false), "{name}: {sub}");
        assert!(sub.get("allowManagedHooksOnly").is_none(), "{name}: {sub}");
    }
}

/// The goal reaches acpmux as `_meta.acpmux.stopCondition` on `session/new`; a session with
/// none sends no key.
#[test]
fn subagent_goal_reaches_acpmux_as_its_stop_condition() {
    use optchat_chief::acpmux::{STOP_CONDITION, SessionSpec, session_meta};
    let spec = SessionSpec {
        name: "optchat-sub-h0me-a1".into(),
        harness: "claude".into(),
        stop_condition: Some(optchat_chief::goal::CONDITION.into()),
        ..Default::default()
    };
    let meta = session_meta(&spec, Some("optchat-sub-h0me"));
    assert_eq!(meta[STOP_CONDITION], json!(optchat_chief::goal::CONDITION));
    let plain = session_meta(
        &SessionSpec {
            stop_condition: None,
            ..spec
        },
        None,
    );
    assert!(plain.get(STOP_CONDITION).is_none(), "{plain}");
}
