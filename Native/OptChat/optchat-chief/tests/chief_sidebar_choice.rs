//! Where a subagent's workspace goes (a1018, then Lawrence 2026-11-09: "Chief's
//! default must be to NOT start new workspaces all the time"). `spawn(workspace)`
//! takes user, internal, none or auto. auto (the default) gives user-facing work
//! (UI, design, screenshots, the user's input or sign-in) a sidebar workspace and
//! everything else none: its chat lives in acpmux and its link opens it. internal
//! puts it in the collapsed "Chief's workspaces" group, made once and reused. The
//! user's cmux-next.json `chief.subagentSidebar` (auto, always, group, never; a1018's
//! values keep their meaning) overrides every choice.

mod common;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Orchestrator};
use optchat_chief::workspaces::{WorkspaceRef, Workspaces};
use serde_json::json;

#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<String>>,
    /// `(name, group)` of each workspace opened.
    groups: Mutex<Vec<(String, String)>>,
}

impl Workspaces for Recorder {
    fn open(
        &self,
        key: &str,
        _: &str,
        name: &str,
        group: &str,
        _: &Path,
    ) -> Result<String, String> {
        self.opened.lock().unwrap().push(name.to_owned());
        self.groups
            .lock()
            .unwrap()
            .push((name.to_owned(), group.to_owned()));
        Ok(key.to_owned())
    }
    fn rename(&self, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn close(&self, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
    fn locate(&self, _: &str) -> Option<WorkspaceRef> {
        None
    }
}

/// A brain and spawner whose user settings file holds `user`.
fn setup(recorder: &Arc<Recorder>, user: serde_json::Value) -> (Harness, Arc<Spawner>, PathBuf) {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    let config = h.dir.path().join("cmux-next.json");
    std::fs::write(&config, user.to_string()).unwrap();
    let ws: Arc<dyn Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
    let sp = Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: "claude".into(),
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
        .with_workspaces(Some(ws))
        .with_user_settings(Some(config.clone())),
    );
    (h, sp, config)
}

/// Spawns through the tool call the Chief makes (`spawn` with `args`).
fn spawn(h: &mut Harness, sp: &Arc<Spawner>, args: serde_json::Value) -> String {
    let Call::Spawn { tasks, cwd, .. } = Call::parse("spawn", &args).unwrap() else {
        panic!("not a spawn");
    };
    let a = sp.clone();
    let worker = std::thread::spawn(move || a.spawn(tasks, cwd));
    while !worker.is_finished() {
        if let Ok(i) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(i);
        }
    }
    while let Ok(i) = h.rx.recv_timeout(Duration::from_millis(100)) {
        h.brain.step(i);
    }
    worker.join().unwrap().unwrap()
}

const BIG: &str = "Title: Chief sidebar rework\nReplace the global on/off with a per-spawn decision by the Chief. \
Spawn takes a visibility; auto applies heuristics the user can shape in Settings and in the settings file. \
Write red tests first, then the fix, check it in the real app before and after, and land it on \
the feature branch with a plain push, then report the range you landed and anything left open.";

const GROUP: &str = "Chief's workspaces";

#[test]
fn by_default_only_user_facing_work_gets_a_workspace() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}));
    // A long build with no user-facing word: no workspace; its chat lives in acpmux.
    let answer = spawn(&mut h, &sp, json!({"tasks": [BIG]}));
    assert!(recorder.opened.lock().unwrap().is_empty(), "{answer}");
    assert!(answer.contains("no workspace"), "{answer}");
    assert!(answer.contains("\"show\""), "says how to show it: {answer}");
    // A short errand: none either.
    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Sha lookup\nlook up the sha of the last nightly"]}),
    );
    assert!(answer.contains("no workspace"), "{answer}");
    assert!(recorder.opened.lock().unwrap().is_empty());
    // UI work the user will look at: the normal sidebar, in no group.
    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Tab bar polish\nFix the tab bar UI and send light/dark screenshots"]}),
    );
    assert_eq!(
        *recorder.groups.lock().unwrap(),
        vec![("Tab bar polish".to_owned(), String::new())],
        "{answer}"
    );
    assert!(answer.contains("user-facing"), "{answer}");
}

#[test]
fn the_chief_chooses_user_internal_or_none_per_spawn_and_per_task() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}));
    // workspace: none keeps even UI work out of the sidebar.
    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: UI peek\nlook at the UI"], "workspace": "none"}),
    );
    assert!(answer.contains("no workspace"), "{answer}");
    assert!(recorder.opened.lock().unwrap().is_empty());
    // workspace: user shows a long build; a task's own line wins.
    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": [BIG, "Workspace: internal\nTitle: Diff holder\nhold the diffs of the sidebar work"], "workspace": "user"}),
    );
    let mut groups = recorder.groups.lock().unwrap().clone();
    groups.sort();
    assert_eq!(
        groups,
        vec![
            ("Chief sidebar rework".to_owned(), String::new()),
            ("Diff holder".to_owned(), GROUP.to_owned()),
        ],
        "{answer}"
    );
    assert!(!answer.contains("workspace \"Workspace"), "{answer}");
    // The old values still parse: shown is user, hidden is none.
    let Call::Spawn { tasks, .. } =
        Call::parse("spawn", &json!({"tasks": ["x"], "sidebar": "shown"})).unwrap()
    else {
        panic!("not a spawn");
    };
    assert!(tasks[0].starts_with("Workspace: user"), "{tasks:?}");
    assert!(Call::parse("spawn", &json!({"tasks": ["x"], "workspace": "maybe"})).is_err());
}

#[test]
fn the_users_setting_overrides_the_chief() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, config) = setup(&recorder, json!({"chief": {"subagentSidebar": "never"}}));
    let answer = spawn(&mut h, &sp, json!({"tasks": [BIG], "workspace": "user"}));
    assert!(answer.contains("chief.subagentSidebar"), "{answer}");
    assert!(recorder.opened.lock().unwrap().is_empty());
    // group: work that is not user-facing goes to the Chief's group, not none.
    std::fs::write(
        &config,
        json!({"chief.subagentSidebar": "group"}).to_string(),
    )
    .unwrap();
    spawn(&mut h, &sp, json!({"tasks": ["Title: Tiny\nsay hello"]}));
    assert_eq!(
        *recorder.groups.lock().unwrap(),
        vec![("Tiny".to_owned(), GROUP.to_owned())]
    );
    // always still puts every subagent in the sidebar.
    std::fs::write(
        &config,
        json!({"chief.subagentSidebar": "always"}).to_string(),
    )
    .unwrap();
    spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Tiny two\nsay hello"], "workspace": "none"}),
    );
    assert_eq!(
        recorder.groups.lock().unwrap().last().cloned(),
        Some(("Tiny two".to_owned(), String::new()))
    );
}

#[test]
fn the_spawn_tool_offers_the_choice_and_tells_the_chief_how_to_pick() {
    let tools = chief_kernel::tools::tool_list(false, &|_| true);
    let spawn = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "spawn")
        .unwrap();
    assert!(spawn["inputSchema"]["properties"]["sidebar"].is_null());
    let workspace = &spawn["inputSchema"]["properties"]["workspace"];
    assert_eq!(
        workspace["enum"],
        json!(["auto", "user", "internal", "none"])
    );
    let how = workspace["description"].as_str().unwrap();
    assert!(how.contains(GROUP) && how.contains("none"), "{how}");
}
