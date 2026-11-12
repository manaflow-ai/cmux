//! Every Chief subagent gets a workspace, of one of two kinds, and none is ever hidden (Aziz,
//! relayed 2026-11-11: "Chief-made agents getting hidden quite often - cant find them in sidebar
//! despite me telling it to always show agents in sidebar ... make chief can only make 2 types of
//! workspaces, no hidden workspaces at all, one type is just normal that user can view, and other
//! type is just in a 'Chief's workspaces' where it is just in a hidden group, but is still visible
//! to the user").
//!
//! - `user`: a normal sidebar workspace (ungrouped, at the top below the pinned rows), for work the
//!   user watches, joins or steers, UI and design, long builds, anything that needs their input.
//! - `chief`: a workspace in the collapsed "Chief's workspaces" group, still listed and searchable,
//!   for lookups, status checks, land-queue followers and cleanups.
//!
//! `control hide` moves a workspace into the group and `control show` moves it out; nothing
//! closes a Chief workspace on its own. A user rule ("always show agents in the sidebar", or
//! `chief.subagentSidebar: always`) makes every subagent `user`.

mod common;

use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, ControlCall, Orchestrator};
use optchat_chief::workspaces::{WorkspaceRef, Workspaces};
use serde_json::json;

const CHIEF_GROUP: &str = "Chief's workspaces";

/// Records opens (name, group), moves (key, into the Chief's group) and closes (key).
#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<(String, String, String)>>,
    moved: Mutex<Vec<(String, bool)>>,
    closed: Mutex<Vec<String>>,
}

impl Recorder {
    fn groups(&self) -> Vec<(String, String)> {
        self.opened
            .lock()
            .unwrap()
            .iter()
            .map(|(_, n, g)| (n.clone(), g.clone()))
            .collect()
    }
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
        self.opened
            .lock()
            .unwrap()
            .push((key.to_owned(), name.to_owned(), group.to_owned()));
        Ok(key.to_owned())
    }
    fn rename(&self, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn close(&self, key: &str) -> Result<(), String> {
        self.closed.lock().unwrap().push(key.to_owned());
        Ok(())
    }
    fn close_idle(&self, key: &str) -> Result<bool, String> {
        self.closed.lock().unwrap().push(key.to_owned());
        Ok(true)
    }
    fn move_to(&self, key: &str, into_chief_group: bool) -> Result<(), String> {
        self.moved
            .lock()
            .unwrap()
            .push((key.to_owned(), into_chief_group));
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
    fn locate(&self, _: &str) -> Option<WorkspaceRef> {
        Some(WorkspaceRef {
            id: "ws_0123456789abcdef0123456789abcdef".into(),
            session: "cmux-chief-h0me".into(),
        })
    }
}

/// A brain and spawner whose cmux-next.json holds `user` and whose person.md holds `person`.
fn setup(
    recorder: &Arc<Recorder>,
    user: serde_json::Value,
    person: &str,
) -> (Harness, Arc<Spawner>, PathBuf) {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    let config = h.dir.path().join("cmux-next.json");
    std::fs::write(&config, user.to_string()).unwrap();
    let person_md = h.dir.path().join("person.md");
    std::fs::write(&person_md, person).unwrap();
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
        .with_user_settings(Some(config.clone()))
        .with_person(person_md),
    );
    (h, sp, config)
}

fn drain(h: &mut Harness) {
    while let Ok(i) = h.rx.recv_timeout(Duration::from_millis(100)) {
        h.brain.step(i);
    }
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
    drain(h);
    worker.join().unwrap().unwrap()
}

fn control(h: &mut Harness, action: &str, id: &str) -> Result<String, String> {
    let (reply, answer) = channel();
    h.brain.step(Input::Control {
        request: ControlCall {
            action: action.into(),
            id: Some(id.into()),
            ..Default::default()
        },
        reply,
    });
    let until = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(a) = answer.try_recv() {
            drain(h);
            return a;
        }
        assert!(
            Instant::now() < until,
            "control {action} {id} never answered"
        );
        if let Ok(i) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(i);
        }
    }
}

const LOOKUP: &str = "Title: Sha lookup\nlook up the sha of the last nightly";
const DESIGN: &str =
    "Title: Hat variants\nMake 5 design variants of the composer hat, light and dark shots";

