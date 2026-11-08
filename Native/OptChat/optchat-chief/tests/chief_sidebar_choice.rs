//! The Chief decides per spawn whether a subagent shows in the sidebar
//! (a1018, Lawrence 2026-11-05: "the chief will make the decision if the
//! workspace is visible in the sidebar or not", and the user shapes the
//! heuristics; aziz: "not liking how new agents by chief don't appear in
//! sidebar by default"). `spawn(sidebar)` takes shown, hidden or auto; auto
//! (the default) shows a bigger task and hides a short errand; the user's
//! cmux-next.json `chief.subagentSidebar` overrides every choice.

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
}

impl Workspaces for Recorder {
    fn open(&self, key: &str, _: &str, name: &str, _: &str, _: &Path) -> Result<String, String> {
        self.opened.lock().unwrap().push(name.to_owned());
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

#[test]
fn a_bigger_task_shows_by_default_and_a_short_errand_stays_hidden() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}));
    let answer = spawn(&mut h, &sp, json!({"tasks": [BIG]}));
    assert_eq!(
        *recorder.opened.lock().unwrap(),
        vec!["Chief sidebar rework".to_owned()],
        "{answer}"
    );
    assert!(
        answer.contains("bigger task"),
        "the answer says why: {answer}"
    );

    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Sha lookup\nlook up the sha of the last nightly"]}),
    );
    assert!(answer.contains("hidden"), "{answer}");
    assert!(answer.contains("\"show\""), "says how to show it: {answer}");
    assert_eq!(recorder.opened.lock().unwrap().len(), 1);
}

#[test]
fn the_chief_chooses_per_spawn_and_per_task() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}));
    // sidebar: hidden keeps even a big task out of the sidebar.
    let answer = spawn(&mut h, &sp, json!({"tasks": [BIG], "sidebar": "hidden"}));
    assert!(answer.contains("hidden"), "{answer}");
    assert!(recorder.opened.lock().unwrap().is_empty());
    // sidebar: shown puts a one-line task there; a task's own line wins.
    let answer = spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Quick look\nsay hello", "Sidebar: hidden\nTitle: Other\nsay hi"], "sidebar": "shown"}),
    );
    assert_eq!(
        *recorder.opened.lock().unwrap(),
        vec!["Quick look".to_owned()],
        "{answer}"
    );
    // The title never becomes the Sidebar line.
    assert!(!answer.contains("workspace \"Sidebar"), "{answer}");
    assert!(Call::parse("spawn", &json!({"tasks": ["x"], "sidebar": "maybe"})).is_err());
}

#[test]
fn the_users_setting_overrides_the_chief() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, config) = setup(&recorder, json!({"chief": {"subagentSidebar": "never"}}));
    let answer = spawn(&mut h, &sp, json!({"tasks": [BIG], "sidebar": "shown"}));
    assert!(answer.contains("chief.subagentSidebar"), "{answer}");
    assert!(recorder.opened.lock().unwrap().is_empty());
    // Read at each spawn: a change applies to the next one.
    std::fs::write(
        &config,
        json!({"chief.subagentSidebar": "always"}).to_string(),
    )
    .unwrap();
    spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Tiny\nsay hello"], "sidebar": "hidden"}),
    );
    assert_eq!(*recorder.opened.lock().unwrap(), vec!["Tiny".to_owned()]);
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
    let sidebar = &spawn["inputSchema"]["properties"]["sidebar"];
    assert_eq!(sidebar["enum"], json!(["auto", "shown", "hidden"]));
    let how = sidebar["description"].as_str().unwrap();
    assert!(how.contains("shown") && how.contains("hidden"), "{how}");
}
