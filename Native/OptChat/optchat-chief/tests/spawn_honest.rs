//! `spawn` tells the Chief the truth about each subagent (2026-10-06 bug:
//! the headless brain on cmux-lawrence had no app socket, so it made no
//! workspace, yet its answer said "each in its own cmux workspace" and the
//! Chief told the user so). The answer names each subagent's workspace and
//! where it lives, or says it has none and why; subagents start in the
//! directory the Chief asked for when it exists on this host, else the
//! answer says so.

mod common;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings, resolve_cwd};
use optchat_chief::tools::{Call, Command, Orchestrator, command};
use optchat_chief::workspaces::Workspaces;
use serde_json::json;

#[derive(Default)]
struct FakeWorkspaces {
    fail: bool,
    opened: Mutex<Vec<(String, String, PathBuf)>>,
}

impl Workspaces for FakeWorkspaces {
    fn open(&self, key: &str, session: &str, name: &str, cwd: &Path) -> Result<String, String> {
        if self.fail {
            return Err("boom".into());
        }
        let mut opened = self.opened.lock().unwrap();
        opened.push((session.to_owned(), name.to_owned(), cwd.to_owned()));
        Ok(key.to_owned())
    }

    fn rename(&self, _key: &str, _name: &str) -> Result<(), String> {
        Ok(())
    }

    fn place(&self) -> String {
        "the test app".to_owned()
    }
}

struct Setup {
    h: Harness,
    spawner: Arc<Spawner>,
}

fn setup(workspaces: Option<Arc<FakeWorkspaces>>) -> Setup {
    let mut h = Harness::new(default_script());
    let workspaces = workspaces.map(|w| w as Arc<dyn Workspaces>);
    h.brain.set_workspaces(workspaces.clone());
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
    .with_workspaces(workspaces)
    .with_no_workspace_reason("this Chief host has no cmux app");
    Setup {
        h,
        spawner: Arc::new(spawner),
    }
}

fn spawn(s: &mut Setup, tasks: &[&str], cwd: Option<&str>) -> String {
    let tasks: Vec<String> = tasks.iter().map(|t| t.to_string()).collect();
    let cwd = cwd.map(str::to_owned);
    let spawner = s.spawner.clone();
    let worker = std::thread::spawn(move || spawner.spawn(tasks, cwd));
    while !worker.is_finished() {
        if let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(20)) {
            s.h.brain.step(input);
        }
    }
    while let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(50)) {
        s.h.brain.step(input);
    }
    worker.join().unwrap().unwrap()
}

fn sub_cwds(s: &Setup) -> Vec<PathBuf> {
    // The fake agents saw no turn here, so every session is a subagent.
    s.h.agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|spec| spec.cwd.clone())
        .collect()
}

#[test]
fn the_answer_names_each_workspace_and_where_it_lives() {
    let mut s = setup(Some(Arc::new(FakeWorkspaces::default())));
    let answer = spawn(&mut s, &["list the files", "say the date"], None);
    assert!(
        answer.contains("a1: workspace \"a1 · list the files\" in the test app"),
        "{answer}"
    );
    assert!(
        answer.contains("a2: workspace \"a2 · say the date\" in the test app"),
        "{answer}"
    );
}

#[test]
fn without_workspaces_the_answer_never_claims_one() {
    let mut s = setup(None);
    let answer = spawn(&mut s, &["list the files"], None);
    assert!(!answer.contains("own cmux workspace"), "{answer}");
    assert!(
        answer.contains("a1: no cmux workspace (this Chief host has no cmux app)"),
        "{answer}"
    );
}

#[test]
fn a_workspace_that_failed_to_open_is_reported() {
    let mut s = setup(Some(Arc::new(FakeWorkspaces {
        fail: true,
        ..Default::default()
    })));
    let answer = spawn(&mut s, &["list the files"], None);
    assert!(
        answer.contains("a1: no cmux workspace (opening it failed: boom)"),
        "{answer}"
    );
}

#[test]
fn subagents_start_in_the_directory_asked_for() {
    let mut s = setup(Some(Arc::new(FakeWorkspaces::default())));
    let repo = s.h.dir.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let answer = spawn(&mut s, &["summarize"], Some(repo.to_str().unwrap()));
    assert_eq!(sub_cwds(&s), vec![repo.clone()]);
    assert!(
        answer.contains(&format!("in {}", repo.display())),
        "{answer}"
    );
}

