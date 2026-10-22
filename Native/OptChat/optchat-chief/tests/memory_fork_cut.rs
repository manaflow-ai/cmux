//! A fork of a memory (optchat-host db/fork.rs, the copy behind
//! `optchat-chief memory fork`): the log before the cut, the summaries
//! wholly before it, a provenance note, nothing of the source's host state,
//! read while the source's chat is open and writing; and the fork opens as
//! a memory of its own whose compactor rebuilds the lines the cut split.
//! Here, not in optchat-host's own tests: the fleet's optchat-chief step
//! runs these (no step runs optchat-host's workspace).

mod common;

use std::path::Path;
use std::sync::Arc;

use common::open_chat;
use optchat_core::Kind;
use optchat_host::db::ReadOnly;
use optchat_host::db::checkpoint::Loaded;
use optchat_host::db::fork::{FORK_KEY, ForkError, ForkPoint, Provenance, fork_memory};
use optchat_host::{NewMessage, OptChat};

const WAIT: Option<std::time::Duration> = Some(std::time::Duration::from_secs(30));

fn open(dir: &Path) -> Arc<OptChat> {
    open_chat(dir)
}

/// A message too long to be its own summary line, so it needs a model call.
fn long(n: u64) -> String {
    format!("message {n}: {}", "words ".repeat(120))
}

/// A source chat of `n` messages, every one logged with the key `c1#<i+1>`
/// (message i is conversation message i+1) and built into summaries.
fn source(dir: &Path, n: u64) -> Arc<OptChat> {
    let chat = open(dir);
    for i in 0..n {
        let text = if i == 12 {
            "see /src/home/optchat/attachments/ab12cd/shot.png".to_owned()
        } else if i % 3 == 0 {
            long(i)
        } else {
            format!("short {i}")
        };
        let key = format!("c1#{}", i + 1);
        chat.append_with(
            &[NewMessage {
                key: Some(key),
                ..NewMessage::new(Kind::User, &text)
            }],
            |_| Vec::new(),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, WAIT));
    chat.put_state(&[
        ("host/next_subagent".into(), Some("17".into())),
        ("host/conversation".into(), Some("\"c1\"".into())),
        ("fold/session-1".into(), Some("9".into())),
    ])
    .unwrap();
    chat
}

fn provenance(message: Option<&str>) -> Provenance {
    Provenance {
        chief: "agent_SOURCE".into(),
        name: "Scout".into(),
        message: message.map(str::to_owned),
        by: "person".into(),
    }
}

fn rows(db: &ReadOnly, sql: &str) -> Vec<(i64, i64)> {
    let mut statement = db.connection().prepare(sql).unwrap();
    let rows = statement
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    rows.collect::<Result<_, _>>().unwrap()
}

#[test]
fn a_fork_at_a_message_keeps_what_came_before_and_nothing_after() {
    let dir = tempfile::tempdir().unwrap();
    let src_dir = dir.path().join("src/home/optchat");
    let chat = source(&src_dir, 40);
    let before = chat.status().messages;
    let target = dir.path().join("new/home/optchat/memory.sqlite3");
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();

    // Conversation message #21 is log entry 20: the cut leaves out 21 on.
    let point = ForkPoint {
        key: Some("c1#21".into()),
        at: None,
    };
    let stats = fork_memory(
        &chat.db_path(),
        &target,
        &point,
        &provenance(Some("c1#21")),
        Some((
            "/src/home/optchat/attachments/",
            "/new/home/optchat/attachments/",
        )),
    )
    .unwrap();
    assert_eq!(stats.cut, 21);
    assert_eq!(stats.source_messages, 40);
    assert!(stats.nodes > 0);
    assert!(stats.nodes_left_out > 0, "{stats:?}");
    assert_eq!(stats.attachments, vec!["ab12cd".to_owned()]);
    assert_eq!(stats.note, 21);

    let db = ReadOnly::open(&target).unwrap();
    let ids = rows(&db, "SELECT MIN(id), MAX(id) FROM messages");
    assert_eq!(ids, vec![(0, 21)]);
    // Every copied summary lies wholly before the cut.
    for (level, idx) in rows(&db, "SELECT level, idx FROM nodes") {
        let end = (idx as u64 + 1) << level;
        assert!(end <= 21, "node ({level}, {idx}) covers past the cut");
    }
    // The texts are the source's, the attachment path names the new home's copy.
    let (_, text) = db.message(5).unwrap().unwrap();
    assert_eq!(text, "short 5");
    let (_, text) = db.message(12).unwrap().unwrap();
    assert_eq!(text, "see /new/home/optchat/attachments/ab12cd/shot.png");
    // The last entry is the provenance note.
    let (kind, note) = db.message(21).unwrap().unwrap();
    assert_eq!(kind, "note");
    assert!(note.starts_with("Forked from the Chief Scout (agent_SOURCE) at conversation message c1#21, by the person."), "{note}");
    assert!(
        note.contains("its 19 later messages are not in it"),
        "{note}"
    );
    // Only the subagent counter of the host state comes along.
    assert_eq!(
        db.state("host/next_subagent").unwrap().as_deref(),
        Some("17")
    );
    assert_eq!(db.state("host/conversation").unwrap(), None);
    assert_eq!(db.state("fold/session-1").unwrap(), None);
    assert_eq!(db.state("memory/checkpoint").unwrap(), None);
    let origin: serde_json::Value =
        serde_json::from_str(&db.state(FORK_KEY).unwrap().unwrap()).unwrap();
    assert_eq!(origin["chief"], "agent_SOURCE");
    assert_eq!(origin["cut"], 21);
    // The key of a copied message is still its key (the new Chief's own
    // conversation never reuses it), and none past the cut is there.
    let keys = rows(
        &db,
        "SELECT COUNT(*), COUNT(conv_msg) FROM messages WHERE conv_msg = 'c1#21' OR conv_msg = 'c1#22'",
    );
    assert_eq!(keys, vec![(1, 1)]);

    // The source is as it was, and still writes.
    assert_eq!(chat.status().messages, before);
    chat.append(Kind::User, "after the fork").unwrap();
    // Nothing of the build is left beside it (the read connection above may keep -shm/-wal).
    let left: Vec<String> = std::fs::read_dir(target.parent().unwrap())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name.contains("forking"))
        .collect();
    assert!(left.is_empty(), "the fork left {left:?}");

    // The fork opens as a memory of its own: folded from its log, and its
    // compactor builds the lines the cut split; no view line reaches past it.
    drop(db);
    let forked = open(target.parent().unwrap());
    assert_eq!(forked.loaded(), Loaded::Folded);
    assert!(forked.wait_idle(None, WAIT));
    let status = forked.status();
    assert_eq!(status.messages, 22);
    assert_eq!(status.unbuilt, 0);
    let view = forked.render_view();
    assert!(view.parts.iter().all(|p| p.end() <= 22), "{:?}", view.parts);
    assert!(!view.text.contains("after the fork"));
    forked.shutdown();
    chat.shutdown();
}

