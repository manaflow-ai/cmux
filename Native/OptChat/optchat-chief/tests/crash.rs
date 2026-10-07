//! Crashes at each transaction boundary of the brain (README "State and
//! storage"): the process is aborted at an injected point (`OPTCHAT_FAULT`)
//! in a child, and a fresh brain on the same home must log every message
//! exactly once, lose none, and fold a turn's steps exactly once.

mod common;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::state::{HostState, StateFile};
use optchat_host::FAULT_ENV;
use serde_json::{Value, json};

const CRASH_DIR: &str = "OPTCHAT_CRASH_DIR";

/// Runs test `name` as a child working under `dir`, aborted at `point`.
/// Returns whether it aborted and the home it used.
fn crash_child(name: &str, point: &str, dir: &Path) -> (bool, PathBuf) {
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture", "--test-threads", "1"])
        .env(CRASH_DIR, dir)
        .env(FAULT_ENV, point)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let aborted = !out.status.success();
    assert!(
        !aborted || stderr.contains("fault injected"),
        "{point}: the child failed without the fault: {stderr}"
    );
    let home = std::fs::read_to_string(dir.join("home.txt")).unwrap();
    (aborted, PathBuf::from(home.trim()))
}

/// A crash-consistent copy of the child's home (the child is dead; the
/// database's -wal travels with it). Sockets are left behind.
fn copy_home(from: &Path, to: &Path) {
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let (src, dst) = (entry.path(), to.join(entry.file_name()));
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            std::fs::create_dir_all(&dst).unwrap();
            copy_home(&src, &dst);
        } else if kind.is_file() {
            std::fs::copy(&src, &dst).unwrap();
        }
    }
}

/// The child's side: a brain in a fresh home under `CRASH_DIR`, its path
/// written down for the parent, then `work` until the fault aborts it.
fn child(script: Script, work: impl FnOnce(&mut Harness)) -> bool {
    let Some(dir) = std::env::var_os(CRASH_DIR).map(PathBuf::from) else {
        return false;
    };
    let home = tempfile::TempDir::new_in(&dir).unwrap();
    std::fs::write(dir.join("home.txt"), home.path().display().to_string()).unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(home, script, owner);
    work(&mut h);
    // No fault fired: keep the home for the parent.
    std::mem::forget(h);
    true
}

/// The parent's side: a brain on a copy of the child's home, with the
/// conversation holding `messages`.
fn restart(home: &Path, script: Script, messages: &[&str]) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    copy_home(home, dir.path());
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        messages: messages
            .iter()
            .enumerate()
            .map(|(k, t)| message(k as u64 + 1, "user_local", t))
            .collect(),
        ..Owner::default()
    }));
    Harness::in_dir(dir, script, owner)
}

fn count(log: &[(String, String)], kind: &str, text: &str) -> usize {
    log.iter().filter(|(k, t)| k == kind && t == text).count()
}

#[test]
fn message_crash_child() {
    child(default_script(), |h| {
        h.connect();
        h.say("user_local", "hello");
        h.settle();
    });
}

#[test]
fn a_crash_while_a_message_is_logged_logs_it_once_and_answers_it() {
    if std::env::var_os(CRASH_DIR).is_some() {
        return;
    }
    // (point, the message is in the log at the crash)
    let cases = [
        ("append:after-messages#1", false),
        ("append:before-commit#1", false),
        ("brain:after-turn-log", true),
        ("none", true),
    ];
    for (point, logged) in cases {
        let work = tempfile::tempdir().unwrap();
        let (aborted, home) = crash_child("message_crash_child", point, work.path());
        assert_eq!(aborted, point != "none", "{point}");
        let mut h = restart(&home, default_script(), &["hello"]);
        h.connect();
        h.settle();
        let log = h.log();
        assert_eq!(count(&log, "user", "hello"), 1, "{point}: {log:?}");
        let sends = h.owner.lock().unwrap().sends();
        match (point, logged) {
            // The message never reached the log: caught up and answered.
            (_, false) => {
                assert_eq!(sends.len(), 1, "{point}: {sends:?}");
                assert_eq!(sends[0].1, "answer 0", "{point}");
            }
            // Logged with its pending turn, the turn never ran: told once.
            ("brain:after-turn-log", true) => {
                assert_eq!(sends.len(), 1, "{point}: {sends:?}");
                assert!(sends[0].1.starts_with("(interrupted"), "{sends:?}");
            }
            // The turn finished before the restart: nothing to do again.
            _ => assert!(sends.is_empty(), "{point}: {sends:?}"),
        }
        // The read cursor moved past it in every case (and past the
        // Chief's own replies, which the owner numbers after it).
        assert!(h.brain.state().logged_seq >= 1, "{point}");
    }
}

