use super::*;
use std::process::Command as StdCommand;

const SOURCE: &str = include_str!("../../../../../../schemas/settings/source/sessions.json");

fn default_of(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    let rows = doc["lists"][0]["rows"].as_array().unwrap();
    rows.iter().find(|r| r["key"] == key).unwrap()["default"].clone()
}

#[test]
fn the_settings_are_off_and_auto_unless_set_as_the_schema_says() {
    assert_eq!(default_of(SETTING_ENABLED), json!(false));
    assert_eq!(default_of(SETTING_MACHINE), json!("auto"));
    assert_eq!(settings(&Value::Null), Settings { enabled: false, machine: "auto".into() });
    let nested = json!({"sessions": {"sleepHandoff": {"enabled": true, "machine": " gcp-1 "}}});
    assert_eq!(settings(&nested), Settings { enabled: true, machine: "gcp-1".into() });
    let flat = json!({SETTING_ENABLED: true, SETTING_MACHINE: ""});
    assert_eq!(settings(&flat), Settings { enabled: true, machine: "auto".into() });
    assert!(!settings(&json!({SETTING_ENABLED: "yes"})).enabled);
}

#[test]
fn only_a_running_turn_here_moves() {
    let turn = json!({"turnId": "t1"});
    let rows = [
        json!({"sessionId": "running", "status": "running", "turn": turn}),
        json!({"sessionId": "status-only", "status": "running"}),
        json!({"sessionId": "idle", "status": "idle"}),
        json!({"sessionId": "peer", "status": "running", "turn": turn, "peer": "gcp-1"}),
        json!({"sessionId": "child", "status": "running", "turn": turn, "parent": "running"}),
        json!({"sessionId": "watch", "status": "running", "turn": turn, "watching": "claude"}),
        json!({"sessionId": "moving", "status": "running", "turn": turn, "moving": true}),
        json!({"sessionId": "gone", "status": "closed", "turn": null, "movedTo": {"host": "gcp-1"}}),
    ];
    assert_eq!(running_chats(&rows), ["running", "status-only"]);
}

/// A git checkout on a branch with an `origin`, one commit in, in a fresh temp folder.
fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| {
        let ok = StdCommand::new("git").arg("-C").arg(dir.path()).args(args).output().unwrap();
        assert!(ok.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&ok.stderr));
    };
    run(&["init", "-q", "-b", "lane/x"]);
    run(&["remote", "add", "origin", "git@github.com:manaflow-ai/cmux.git"]);
    std::fs::write(dir.path().join("a.txt"), "a").unwrap();
    run(&["add", "."]);
    run(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a"]);
    dir
}

#[test]
fn a_chat_whose_uncommitted_work_all_carries_moves() {
    let repo = repo();
    assert_eq!(refusal_at(repo.path()).unwrap(), None, "a clean checkout moves");
    std::fs::write(repo.path().join("a.txt"), "edited").unwrap();
    std::fs::write(repo.path().join("new.rs"), "fn main() {}").unwrap();
    assert_eq!(
        refusal_at(repo.path()).unwrap(),
        None,
        "tracked edits and plain new files go with it"
    );
    let plain = tempfile::tempdir().unwrap();
    assert_eq!(refusal_at(plain.path()).unwrap(), None, "a folder in no checkout moves");
}

#[cfg(unix)]
#[test]
fn a_chat_whose_uncommitted_work_would_not_all_go_stays_and_says_why() {
    let repo = repo();
    std::fs::write(repo.path().join("a.txt"), "edited").unwrap();
    std::fs::write(repo.path().join(".env"), "TOKEN=x").unwrap();
    let why = refusal_at(repo.path()).unwrap().expect("a refusal");
    assert!(why.starts_with("its uncommitted .env (.env file: it may hold secrets"), "{why}");
    assert!(why.ends_with("can't go with it"), "{why}");
    std::fs::write(repo.path().join("id_ed25519"), "key").unwrap();
    let why = refusal_at(repo.path()).unwrap().expect("a refusal");
    assert!(why.contains(" and 1 more can't go with it"), "{why}");
}
