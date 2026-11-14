//! The Chief's own turns run in bypassPermissions unless the person or the
//! Chief chose another mode (cmux#37392: "there is no way for me to switch
//! this to dangerously-skip-permissions? ... it should be default on that
//! right?"). The brain sets the mode on each Claude turn session before its
//! prompt, so a change applies from the next turn; Settings caps what
//! `chief engine set --mode` may choose.
mod common;

use common::*;
use optchat_chief::engine::{self, EngineChoice};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

/// The policy of the first turn's session and the mode the brain set on it
/// before its prompt, for engine.json `saved` and the user's settings `user`.
fn first_turn(saved: Value, user: Option<Value>) -> (String, Option<String>) {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("engine.json");
    std::fs::write(&file, saved.to_string()).unwrap();
    let mut s = settings(dir.path());
    s.engine_file = Some(file);
    s.families
        .insert(s.harness.clone(), optchat_chief::acpmux::Family::Claude);
    let mut h = Harness::configured(
        dir,
        default_script(),
        Arc::new(Mutex::new(Owner {
            summary: Some(summary()),
            ..Owner::default()
        })),
        s,
        Arc::new(|_| {}),
    );
    h.brain.set_user_settings(user);
    h.connect();
    h.say("user_local", "what is x?");
    h.settle_posts();
    let inner = h.agents.inner.lock().unwrap();
    let turn = inner
        .specs
        .iter()
        .find(|s| s.name.starts_with(TURN_PREFIX))
        .expect("a turn session started");
    // Set before the turn's prompt (0 prompts sent before it).
    let mode = inner
        .modes
        .iter()
        .find(|(_, _, prompts)| *prompts == 0)
        .map(|(_, mode, _)| mode.clone());
    (turn.policy.clone(), mode)
}

fn first_turn_mode(saved: Value, user: Option<Value>) -> Option<String> {
    let (policy, mode) = first_turn(saved, user);
    assert_eq!(policy, "approve-all");
    mode
}

/// Manual is Claude Code's `default`, which asks before each change. Under
/// approve-all acpmux answers every ask with allow, so a Manual turn would
/// run as wide as bypass: it runs under `ask`, where each ask comes to the
/// Chief's `turn_permission` and is refused, with `default` set on it.
#[test]
fn a_manual_chief_turn_runs_under_ask_so_its_asks_are_refused_not_allowed() {
    for (saved, user) in [
        (json!({"permission_mode": "default"}), None),
        (
            json!({}),
            Some(json!({"chief": {"permissionMode": "default"}})),
        ),
        (
            json!({"permission_mode": "bypassPermissions"}),
            Some(json!({"chief.permissionMode": "manual"})),
        ),
    ] {
        assert_eq!(
            first_turn(saved.clone(), user.clone()),
            ("ask".to_owned(), Some("default".to_owned())),
            "engine.json {saved}, settings {user:?}"
        );
    }
}

/// A settings file that is there but does not parse caps the mode at
/// Manual: the person's choice is unknown, so it fails closed, never to the
/// bypass default. A missing file is no choice at all.
#[test]
fn an_unreadable_settings_file_caps_the_chief_at_manual() {
    use optchat_chief::agent_memory::settings::document_checked;
    let home = tempfile::tempdir().unwrap();
    assert_eq!(document_checked(home.path()), Ok(None));
    assert_eq!(
        engine::user_permission_mode_checked(Ok::<_, String>(None)),
        None
    );
    let dir = home.path().join(".config/cmux");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("cmux-next.json"),
        "{\"chief\": {\"permissionMode\": \"default\"",
    )
    .unwrap();
    let read = document_checked(home.path());
    assert!(read.is_err(), "{read:?}");
    let user = engine::user_permission_mode_checked(read.as_ref().map(Option::as_ref));
    assert_eq!(user.as_deref(), Some("default"));
    assert_eq!(
        engine::permission_mode(&EngineChoice::default(), user.as_deref()),
        ("default", "settings")
    );
    // `engine show` reads it the same way.
    assert!(
        engine::permission_mode_line_for(&EngineChoice::default(), user.as_deref())
            .starts_with("permission mode: default (Settings"),
    );
    std::fs::write(
        dir.join("cmux-next.json"),
        "{\"chief\": {\"permissionMode\": \"auto\"}}",
    )
    .unwrap();
    let read = document_checked(home.path()).unwrap();
    assert_eq!(
        engine::user_permission_mode(read.as_ref()).as_deref(),
        Some("auto")
    );
}

