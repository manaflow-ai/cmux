//! `optchat-chief memory fork` (the copy the daemon runs for
//! `chief.profile.create` with `fork`): a new Chief home whose memory is the
//! source's up to a conversation message, with the attachments that memory
//! names copied into the new home (files, never links) and its paths
//! pointing there; the source keeps running and is not changed.

mod common;

use std::path::Path;
use std::process::Command;

use common::open_chat;
use optchat_core::Kind;
use optchat_host::NewMessage;
use optchat_host::db::ReadOnly;

const BIN: &str = env!("CARGO_BIN_EXE_optchat-chief");

fn fork(source: &Path, target: &Path, extra: &[&str]) -> std::process::Output {
    Command::new(BIN)
        .args(["memory", "fork", "--mux-home"])
        .arg(source)
        .arg("--to-home")
        .arg(target)
        .args([
            "--chief",
            "agent_SCOUT",
            "--name",
            "Scout",
            "--by",
            "person",
            "--json",
        ])
        .args(extra)
        .env_clear()
        .output()
        .unwrap()
}

#[test]
fn a_fork_copies_the_memory_up_to_the_message_and_the_files_it_names() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("scout");
    let optchat = source.join("optchat");
    std::fs::create_dir_all(optchat.join("attachments/ab12")).unwrap();
    std::fs::write(optchat.join("attachments/ab12/shot.png"), b"png bytes").unwrap();
    std::fs::create_dir_all(optchat.join("attachments/ff99")).unwrap();
    std::fs::write(optchat.join("attachments/ff99/later.txt"), b"later").unwrap();
    let shot = optchat.join("attachments/ab12/shot.png");
    let later = optchat.join("attachments/ff99/later.txt");
    let chat = open_chat(&optchat);
    let texts = [
        "hello".to_owned(),
        format!("look at this\n[image: {}]", shot.display()),
        "and this".to_owned(),
        format!("a later file {}", later.display()),
        "after".to_owned(),
    ];
    for (n, text) in texts.iter().enumerate() {
        chat.append_with(
            &[NewMessage {
                key: Some(format!("c1#{}", n + 1)),
                ..NewMessage::new(Kind::User, text)
            }],
            |_| Vec::new(),
        )
        .unwrap();
    }

    // Fork at conversation message #3 while the source's chat is open.
    let target = dir.path().join("fork");
    let out = fork(&source, &target, &["--key", "c1#3"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let answer: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(answer["cut"], 3, "{answer}");
    assert_eq!(answer["source_messages"], 5);
    assert_eq!(answer["attachments"], 1);

    // The file the kept memory names is the new home's own copy; the one
    // only a later message names is not copied.
    let copied = target.join("optchat/attachments/ab12/shot.png");
    let meta = std::fs::symlink_metadata(&copied).unwrap();
    assert!(meta.file_type().is_file(), "a copy, not a link");
    assert_eq!(std::fs::read(&copied).unwrap(), b"png bytes");
    assert!(!target.join("optchat/attachments/ff99").exists());
    let db = ReadOnly::open(&target.join("optchat/memory.sqlite3")).unwrap();
    let (_, text) = db.message(1).unwrap().unwrap();
    assert_eq!(text, format!("look at this\n[image: {}]", copied.display()));
    let (kind, note) = db.message(3).unwrap().unwrap();
    assert_eq!(kind, "note");
    assert!(note.contains("Forked from the Chief Scout"), "{note}");
    assert!(db.message(4).unwrap().is_none());

    // The source is unchanged and still the source's.
    assert_eq!(chat.status().messages, 5);
    assert_eq!(std::fs::read(&shot).unwrap(), b"png bytes");
    std::fs::write(&copied, b"changed in the fork").unwrap();
    assert_eq!(std::fs::read(&shot).unwrap(), b"png bytes");

    // A second fork into the same home is refused, and the first is kept.
    let again = fork(&source, &target, &[]);
    assert!(!again.status.success());
    assert!(String::from_utf8_lossy(&again.stderr).contains("already exists"));
    assert_eq!(
        ReadOnly::open(&target.join("optchat/memory.sqlite3"))
            .unwrap()
            .counts()
            .unwrap()
            .messages,
        4
    );
    chat.shutdown();
}

#[test]
fn a_fork_needs_its_provenance_and_a_home_of_its_own() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("scout");
    let chat = open_chat(&source.join("optchat"));
    chat.append(Kind::User, "hi").unwrap();
    let same = fork(&source, &source, &[]);
    assert!(!same.status.success());
    let bare = Command::new(BIN)
        .args(["memory", "fork", "--mux-home"])
        .arg(&source)
        .arg("--to-home")
        .arg(dir.path().join("x"))
        .env_clear()
        .output()
        .unwrap();
    assert!(!bare.status.success());
    assert!(String::from_utf8_lossy(&bare.stderr).contains("--chief"));
    chat.shutdown();
}