/// The turn's events as acpmux records them.
fn turn_events() -> Vec<Value> {
    default_script()(0, &[])
}

#[test]
fn fold_crash_child() {
    child(default_script(), |h| {
        h.connect();
        h.say("user_local", "hello");
        h.settle();
    });
}

#[test]
fn a_crash_while_a_turn_is_folded_logs_each_step_once() {
    if std::env::var_os(CRASH_DIR).is_some() {
        return;
    }
    // Appends: #1 logs "hello", #2 records the new session (before its
    // prompt starts), #3 folds its events; `turn:after-fold` is after #3,
    // before the brain saves the turn's position. (point, steps folded)
    for (point, folded) in [
        ("append:before-commit#2", false),
        ("append:before-commit#3", true),
        ("turn:after-fold", true),
    ] {
        let work = tempfile::tempdir().unwrap();
        let (aborted, home) = crash_child("fold_crash_child", point, work.path());
        assert!(aborted, "{point}");
        let mut h = restart(&home, default_script(), &["hello"]);
        // The stopped turn's session lives on in acpmux with its events.
        h.agents.set_events("s1", turn_events());
        h.connect();
        h.settle();
        let log = h.log();
        assert_eq!(count(&log, "user", "hello"), 1, "{point}: {log:?}");
        // A session that never got its prompt did nothing; one that did has
        // each step in the log exactly once.
        for (kind, text) in [
            ("talk", "Checking."),
            ("tool", "Bash {\"command\":\"ls\"}"),
            ("echo", "a.txt"),
            ("talk", "answer 0"),
        ] {
            assert_eq!(
                count(&log, kind, text),
                usize::from(folded),
                "{point}: {kind} {text}: {log:?}"
            );
        }
    }
}

#[test]
fn an_old_host_json_moves_into_the_database_once() {
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            logged_seq: 7,
            ..Default::default()
        })
        .unwrap();
    let chat = open_chat(&dir.path().join("chat"));
    let file = StateFile::new(&dir.path().join("host.json")).attach(chat.clone());
    assert_eq!(file.load().logged_seq, 7);
    assert!(!dir.path().join("host.json").exists());
    assert!(dir.path().join("host.json.imported").exists());
    let rows = chat.state_prefix("host/").unwrap();
    assert!(
        rows.iter().any(|(k, v)| k == "host/logged_seq" && v == "7"),
        "{rows:?}"
    );
    // Saving writes only what changed.
    let mut state = file.load();
    state.logged_seq = 8;
    assert_eq!(
        file.writes(&state),
        vec![("host/logged_seq".to_owned(), Some("8".to_owned()))]
    );
    file.save(&state).unwrap();
    drop(file);
    // A stray host.json written later is not imported again.
    std::fs::write(
        dir.path().join("host.json"),
        json!({"logged_seq": 1}).to_string(),
    )
    .unwrap();
    let file = StateFile::new(&dir.path().join("host.json")).attach(chat.clone());
    assert_eq!(file.load().logged_seq, 8);
}

/// The pending turn, its items and the cursor live in the database: a host
/// stopped mid-turn (no crash, just gone) finds them all at the next start.
/// (The images lane's `Item.images` and `HostState.undescribed` ride the
/// same rows: `host/turn` and `host/undescribed`.)
#[test]
fn a_pending_turn_and_its_items_survive_a_restart_in_the_database() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "first");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The turn is running: its pending record is in the database.
    let rows = h.chat.state_prefix("host/turn").unwrap();
    let turn: serde_json::Value = serde_json::from_str(&rows[0].1).unwrap();
    assert_eq!(turn["items"], json!([{"seq": 1, "child": null}]), "{turn}");
    assert!(turn["key"].as_str().unwrap().starts_with("turn:optchat:0:"));
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle();
    assert_eq!(count(&h.log(), "user", "first"), 1);
    assert!(h.brain.state().turn.is_none());
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.starts_with("(interrupted")),
        "{sends:?}"
    );
}