#[test]
fn every_subagent_gets_a_workspace_and_none_is_hidden() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}), "");
    let lookup = spawn(&mut h, &sp, json!({"tasks": [LOOKUP]}));
    let design = spawn(&mut h, &sp, json!({"tasks": [DESIGN]}));
    assert_eq!(
        recorder.groups(),
        vec![
            ("Sha lookup".to_owned(), CHIEF_GROUP.to_owned()),
            ("Hat variants".to_owned(), String::new()),
        ],
        "{lookup}\n{design}"
    );
    for answer in [&lookup, &design] {
        assert!(
            !answer.to_lowercase().contains("hidden"),
            "no subagent is hidden: {answer}"
        );
    }
    assert!(lookup.contains(CHIEF_GROUP), "{lookup}");
    let status = control(&mut h, "status", "a1").unwrap();
    assert!(!status.to_lowercase().contains("hidden"), "{status}");
}

#[test]
fn spawn_takes_user_or_chief_and_older_values_still_read() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}), "");
    spawn(&mut h, &sp, json!({"tasks": [DESIGN], "sidebar": "chief"}));
    spawn(&mut h, &sp, json!({"tasks": [LOOKUP], "sidebar": "user"}));
    // `hidden` from an older Chief is the Chief's group, never no workspace.
    spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Old hidden\nsay hi"], "sidebar": "hidden"}),
    );
    spawn(
        &mut h,
        &sp,
        json!({"tasks": ["Title: Old shown\nsay hi"], "sidebar": "shown"}),
    );
    assert_eq!(
        recorder.groups(),
        vec![
            ("Hat variants".to_owned(), CHIEF_GROUP.to_owned()),
            ("Sha lookup".to_owned(), String::new()),
            ("Old hidden".to_owned(), CHIEF_GROUP.to_owned()),
            ("Old shown".to_owned(), String::new()),
        ]
    );
    let tools = chief_kernel::tools::tool_list(false, &|_| true);
    let spawn_tool = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "spawn")
        .unwrap();
    let sidebar = &spawn_tool["inputSchema"]["properties"]["sidebar"];
    assert_eq!(sidebar["enum"], json!(["auto", "user", "chief"]));
    let how = sidebar["description"].as_str().unwrap();
    assert!(!how.to_lowercase().contains("hidden"), "{how}");
    assert!(how.contains(CHIEF_GROUP), "{how}");
}

#[test]
fn the_users_always_show_rule_makes_every_subagent_a_user_workspace() {
    // Aziz's rule, as the Chief remembers it in person.md.
    let recorder = Arc::new(Recorder::default());
    let person =
        "# Aziz\n\n## Learned\n\n- Always show agents in the sidebar (learned 2026-11-10)\n";
    let (mut h, sp, _) = setup(&recorder, json!({}), person);
    let answer = spawn(&mut h, &sp, json!({"tasks": [LOOKUP], "sidebar": "chief"}));
    assert_eq!(
        recorder.groups(),
        vec![("Sha lookup".to_owned(), String::new())],
        "{answer}"
    );
    // The setting does the same, and `never` still gives a workspace, in the Chief's group.
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, config) = setup(
        &recorder,
        json!({"chief": {"subagentSidebar": "always"}}),
        "",
    );
    spawn(&mut h, &sp, json!({"tasks": [LOOKUP], "sidebar": "chief"}));
    std::fs::write(
        &config,
        json!({"chief.subagentSidebar": "never"}).to_string(),
    )
    .unwrap();
    spawn(&mut h, &sp, json!({"tasks": [DESIGN], "sidebar": "user"}));
    assert_eq!(
        recorder.groups(),
        vec![
            ("Sha lookup".to_owned(), String::new()),
            ("Hat variants".to_owned(), CHIEF_GROUP.to_owned()),
        ]
    );
}

#[test]
fn hide_moves_into_the_chiefs_group_and_show_moves_it_out_never_closing_it() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp, _) = setup(&recorder, json!({}), "");
    spawn(&mut h, &sp, json!({"tasks": [LOOKUP]}));
    let key = recorder.opened.lock().unwrap()[0].0.clone();
    let shown = control(&mut h, "show", "a1").unwrap();
    assert!(shown.starts_with("outcome: done."), "{shown}");
    let hid = control(&mut h, "hide", "a1").unwrap();
    assert!(hid.starts_with("outcome: done."), "{hid}");
    assert!(hid.contains(CHIEF_GROUP), "{hid}");
    assert_eq!(
        *recorder.moved.lock().unwrap(),
        vec![(key.clone(), false), (key.clone(), true)]
    );
    assert!(recorder.closed.lock().unwrap().is_empty(), "nothing closes");
    assert_eq!(
        recorder.opened.lock().unwrap().len(),
        1,
        "no second workspace"
    );
    let workspace = h
        .brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.workspace.clone());
    assert_eq!(
        workspace.as_deref(),
        Some(key.as_str()),
        "it keeps its workspace"
    );
}
