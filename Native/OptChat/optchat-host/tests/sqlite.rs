//! The SQLite store's own guarantees: full-text search, the text export kept
//! in step, readers during writes, and crashes at each transaction boundary.

mod common;

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use common::*;
use optchat_host::db::{Exporter, Hit, ReadOnly};
use optchat_host::*;

#[test]
fn search_finds_messages_and_summaries() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    chat.append(Kind::User, "deploy the staging branch tonight")
        .unwrap();
    chat.append(Kind::Talk, "the kangaroo migration is done")
        .unwrap();
    chat.append(Kind::User, &long(2)).unwrap();
    assert!(chat.wait_idle(None, WAIT));
    let reader = ReadOnly::open(&dir.path().join(DB_FILE)).unwrap();
    let hits = reader.search("kangaroo", 10).unwrap();
    // The message, and its free node (a short message is its own summary).
    assert!(
        hits.iter()
            .any(|h| matches!(h, Hit::Message { id: 1, kind, snippet }
            if kind == "talk" && snippet.contains("[kangaroo]"))),
        "{hits:?}"
    );
    assert!(
        hits.iter()
            .any(|h| matches!(h, Hit::Node { node, .. } if *node == NodeId::new(0, 1))),
        "{hits:?}"
    );
    // A summary the model wrote is searchable too.
    let sums = reader.search("sum", 10).unwrap();
    assert!(
        sums.iter()
            .any(|h| matches!(h, Hit::Node { node, .. } if *node == NodeId::new(0, 2))),
        "{sums:?}"
    );
    assert!(!reader.search("staging tonight", 10).unwrap().is_empty());
    assert!(reader.search("nothing-like-this", 10).unwrap().is_empty());
}

fn tree_files(dir: &Path) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    for stream in ["main", "tree"] {
        let Ok(entries) = std::fs::read_dir(dir.join(stream)) else {
            continue;
        };
        let mut names: Vec<_> = entries.map(|e| e.unwrap().path()).collect();
        names.sort();
        for p in names {
            out.push((
                format!("{stream}/{}", p.file_name().unwrap().to_string_lossy()),
                std::fs::read(&p).unwrap(),
            ));
        }
    }
    out
}

#[test]
fn the_incremental_export_equals_a_full_export() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(&dir.path().join("chat"), 6_000, instant(300));
    let reader = ReadOnly::open(&dir.path().join("chat").join(DB_FILE)).unwrap();
    let out = dir.path().join("export");
    let mut exporter = Exporter::new(&out);
    for round in 0..4 {
        for n in 0..25 {
            let text = if n % 4 == 0 {
                long(n)
            } else {
                format!("round {round} message {n}")
            };
            chat.append(Kind::User, &text).unwrap();
        }
        assert!(chat.wait_idle(None, WAIT));
        exporter.sync(&reader).unwrap();
    }
    // A new exporter reads the watermark and appends only what is new.
    chat.append(Kind::Talk, "after a restart of the exporter")
        .unwrap();
    assert!(chat.wait_idle(None, WAIT));
    let mut again = Exporter::new(&out);
    let stats = again.sync(&reader).unwrap();
    assert_eq!(stats.messages, 1);
    let full = dir.path().join("full");
    reader.export_text(&full).unwrap();
    assert_eq!(tree_files(&out), tree_files(&full));
}

#[test]
fn a_reader_sees_whole_messages_while_the_writer_appends() {
    let dir = tempfile::tempdir().unwrap();
    let chat = Arc::new(open(dir.path(), 128_000, instant(200)));
    chat.append(Kind::User, "first").unwrap();
    let db = dir.path().join(DB_FILE);
    let done = Arc::new(AtomicBool::new(false));
    let stop = done.clone();
    let reader = std::thread::spawn(move || {
        let reader = ReadOnly::open(&db).unwrap();
        let (mut last, mut reads) = (0u64, 0u64);
        while !stop.load(Ordering::SeqCst) {
            let n = reader.counts().unwrap().messages;
            assert!(n >= last, "the count went back from {last} to {n}");
            // Every message below the count is whole.
            let (kind, text) = reader.message(n - 1).unwrap().expect("a counted message");
            assert_eq!(kind, "user");
            assert!(text == "first" || text.starts_with("message "), "{text}");
            last = n;
            reads += 1;
        }
        (last, reads)
    });
    for n in 0..300 {
        chat.append(Kind::User, &format!("message {n}")).unwrap();
    }
    done.store(true, Ordering::SeqCst);
    let (last, reads) = reader.join().unwrap();
    assert!(reads > 0 && last <= 301);
    assert_eq!(chat.status().messages, 301);
}