#[test]
fn a_missing_directory_is_reported_and_the_default_is_used() {
    let mut s = setup(None);
    let missing = s.h.dir.path().join("no-such-repo");
    let answer = spawn(&mut s, &["summarize"], Some(missing.to_str().unwrap()));
    assert_eq!(sub_cwds(&s), vec![s.h.dir.path().join("subagent")]);
    assert!(
        answer.contains(&format!(
            "{} does not exist on this host",
            missing.display()
        )),
        "{answer}"
    );
}

#[test]
fn a_tilde_directory_is_the_hosts_home() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join("fun/repo")).unwrap();
    assert_eq!(
        resolve_cwd("~/fun/repo", home.path()),
        Ok(home.path().join("fun/repo"))
    );
    assert_eq!(resolve_cwd("~", home.path()), Ok(home.path().to_owned()));
    assert!(resolve_cwd("relative/dir", home.path()).is_err());
    assert!(resolve_cwd("~/fun/missing", home.path()).is_err());
}

#[test]
fn spawn_takes_an_optional_directory_from_every_surface() {
    assert_eq!(
        Call::parse("spawn", &json!({"tasks": ["x"], "cwd": "~/fun/repo"})),
        Ok(Call::Spawn {
            tasks: vec!["x".into()],
            cwd: Some("~/fun/repo".into())
        })
    );
    assert_eq!(
        command("spawn", &["--cwd", "~/fun/repo", "x"]),
        Ok(Command::Call(Call::Spawn {
            tasks: vec!["x".into()],
            cwd: Some("~/fun/repo".into())
        }))
    );
    let tools = optchat_chief::mcp::tools_for(false);
    let spawn = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "spawn")
        .unwrap();
    assert_eq!(spawn["inputSchema"]["properties"]["cwd"]["type"], "string");
}

#[test]
fn no_prompt_promises_a_workspace_the_host_may_not_make() {
    use optchat_chief::prompt::{SPAWN_DESCRIPTION, Tools, subagent_system_text, system_text};
    for text in [
        system_text(None, &Tools::Mcp),
        system_text(None, &Tools::Cli("/x/chief".into())),
        SPAWN_DESCRIPTION.to_owned(),
    ] {
        assert!(!text.contains("its own cmux workspace"), "{text}");
        assert!(!text.contains("of its own"), "{text}");
    }
    assert!(!subagent_system_text(None, &Tools::Mcp).contains("in a workspace of your\nown"));
}

#[test]
fn each_subagent_session_carries_the_id_of_its_own_workspace() {
    let workspaces = Arc::new(FakeWorkspaces::default());
    let mut s = setup(Some(workspaces.clone()));
    spawn(&mut s, &["one", "two"], None);
    let specs = s.h.agents.inner.lock().unwrap().specs.clone();
    let ids: Vec<String> = specs
        .iter()
        .map(|spec| {
            spec.env
                .get("CMUX_WORKSPACE_ID")
                .cloned()
                .expect("a workspace id")
        })
        .collect();
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1], "each its own workspace");
    for id in &ids {
        assert_eq!(id.len(), 36);
        assert_eq!(id, &id.to_uppercase(), "the old app's uppercase UUID form");
    }
    // The workspace opened is the one the session names.
    let answer_keys: Vec<String> = ids.iter().map(|i| i.to_lowercase()).collect();
    let spawned = spawn(&mut s, &["three"], None);
    let last = s.h.agents.inner.lock().unwrap().specs.last().unwrap().env["CMUX_WORKSPACE_ID"]
        .to_lowercase();
    assert!(!answer_keys.contains(&last));
    assert!(spawned.contains("a3: workspace"), "{spawned}");
}

#[test]
fn without_workspaces_a_subagent_session_names_no_workspace() {
    let mut s = setup(None);
    spawn(&mut s, &["one"], None);
    let specs = s.h.agents.inner.lock().unwrap().specs.clone();
    assert!(!specs[0].env.contains_key("CMUX_WORKSPACE_ID"));
}
