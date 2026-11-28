//! A codex turn under approve-all runs without codex's workspace-write
//! sandbox (codex-acp mode `agent-full-access`), as a Claude turn runs
//! without one (2026-10-08, E6: on the laptop Chief, codex turns failed
//! 9 tool calls with "Failed to connect to socket at <home>/state/app.sock
//! (Operation not permitted)", so under codex the Chief could not drive
//! cmux at all). The mode is set before the prompt. A turn under `ask` keeps
//! the sandbox, and a Claude turn is not touched.

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::Settings;
use optchat_chief::engine::{EngineChoice, save};

fn harness(policy: &str) -> (Harness, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("engine.json");
    let settings = Settings {
        policy: policy.into(),
        engine_file: Some(file.clone()),
        families: BTreeMap::from([
            ("claude-sr".to_owned(), Family::Claude),
            ("codex".to_owned(), Family::Codex),
        ]),
        codex_preset: Some("optchat-chief-codex-h0me".into()),
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::configured(
        dir,
        default_script(),
        owner,
        settings,
        Arc::new(|_: &str| {}),
    );
    h.agents.inner.lock().unwrap().catalog = Some(catalog());
    h.connect();
    (h, file)
}

fn codex(file: &std::path::Path) {
    save(
        file,
        &EngineChoice {
            harness: Some("codex".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
}

#[test]
fn a_codex_turn_under_approve_all_runs_without_the_sandbox() {
    let (mut h, file) = harness("approve-all");
    codex(&file);
    h.say("user_local", "list my workspaces");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].harness, "codex");
    assert_eq!(
        inner.modes,
        vec![("s1".to_owned(), "agent-full-access".to_owned(), 0)],
        "set on the turn session before its prompt"
    );
}

#[test]
fn a_codex_turn_under_ask_and_a_claude_turn_keep_their_modes() {
    let (mut h, file) = harness("ask");
    codex(&file);
    h.say("user_local", "hi");
    h.settle();
    assert!(h.agents.inner.lock().unwrap().modes.is_empty());
    let (mut h, _) = harness("approve-all");
    h.say("user_local", "hi");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].harness, "claude-sr");
    assert!(inner.modes.is_empty());
}
