//! Chief subagents run hidden by default (#26386: their workspaces filled the
//! sidebar's topic groups between the user's own). The setting
//! `subagents.showWorkspaces` opts back in; `control show ID` opens one
//! hidden subagent's workspace and `control hide ID` closes it again, while
//! the subagent keeps working.

mod common;

use std::path::Path;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};
use optchat_chief::workspaces::{WorkspaceRef, Workspaces};

/// Records the workspaces opened (key, name, group) and closed (key).
#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<(String, String, String)>>,
    closed: Mutex<Vec<String>>,
}

impl Workspaces for Recorder {
    fn open(
        &self,
        key: &str,
        _session: &str,
        name: &str,
        group: &str,
        _cwd: &Path,
    ) -> Result<String, String> {
        self.opened
            .lock()
            .unwrap()
            .push((key.to_owned(), name.to_owned(), group.to_owned()));
        Ok(key.to_owned())
    }
    fn rename(&self, _key: &str, _name: &str) -> Result<(), String> {
        Ok(())
    }
    fn close(&self, key: &str) -> Result<(), String> {
        self.closed.lock().unwrap().push(key.to_owned());
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
    fn locate(&self, _key: &str) -> Option<WorkspaceRef> {
        Some(WorkspaceRef {
            id: "ws_0123456789abcdef0123456789abcdef".into(),
            session: "cmux-chief-h0me".into(),
        })
    }
}

/// A brain and spawner on `recorder`, with `show` as the setting.
fn setup(recorder: &Arc<Recorder>, show: Option<&str>) -> (Harness, Arc<Spawner>) {
    setup_with(recorder, show, "approve-all")
}

fn setup_with(
    recorder: &Arc<Recorder>,
    show: Option<&str>,
    policy: &str,
) -> (Harness, Arc<Spawner>) {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    let ws: Arc<dyn Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
    if let Some(show) = show {
        h.brain
            .set_setting("subagents.showWorkspaces", show)
            .unwrap();
    }
    let sp = Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: "claude".into(),
                policy: policy.into(),
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
        .with_workspaces(Some(ws)),
    );
    (h, sp)
}

/// Spawns one task and steps the brain until the spawn answered and the
/// brain took every input.
fn spawn(h: &mut Harness, sp: &Arc<Spawner>, task: &str) -> String {
    let (a, task) = (sp.clone(), task.to_owned());
    let worker = std::thread::spawn(move || a.spawn(vec![task], None));
    while !worker.is_finished() {
        if let Ok(i) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(i);
        }
    }
    drain(h);
    worker.join().unwrap().unwrap()
}

fn drain(h: &mut Harness) {
    while let Ok(i) = h.rx.recv_timeout(Duration::from_millis(100)) {
        h.brain.step(i);
    }
}

/// `control <action> <id>` through the brain, as the Chief's tool sends it;
/// its answer comes once the workspace is open or closed.
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

fn workspace(h: &Harness, id: &str) -> Option<String> {
    h.brain
        .state()
        .sub(id)
        .and_then(|(_, s)| s.workspace.clone())
}

