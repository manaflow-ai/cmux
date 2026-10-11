//! The remote backup of the text export (decision 2026-10-06): pushed to a
//! bare repository after each turn's commit, held on a possible secret,
//! retried with backoff when the remote is unreachable, never forced.

use std::path::{Path, PathBuf};
use std::process::Command;

use optchat_chief::backup::{Backup, BackupConfig, Outcome, find_secret};
use optchat_chief::persist::snapshot;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A chat directory whose export holds `texts` as messages 0.., committed.
fn turn(dir: &Path, texts: &[&str], key: &str) {
    std::fs::create_dir_all(dir.join("main")).unwrap();
    let mut lines = String::new();
    for (i, text) in texts.iter().enumerate() {
        let line = serde_json::json!({"i": i, "kind": "user", "text": text,
            "size": 6 + text.len(), "date": "2026-10-06T10:00:00.000+00:00"});
        lines.push_str(&format!("{line}\n"));
    }
    std::fs::write(dir.join("main/2026-10-06.jsonl"), lines).unwrap();
    snapshot(dir, key).unwrap();
}

struct Setup {
    _root: tempfile::TempDir,
    chat: PathBuf,
    bare: PathBuf,
    config: BackupConfig,
}

fn setup() -> Setup {
    let root = tempfile::tempdir().unwrap();
    let chat = root.path().join("chat");
    let bare = root.path().join("remote.git");
    let config = BackupConfig {
        remote: Some(true),
        tagged: false,
        url: Some(bare.display().to_string()),
        repo: "manaflow-ai/chief-memory-test".into(),
        status: root.path().join("backup.json"),
        traces: root.path().join("traces"),
        allow: root.path().join("backup-allow.txt"),
    };
    Setup {
        _root: root,
        chat,
        bare,
        config,
    }
}

fn init_bare(bare: &Path) {
    let out = Command::new("git")
        .args(["init", "-q", "--bare"])
        .arg(bare)
        .output()
        .unwrap();
    assert!(out.status.success());
}

fn status(s: &Setup) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(&s.config.status).unwrap()).unwrap()
}

#[test]
fn each_turn_is_pushed_to_the_backup_repository() {
    let s = setup();
    init_bare(&s.bare);
    let mut backup = Backup::new(s.config.clone());
    turn(&s.chat, &["hello"], "turn:optchat:0:1");
    let head = git(&s.chat, &["rev-parse", "HEAD"]);
    assert_eq!(backup.run(&s.chat), Outcome::Pushed { head: head.clone() });
    assert_eq!(git(&s.bare, &["rev-parse", "main"]), head);
    assert_eq!(backup.run(&s.chat), Outcome::UpToDate);
    turn(&s.chat, &["hello", "second"], "turn:optchat:1:2");
    let head = git(&s.chat, &["rev-parse", "HEAD"]);
    assert_eq!(backup.run(&s.chat), Outcome::Pushed { head: head.clone() });
    assert_eq!(git(&s.bare, &["rev-parse", "main"]), head);
    assert_eq!(status(&s)["state"], "ok");
}

#[test]
fn a_possible_secret_holds_the_backup_until_it_is_allowed() {
    let s = setup();
    init_bare(&s.bare);
    let mut backup = Backup::new(s.config.clone());
    turn(&s.chat, &["hello"], "turn:optchat:0:1");
    assert!(matches!(backup.run(&s.chat), Outcome::Pushed { .. }));
    let pushed = git(&s.bare, &["rev-parse", "main"]);
    let token = format!("my token is ghp_{}", "a1B2".repeat(9));
    turn(&s.chat, &["hello", &token], "turn:optchat:1:2");
    assert_eq!(
        backup.run(&s.chat),
        Outcome::Held {
            what: "message 1".into(),
            rule: "github-token".into()
        }
    );
    assert_eq!(
        git(&s.bare, &["rev-parse", "main"]),
        pushed,
        "nothing pushed"
    );
    assert_eq!(
        status(&s)["text"],
        "(backup held: possible secret in message 1)"
    );
    let trace = std::fs::read_dir(&s.config.traces)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let line: serde_json::Value = serde_json::from_str(
        std::fs::read_to_string(trace)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        (line["ev"].as_str(), line["what"].as_str()),
        (Some("backup_held"), Some("message 1"))
    );
    // Still held at the next turn; pushed once the user allows message 1.
    assert!(matches!(backup.run(&s.chat), Outcome::Held { .. }));
    std::fs::write(&s.config.allow, "# a test token\n1\n").unwrap();
    assert!(matches!(backup.run(&s.chat), Outcome::Pushed { .. }));
    assert_eq!(
        git(&s.bare, &["rev-parse", "main"]),
        git(&s.chat, &["rev-parse", "HEAD"])
    );
}

