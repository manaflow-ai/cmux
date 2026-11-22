//! Fresh-Chief eval, first-run walk (user 12374): a new person's Chief (clean home, empty
//! memory, default grant) spawns a subagent; the answer names a workspace with a real id, in a
//! group, and the Chief's reply links the subagent. Same steps for every placement.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::chief_profile::Grant;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::workspaces::{self, Workspaces};

#[derive(Default)]
struct Opened(Mutex<Vec<(String, String)>>);

impl Workspaces for Opened {
    fn open(
        &self,
        key: &str,
        _s: &str,
        name: &str,
        group: &str,
        _c: &std::path::Path,
    ) -> Result<String, String> {
        self.0.lock().unwrap().push((name.into(), group.into()));
        Ok(key.to_owned())
    }
    fn rename(&self, _k: &str, _n: &str) -> Result<(), String> {
        Ok(())
    }
    fn place(&self) -> String {
        "this Mac".into()
    }
    fn locate(&self, _k: &str) -> Option<workspaces::WorkspaceRef> {
        Some(workspaces::WorkspaceRef {
            id: "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e".into(),
            session: "cmux-chief-h0me".into(),
        })
    }
}

fn walk(ws: Option<Arc<dyn Workspaces>>) -> (String, bool, String) {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    h.brain.set_workspaces(ws.clone());
    // Shown at start (#26386: hidden unless this setting is on).
    h.brain
        .set_setting("subagents.showWorkspaces", "true")
        .unwrap();
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
        .with_workspaces(ws),
    );
    let a = sp.clone();
    let worker =
        std::thread::spawn(move || a.spawn(vec!["Title: First task\nsay hello".into()], None));
    while !worker.is_finished() {
        if let Ok(i) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(i);
        }
    }
    while let Ok(i) = h.rx.recv_timeout(Duration::from_millis(100)) {
        h.brain.step(i);
    }
    let answer = worker.join().unwrap().unwrap();
    let session = h
        .brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.session_id.clone());
    let reply = workspaces::link_subagents("a1 is on it.", "optchat-chief:0123abcd", |id| {
        (id == "a1").then(|| session.clone()).flatten()
    });
    let grant_spawns = Grant::all().allows("spawn") && Grant::all().allows("tell");
    (answer, grant_spawns, reply)
}

#[test]
fn a_fresh_chief_with_a_workspace_host_answers_a_workspace_and_a_linked_reply() {
    let ws: Arc<dyn Workspaces> = Arc::new(Opened::default());
    let (answer, granted, reply) = walk(Some(ws));
    assert!(granted, "the default grant lets a Chief spawn and tell");
    assert!(answer.contains("workspace \"First task\""), "{answer}");
    assert!(
        answer.contains("ws_"),
        "the real workspace id is in the answer: {answer}"
    );
    assert!(
        reply.contains("](cmux://chief/"),
        "the reply links a1: {reply}"
    );
}

#[test]
fn without_a_workspace_host_the_answer_says_why_in_words_a_person_can_act_on() {
    let (answer, _, _) = walk(None);
    assert!(answer.contains("no cmux workspace ("), "{answer}");
}