#[test]
fn by_default_a_subagent_runs_hidden_and_show_and_hide_toggle_its_workspace() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp) = setup(&recorder, None);
    let answer = spawn(&mut h, &sp, "Title: PR confidence check\nsay hello");

    // Hidden: nothing in the sidebar, and the answer says so and how to show it.
    assert!(recorder.opened.lock().unwrap().is_empty(), "{answer}");
    assert!(answer.contains("hidden"), "{answer}");
    assert!(answer.contains("subagents.showWorkspaces"), "{answer}");
    assert!(answer.contains("\"show\""), "{answer}");
    assert!(
        !answer.contains("ws_"),
        "no workspace id for a hidden one: {answer}"
    );
    assert_eq!(workspace(&h, "a1"), None);
    let session_env = h
        .agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .find(|s| s.tags.contains_key("optchat.subagent"))
        .and_then(|s| s.env.get("CMUX_WORKSPACE_ID").cloned())
        .expect("the session still carries its workspace's key");
    assert!(
        control(&mut h, "status", "a1").unwrap().contains("hidden"),
        "status names it hidden"
    );

    // show: its workspace opens under the key its session already carries.
    let shown = control(&mut h, "show", "a1").unwrap();
    assert!(shown.starts_with("outcome: done."), "{shown}");
    assert!(
        shown.contains("ws_0123456789abcdef0123456789abcdef"),
        "{shown}"
    );
    let opened = recorder.opened.lock().unwrap().clone();
    assert_eq!(opened.len(), 1, "{opened:?}");
    let (key, name, group) = opened[0].clone();
    assert_eq!(key.to_uppercase(), session_env);
    assert_eq!(name, "PR confidence check");
    assert_eq!(
        group,
        optchat_chief::workspaces::topic_group("Title: PR confidence check\nsay hello")
    );
    assert_eq!(workspace(&h, "a1").as_deref(), Some(key.as_str()));
    // A second show is a noop, never a second workspace.
    assert!(
        control(&mut h, "show", "a1")
            .unwrap()
            .starts_with("outcome: noop.")
    );
    assert_eq!(recorder.opened.lock().unwrap().len(), 1);

    // hide: its workspace closes; the subagent goes on hidden.
    let hidden = control(&mut h, "hide", "a1").unwrap();
    assert!(hidden.starts_with("outcome: done."), "{hidden}");
    assert_eq!(*recorder.closed.lock().unwrap(), vec![key.clone()]);
    assert_eq!(workspace(&h, "a1"), None);
    assert!(
        control(&mut h, "hide", "a1")
            .unwrap()
            .starts_with("outcome: noop.")
    );

    // show again: a new workspace under a fresh key (the daemon replays a
    // closed key's mutations), in the same group.
    assert!(
        control(&mut h, "show", "a1")
            .unwrap()
            .starts_with("outcome: done.")
    );
    let opened = recorder.opened.lock().unwrap().clone();
    assert_eq!(opened.len(), 2, "{opened:?}");
    assert_ne!(opened[1].0, key, "a closed key never opens again");
    assert_eq!(
        (opened[1].1.as_str(), opened[1].2.as_str()),
        (name.as_str(), group.as_str())
    );

    // A subagent that does not exist is an error, not a workspace.
    assert!(control(&mut h, "show", "a9").is_err());
}

#[test]
fn the_setting_opts_back_into_a_workspace_per_subagent() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp) = setup(&recorder, Some("true"));
    let answer = spawn(&mut h, &sp, "Title: Dev build speed audit\nsay hello");
    assert_eq!(recorder.opened.lock().unwrap().len(), 1, "{answer}");
    assert!(
        answer.contains("workspace \"Dev build speed audit\""),
        "{answer}"
    );
    assert!(workspace(&h, "a1").is_some());

    // Off again: the next spawn runs hidden; the one already shown stays.
    h.brain
        .set_setting("subagents.showWorkspaces", "false")
        .unwrap();
    let answer = spawn(&mut h, &sp, "Title: Agent system rules\nsay hello");
    assert!(answer.contains("hidden"), "{answer}");
    assert_eq!(recorder.opened.lock().unwrap().len(), 1);
    assert!(workspace(&h, "a1").is_some());
    assert_eq!(workspace(&h, "a2"), None);
}

#[test]
fn the_setting_is_off_by_default_and_saved_with_the_chief_settings() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("settings.json");
    let settings = optchat_chief::chief_settings::ChiefSettings::load(&file);
    assert!(!settings.show_subagent_workspaces);
    assert_eq!(
        settings.to_json()["subagents"]["showWorkspaces"],
        serde_json::json!(false)
    );
    let recorder = Arc::new(Recorder::default());
    let (mut h, _) = setup(&recorder, None);
    assert_eq!(
        h.brain
            .set_setting("subagents.showWorkspaces", "true")
            .unwrap(),
        "subagents.showWorkspaces = true"
    );
    assert!(
        h.brain
            .set_setting("subagents.showWorkspaces", "maybe")
            .is_err()
    );
    let saved =
        optchat_chief::chief_settings::ChiefSettings::load(&h.dir.path().join("settings.json"));
    assert!(saved.show_subagent_workspaces);
    drain(&mut h);
}

/// A subagent that runs with policy ask still gets its workspace: only its
/// tab shows an Allow button for its prompts.
#[test]
fn a_subagent_that_asks_before_it_acts_still_shows() {
    let recorder = Arc::new(Recorder::default());
    let (mut h, sp) = setup_with(&recorder, None, "ask");
    let answer = spawn(&mut h, &sp, "Title: Careful change\nsay hello");
    assert_eq!(recorder.opened.lock().unwrap().len(), 1, "{answer}");
    assert!(!answer.contains("hidden"), "{answer}");
    assert!(workspace(&h, "a1").is_some());
}