#[test]
fn a_fork_by_time_cuts_after_the_last_entry_at_or_before_it() {
    let dir = tempfile::tempdir().unwrap();
    let chat = source(&dir.path().join("src"), 12);
    // A message the source never logged under a key (its own reply): its
    // commit time, here the date of entry 7.
    let at = ReadOnly::open(&chat.db_path())
        .unwrap()
        .message_row(7)
        .unwrap()
        .unwrap()
        .date;
    let target = dir.path().join("t1/memory.sqlite3");
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
    let point = ForkPoint {
        key: Some("c9#1".into()),
        at: Some(at),
    };
    let stats = fork_memory(&chat.db_path(), &target, &point, &provenance(None), None).unwrap();
    // Entries written in the same millisecond as entry 7 are kept too.
    assert!(stats.cut >= 8, "{stats:?}");
    let db = ReadOnly::open(&target).unwrap();
    assert_eq!(db.message(stats.cut).unwrap().unwrap().0, "note");

    // Now: everything.
    let now = dir.path().join("t2/memory.sqlite3");
    std::fs::create_dir_all(now.parent().unwrap()).unwrap();
    let stats = fork_memory(
        &chat.db_path(),
        &now,
        &ForkPoint::now(),
        &provenance(None),
        None,
    )
    .unwrap();
    assert_eq!(stats.cut, 12);
    let note = ReadOnly::open(&now)
        .unwrap()
        .message(12)
        .unwrap()
        .unwrap()
        .1;
    assert!(note.contains("at the moment of the fork"), "{note}");
    chat.shutdown();
}

#[test]
fn a_fork_never_overwrites_a_memory_and_says_when_the_message_is_not_there() {
    let dir = tempfile::tempdir().unwrap();
    let chat = source(&dir.path().join("src"), 5);
    let target = dir.path().join("t/memory.sqlite3");
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
    std::fs::write(&target, "someone's memory").unwrap();
    let error = fork_memory(
        &chat.db_path(),
        &target,
        &ForkPoint::now(),
        &provenance(None),
        None,
    )
    .unwrap_err();
    assert!(matches!(error, ForkError::DestinationExists(_)), "{error}");
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "someone's memory"
    );

    let fresh = dir.path().join("u/memory.sqlite3");
    std::fs::create_dir_all(fresh.parent().unwrap()).unwrap();
    let point = ForkPoint {
        key: Some("c1#99".into()),
        at: None,
    };
    let error = fork_memory(&chat.db_path(), &fresh, &point, &provenance(None), None).unwrap_err();
    assert!(matches!(error, ForkError::NotInMemory(_)), "{error}");
    // A failed fork leaves nothing a brain would open.
    let left: Vec<_> = std::fs::read_dir(fresh.parent().unwrap())
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert!(left.is_empty(), "{left:?}");
    chat.shutdown();
}
