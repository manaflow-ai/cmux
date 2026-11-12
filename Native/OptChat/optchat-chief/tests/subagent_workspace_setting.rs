//! The Chief setting `subagents.showWorkspaces` puts every subagent's workspace in the sidebar;
//! off (the default), the Chief's rules choose between the sidebar and the collapsed "Chief's
//! workspaces" group (chief_two_workspace_kinds.rs). Either way every subagent gets a workspace.

mod common;

use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::workspaces::{WorkspaceRef, Workspaces};

/// Records the workspaces opened (key, name, group) and closed (key).
#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<(String, String, String)>>,
    closed: Mutex<Vec<String>>,
    closed_changed: Condvar,
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
        self.closed_changed.notify_all();
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
        .with_workspaces(Some(ws))
        // No user rules: the defaults, never the developer's own file.
        .with_user_settings(Some(h.dir.path().join("cmux-next.json"))),
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

fn workspace(h: &Harness, id: &str) -> Option<String> {
    h.brain
        .state()
        .sub(id)
        .and_then(|(_, s)| s.workspace.clone())
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

    assert_eq!(recorder.opened.lock().unwrap()[0].2, "", "in the sidebar");

    // Off again: the next short spawn goes to the Chief's group, still with a workspace.
    h.brain
        .set_setting("subagents.showWorkspaces", "false")
        .unwrap();
    let answer = spawn(&mut h, &sp, "Title: Agent system rules\nsay hello");
    assert!(!answer.contains("hidden"), "{answer}");
    let opened = recorder.opened.lock().unwrap().clone();
    assert_eq!(opened.len(), 2, "{answer}");
    assert_eq!(opened[1].2, "Chief's workspaces");
    assert!(workspace(&h, "a1").is_some());
    assert!(workspace(&h, "a2").is_some());
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
    assert_eq!(
        recorder.opened.lock().unwrap()[0].2,
        "",
        "in the sidebar, not the group"
    );
    assert!(workspace(&h, "a1").is_some());
}