#[test]
fn an_unreachable_remote_is_retried_with_backoff() {
    let s = setup();
    let mut backup = Backup::new(s.config.clone());
    turn(&s.chat, &["hello"], "turn:optchat:0:1");
    let Outcome::Failed { retry: first, .. } = backup.run(&s.chat) else {
        panic!("the push must fail while the remote is missing")
    };
    assert!(backup.due().is_some());
    let Outcome::Failed { retry: second, .. } = backup.run(&s.chat) else {
        panic!("still missing")
    };
    assert_eq!(second, first * 2);
    assert_eq!(status(&s)["state"], "retrying");
    // The remote comes back: the next try pushes and the retry is cleared.
    init_bare(&s.bare);
    assert!(matches!(backup.run(&s.chat), Outcome::Pushed { .. }));
    assert!(backup.due().is_none());
}

#[test]
fn a_remote_with_other_history_is_never_forced() {
    let s = setup();
    init_bare(&s.bare);
    // Someone else's history in the backup repository.
    let other = s.chat.with_file_name("other");
    turn(&other, &["not this chief"], "other:1");
    git(
        &other,
        &[
            "push",
            "-q",
            s.bare.to_str().unwrap(),
            "HEAD:refs/heads/main",
        ],
    );
    let theirs = git(&s.bare, &["rev-parse", "main"]);
    let mut backup = Backup::new(s.config.clone());
    turn(&s.chat, &["hello"], "turn:optchat:0:1");
    assert!(matches!(backup.run(&s.chat), Outcome::Failed { .. }));
    assert_eq!(git(&s.bare, &["rev-parse", "main"]), theirs);
}

#[test]
fn backup_off_pushes_nothing() {
    let s = setup();
    init_bare(&s.bare);
    let mut backup = Backup::new(BackupConfig {
        remote: Some(false),
        ..s.config.clone()
    });
    turn(&s.chat, &["hello"], "turn:optchat:0:1");
    assert_eq!(backup.run(&s.chat), Outcome::Off);
    assert_eq!(status(&s)["state"], "off");
    // A tagged dev home stays off when nothing says otherwise.
    let mut tagged = Backup::new(BackupConfig {
        remote: None,
        tagged: true,
        url: None,
        ..s.config.clone()
    });
    assert_eq!(tagged.run(&s.chat), Outcome::Off);
}

#[test]
fn the_built_in_scan_knows_the_common_shapes_and_spares_prose() {
    for (text, rule) in [
        (format!("ghp_{}", "x".repeat(36)), "github-token"),
        (
            format!("key sk-ant-api03-{}", "Ab9_".repeat(10)),
            "anthropic-key",
        ),
        ("AKIAIOSFODNN7EXAMPLE".to_owned(), "aws-access-key"),
        (format!("xoxb-{}", "1234-".repeat(6)), "slack-token"),
        (
            "-----BEGIN OPENSSH PRIVATE KEY-----".to_owned(),
            "private-key",
        ),
        (format!("AIza{}", "B".repeat(35)), "google-api-key"),
    ] {
        assert_eq!(find_secret(&text), Some(rule), "{text}");
    }
    for prose in [
        "ask the team about the sk- prefix",
        "ghp_ is a GitHub token prefix",
        "AKIA means nothing alone",
        "the task-ant-colony test",
    ] {
        assert_eq!(find_secret(prose), None, "{prose}");
    }
}