#[test]
fn a_claude_chief_turn_runs_in_bypass_by_default_and_in_the_chosen_mode_otherwise() {
    for (saved, user, expected) in [
        // Nothing chosen: bypassPermissions.
        (json!({}), None, "bypassPermissions"),
        // The Chief's own `engine set --mode`.
        (json!({"permission_mode": "auto"}), None, "auto"),
        // The person's Settings choice.
        (
            json!({}),
            Some(json!({"chief": {"permissionMode": "auto"}})),
            "auto",
        ),
        // Settings caps a wider engine.json choice, and allows a narrower one.
        (
            json!({"permission_mode": "bypassPermissions"}),
            Some(json!({"chief": {"permissionMode": "auto"}})),
            "auto",
        ),
        (
            json!({"permission_mode": "auto"}),
            Some(json!({"chief.permissionMode": "bypassPermissions"})),
            "auto",
        ),
    ] {
        assert_eq!(
            first_turn_mode(saved.clone(), user.clone()).as_deref(),
            Some(expected),
            "engine.json {saved}, settings {user:?}"
        );
    }
}

#[test]
fn only_an_approve_all_claude_turn_takes_the_chief_mode() {
    use optchat_chief::acpmux::{Family, chief_turn_mode};
    let bypass = Some("bypassPermissions");
    assert_eq!(
        chief_turn_mode(Family::Claude, "approve-all", bypass),
        bypass
    );
    // A turn that carries another person's text runs `ask`: never widened.
    assert_eq!(chief_turn_mode(Family::Claude, "ask", bypass), None);
    assert_eq!(chief_turn_mode(Family::Claude, "ask", Some("auto")), None);
    // A Manual owner turn runs `ask` with Manual set: no wider than `ask`.
    assert_eq!(
        chief_turn_mode(Family::Claude, "ask", Some("default")),
        Some("default")
    );
    // codex keeps its full-access mode under approve-all (E6), whatever the Claude mode.
    assert_eq!(
        chief_turn_mode(Family::Codex, "approve-all", Some("default")),
        Some(optchat_chief::acpmux::CODEX_FULL_ACCESS_MODE)
    );
    assert_eq!(chief_turn_mode(Family::Codex, "ask", bypass), None);
    assert_eq!(chief_turn_mode(Family::Codex, "ask", Some("default")), None);
    assert_eq!(chief_turn_mode(Family::Other, "approve-all", bypass), None);
}

fn set(choice: EngineChoice, words: &[&str]) -> Result<EngineChoice, String> {
    let mut all = vec!["engine", "set"];
    all.extend_from_slice(words);
    let flags =
        optchat_chief::cli::Flags::parse(&all.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>());
    engine::apply_flags(choice, &flags)
}

#[test]
fn engine_set_mode_validates_aliases_and_clears() {
    let c = set(EngineChoice::default(), &["--mode", "auto"]).unwrap();
    assert_eq!(c.permission_mode.as_deref(), Some("auto"));
    // `default` is Claude Code's Manual mode here, not a clear.
    let c = set(c, &["--mode", "default"]).unwrap();
    assert_eq!(c.permission_mode.as_deref(), Some("default"));
    let c = set(c, &["--mode", "yolo"]).unwrap();
    assert_eq!(c.permission_mode.as_deref(), Some("bypassPermissions"));
    let c = set(c, &["--mode", "unset"]).unwrap();
    assert_eq!(c.permission_mode, None);
    let err = set(EngineChoice::default(), &["--mode", "plan"]).unwrap_err();
    assert!(err.contains("bypassPermissions, auto, default"), "{err}");
    // A preset keeps the mode.
    let c = set(
        EngineChoice::default(),
        &["--mode", "auto", "--preset", "codex"],
    )
    .unwrap();
    assert_eq!(c.permission_mode.as_deref(), Some("auto"));
}

#[test]
fn engine_show_names_the_mode_and_what_chose_it() {
    let none = EngineChoice::default();
    let line = engine::permission_mode_line(&none, None);
    assert!(
        line.starts_with("permission mode: bypassPermissions (default"),
        "{line}"
    );
    let own = EngineChoice {
        permission_mode: Some("auto".into()),
        ..EngineChoice::default()
    };
    let line = engine::permission_mode_line(&own, None);
    assert!(line.contains("auto (chief engine set --mode"), "{line}");
    let user = json!({"chief": {"permissionMode": "default"}});
    let line = engine::permission_mode_line(&own, Some(&user));
    assert!(line.contains("default (Settings > Chief"), "{line}");
    // An unknown Settings value never reads wider than Manual.
    assert_eq!(
        engine::permission_mode(&none, Some("sometimes")),
        ("default", "settings")
    );
}