/// The child of the append crash tests: logs two batches with state.
#[test]
fn append_crash_child() {
    let Some(dir) = crash_dir() else { return };
    let chat = open(&dir, 128_000, instant(200));
    for batch in 0..2u64 {
        let texts = [format!("batch {batch} a"), format!("batch {batch} b")];
        let messages: Vec<NewMessage<'_>> = texts
            .iter()
            .map(|t| NewMessage::new(Kind::User, t))
            .collect();
        chat.append_with(&messages, |done| {
            vec![("host/logged".into(), Some(done.ids[1].to_string()))]
        })
        .unwrap();
    }
}

#[test]
fn a_crash_inside_an_append_leaves_the_batch_and_its_state_or_neither() {
    if crash_dir().is_some() {
        return;
    }
    // (point, batches that must be in the log afterwards)
    let cases = [
        ("append:after-messages#1", 0),
        ("append:before-commit#1", 0),
        ("append:after-messages#2", 1),
        ("append:before-commit#2", 1),
        ("none", 2),
    ];
    for (point, batches) in cases {
        let dir = tempfile::tempdir().unwrap();
        let aborted = crash_child("append_crash_child", point, dir.path());
        assert_eq!(aborted, point != "none", "{point}");
        let chat = open(dir.path(), 128_000, instant(200));
        let log = log_of(&chat);
        assert_eq!(log.len(), batches * 2, "{point}: {log:?}");
        let logged = chat.state("host/logged").unwrap();
        let want = (batches > 0).then(|| (batches * 2 - 1).to_string());
        assert_eq!(logged, want, "{point}: the state moves with its batch");
        // Ids stay dense after the rolled-back batch.
        assert_eq!(
            chat.append(Kind::User, "next").unwrap(),
            (batches * 2) as u64
        );
    }
}

/// The child of the checkpoint crash test: 120 settled messages, the view
/// they make written to `pre.txt`, then one more message, aborted right
/// after its transaction commits.
#[test]
fn checkpoint_crash_child() {
    let Some(dir) = crash_dir() else { return };
    let chat = open(&dir, 128_000, instant(200));
    for n in 0..120u64 {
        let text = if n % 3 == 0 { long(n) } else { format!("short {n}") };
        chat.append(Kind::User, &text).unwrap();
        assert!(chat.wait_idle(None, WAIT));
    }
    std::fs::write(dir.join("pre.txt"), chat.render_view().text).unwrap();
    chat.append(Kind::User, "the last word").unwrap();
}

/// Spec 3.2 (gist 3c190e0): the view is saved and loaded, never rebuilt. The
/// checkpoint commits in the message's own transaction, so a crash right
/// after a message leaves the view that includes it: the start resumes it
/// as saved, replays nothing, and the cached prefix of the view is the one
/// the last call before the crash sent.
#[test]
fn a_crash_after_a_message_commits_resumes_its_saved_view_without_a_replay() {
    if crash_dir().is_some() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    assert!(crash_child(
        "checkpoint_crash_child",
        "append:after-commit#121",
        dir.path()
    ));
    let saved = {
        let db = optchat_host::db::Db::open(&dir.path().join(DB_FILE)).unwrap();
        assert_eq!(db.len(), 121);
        let text = db
            .state(optchat_host::db::checkpoint::CHECKPOINT_KEY)
            .unwrap()
            .expect("a checkpoint");
        optchat_host::db::checkpoint::decode(&text).unwrap()
    };
    assert_eq!(saved.t, 121, "the checkpoint commits with the message");
    let pre = std::fs::read_to_string(dir.path().join("pre.txt")).unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    assert_eq!(chat.loaded(), optchat_host::db::checkpoint::Loaded::Resumed);
    let resumed = chat.render_view();
    assert_eq!(resumed.parts, saved.view, "resumed as saved, not replayed");
    // Every 4-line block of the view before the crash is still there, byte
    // for byte: the next call reads it from the cache.
    let cuts = optchat_core::block_cuts(&pre);
    let last = *cuts.last().unwrap();
    assert_eq!(optchat_core::block_cuts(&resumed.text)[..cuts.len()], cuts[..]);
    assert_eq!(resumed.text[..last], pre[..last]);
}

/// The child of the node crash test: one message that needs a model node.
#[test]
fn node_crash_child() {
    let Some(dir) = crash_dir() else { return };
    let chat = open(&dir, 128_000, instant(200));
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.settle(None, WAIT));
}

#[test]
fn a_crash_while_storing_a_node_leaves_it_to_build_again() {
    if crash_dir().is_some() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    assert!(crash_child(
        "node_crash_child",
        "node:before-commit",
        dir.path()
    ));
    let chat = open(dir.path(), 128_000, instant(200));
    assert_eq!(chat.status().messages, 1);
    assert_eq!(chat.status().built, 0, "the node never committed");
    // The compactor builds it again, exactly once.
    assert!(chat.settle(None, WAIT));
    assert_eq!(chat.status().built, 1);
    assert!(chat.render_view().text.contains("sum 0+1: "));
}
