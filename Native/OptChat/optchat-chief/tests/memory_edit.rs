//! The owner's changes to the memory through the native Memory Inspector's
//! API (inspect/edit.rs, plans/cmux-next/memory-inspector-native-DESIGN.md):
//! an edit or a delete rewrites one text in place, keeps every tree address,
//! writes a full backup and a journal record first, marks the summaries
//! above it stale and builds them again; an undo puts every text back
//! exactly; the Chief's own callers cannot change anything.

use std::sync::Arc;
use std::time::Duration;

use optchat_chief::inspect::Inspector;
use optchat_chief::inspect::edit::{Editor, JOURNAL, TOMBSTONE};
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, Kind, ModelError, NodeId, OptChat, Reply,
    SystemClock,
};
use serde_json::{Value, json};

const WAIT: Duration = Duration::from_secs(60);

/// A compactor whose line keeps the words that matter of its input (filler,
/// line names, kinds and plain message numbers dropped), so a summary holds
/// what is below it at every level: a changed message changes every line above it.
struct Echo;

impl CompactModel for Echo {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        let input = request
            .step
            .split_once("<input>\n")
            .map_or("", |(_, rest)| rest)
            .split("\n</input>")
            .next()
            .unwrap_or("");
        let kept: Vec<&str> = input
            .split_whitespace()
            .filter(|w| {
                !(matches!(*w, "filler" | "words" | "plain" | "message" | "user:")
                    || w.bytes().all(|b| b.is_ascii_digit())
                    || (w.starts_with('S') && w.contains('+')))
            })
            .collect();
        let line = format!("S{} {}", request.node.name(), kept.join(" "));
        Ok(Reply::text(
            optchat_core::cut_at_bytes(&line, 400).to_owned(),
        ))
    }
}

struct Fixture {
    dir: tempfile::TempDir,
    chat: Arc<OptChat>,
    insp: Inspector,
    editor: Arc<Editor>,
}

/// 64 messages too long to be their own lines (every line is a model call),
/// message 5 holding a secret; the compactor settled.
fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            dir.path().join("chat"),
            config,
            Arc::new(Echo),
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    for k in 0..64u64 {
        let head = if k == 5 {
            "SECRETXYZ my card is 4111".to_owned()
        } else {
            format!("plain message {k}")
        };
        chat.append(
            Kind::User,
            &format!("{head} {}", "filler words ".repeat(60)),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(WAIT)), "the compactor settles");
    let editor = Editor::open(chat.clone(), dir.path());
    let insp = Inspector::new(
        chat.clone(),
        dir.path().join("traces"),
        dir.path().join("settle.json"),
        String::new(),
    )
    .with_editor(editor.clone());
    Fixture {
        dir,
        chat,
        insp,
        editor,
    }
}

fn q(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

/// Every built line from message 5's own line up.
fn above_five(chat: &OptChat) -> Vec<(NodeId, String)> {
    (0..63)
        .map(|l| NodeId::new(l, 5 >> l))
        .map_while(|n| chat.node(n).map(|t| (n, t)))
        .collect()
}

fn search(chat: &OptChat, text: &str) -> usize {
    optchat_host::db::ReadOnly::open(&chat.db_path())
        .unwrap()
        .search(text, 50)
        .unwrap()
        .len()
}

#[test]
fn an_edit_rewrites_the_message_in_place_and_rebuilds_every_line_above_it() {
    let f = fixture();
    let before = above_five(&f.chat);
    assert!(
        before.len() >= 6,
        "message 5 has lines up to 0+64: {before:?}"
    );
    assert!(before.iter().all(|(_, t)| t.contains("SECRETXYZ")));
    assert!(search(&f.chat, "SECRETXYZ") > 0);

    let answer = f
        .insp
        .answer_write(
            "/api/memory/edit",
            &q(&[("target", "message:5"), ("text", "a harmless reminder")]),
        )
        .unwrap();
    assert_eq!(answer["op"], "edit");
    assert!(answer["old"].as_str().unwrap().starts_with("SECRETXYZ"));
    let stale: Vec<&str> = answer["stale"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(stale[..3], ["5+1", "4+2", "4+4"], "lowest line first");

    // Same id, kind and date; new text.
    let (kind, text) = f.chat.message(5).unwrap();
    assert_eq!(kind, Kind::User);
    assert_eq!(text, "a harmless reminder");

    assert!(
        f.editor.wait_rebuilt(WAIT),
        "the stale lines are built again"
    );
    assert!(f.editor.stale().is_empty());
    let after = above_five(&f.chat);
    assert_eq!(after.len(), before.len(), "no tree address moved");
    for (node, text) in &after {
        assert!(!text.contains("SECRETXYZ"), "{}: {text}", node.name());
    }
    assert!(after[0].1.contains("a harmless reminder"));
    assert_eq!(search(&f.chat, "SECRETXYZ"), 0, "the search index follows");
    assert!(!f.chat.render_view().text.contains("SECRETXYZ"));
    // The status and the view mark nothing stale any more.
    assert_eq!(
        f.insp.answer("/api/status", &[]).unwrap()["stale"],
        json!([])
    );

    // The memory keeps working after the change.
    f.chat.append(Kind::User, "one more").unwrap();
    assert!(f.chat.wait_idle(None, Some(WAIT)));
    assert_eq!(f.chat.status().messages, 65);
    let view = f.insp.answer("/api/view", &[]).unwrap();
    assert!(!view["lines"].as_array().unwrap().is_empty());
}

#[test]
fn a_backup_and_a_journal_record_are_written_before_the_first_change() {
    let f = fixture();
    f.insp
        .answer_write("/api/memory/delete", &q(&[("target", "message:5")]))
        .unwrap();
    let backups: Vec<_> = std::fs::read_dir(f.dir.path().join("backups"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .collect();
    assert_eq!(backups.len(), 1, "one full copy before the first change");
    let copy = optchat_host::db::ReadOnly::open(&backups[0]).unwrap();
    let (_, old) = copy.message(5).unwrap().unwrap();
    assert!(old.starts_with("SECRETXYZ"), "the copy holds the old text");
    use std::os::unix::fs::PermissionsExt;
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&backups[0]), 0o600);

    let journal = f.dir.path().join(JOURNAL);
    assert_eq!(mode(&journal), 0o600);
    // The change record is written before the answer; the rebuild worker may be
    // appending its own records after it while this reads.
    let text = std::fs::read_to_string(&journal).unwrap();
    let record: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(record["rec"], "change");
    assert_eq!(record["op"], "delete");
    assert!(record["old"].as_str().unwrap().starts_with("SECRETXYZ"));
    assert_eq!(record["new"], TOMBSTONE);

    // A second change writes no second copy.
    f.insp
        .answer_write(
            "/api/memory/edit",
            &q(&[("target", "message:6"), ("text", "changed six")]),
        )
        .unwrap();
    assert_eq!(
        std::fs::read_dir(f.dir.path().join("backups"))
            .unwrap()
            .count(),
        1
    );
}

#[test]
fn a_delete_leaves_a_tombstone_and_undo_puts_every_text_back_exactly() {
    let f = fixture();
    let message = f.chat.message(5).unwrap().1;
    let lines = above_five(&f.chat);
    let change = f
        .insp
        .answer_write("/api/memory/delete", &q(&[("target", "message:5")]))
        .unwrap();
    assert_eq!(f.chat.message(5).unwrap().1, TOMBSTONE);
    assert!(f.editor.wait_rebuilt(WAIT));
    assert!(above_five(&f.chat)[0].1.contains(TOMBSTONE));

    let id = change["id"].as_u64().unwrap().to_string();
    let undone = f
        .insp
        .answer_write("/api/memory/undo", &q(&[("change", &id)]))
        .unwrap();
    assert_eq!(undone["undone"], true);
    assert_eq!(f.chat.message(5).unwrap().1, message);
    assert_eq!(above_five(&f.chat), lines, "every line above it as it was");
    assert!(search(&f.chat, "SECRETXYZ") > 0);

    // Undone once only; the change list says so.
    let again = f
        .insp
        .answer_write("/api/memory/undo", &q(&[("change", &id)]))
        .unwrap_err();
    assert_eq!(again.0, 400);
    let changes = f.insp.answer("/api/memory/changes", &[]).unwrap();
    assert_eq!(changes["changes"][0]["undone"], true);
}

#[test]
fn an_older_change_is_undone_only_after_a_later_one_on_the_same_lines() {
    let f = fixture();
    let first = f
        .insp
        .answer_write(
            "/api/memory/edit",
            &q(&[("target", "message:5"), ("text", "first edit")]),
        )
        .unwrap();
    assert!(f.editor.wait_rebuilt(WAIT));
    let second = f
        .insp
        .answer_write(
            "/api/memory/edit",
            &q(&[("target", "message:5"), ("text", "second edit")]),
        )
        .unwrap();
    assert!(f.editor.wait_rebuilt(WAIT));
    let id = |c: &Value| c["id"].as_u64().unwrap().to_string();
    let refused = f
        .insp
        .answer_write("/api/memory/undo", &q(&[("change", &id(&first))]))
        .unwrap_err();
    assert_eq!(refused.0, 409, "{refused:?}");
    f.insp
        .answer_write("/api/memory/undo", &q(&[("change", &id(&second))]))
        .unwrap();
    assert_eq!(f.chat.message(5).unwrap().1, "first edit");
    f.insp
        .answer_write("/api/memory/undo", &q(&[("change", &id(&first))]))
        .unwrap();
    assert!(f.chat.message(5).unwrap().1.starts_with("SECRETXYZ"));
}

#[test]
fn a_summary_line_is_edited_in_place_and_the_lines_above_it_are_rebuilt() {
    let f = fixture();
    let node = NodeId::new(3, 0); // 0+8
    let parent = f.chat.node(node.parent()).unwrap();
    f.insp
        .answer_write(
            "/api/memory/edit",
            &q(&[
                ("target", "node:0+8"),
                ("text", "my own summary of the start"),
            ]),
        )
        .unwrap();
    assert_eq!(f.chat.node(node).unwrap(), "my own summary of the start");
    assert!(f.editor.wait_rebuilt(WAIT));
    let rebuilt = f.chat.node(node.parent()).unwrap();
    assert_ne!(rebuilt, parent);
    assert!(rebuilt.contains("my own summary"), "{rebuilt}");
    // The line below it is untouched.
    assert!(
        !f.chat
            .node(NodeId::new(2, 0))
            .unwrap()
            .contains("my own summary")
    );

    // A summary line holds at most NODE bytes; nothing else is a target.
    let long = "x".repeat(optchat_core::NODE + 1);
    let err = f
        .insp
        .answer_write(
            "/api/memory/edit",
            &q(&[("target", "node:0+8"), ("text", &long)]),
        )
        .unwrap_err();
    assert_eq!(err.0, 400);
    for target in ["node:3+8", "message:999", "nonsense"] {
        let err = f
            .insp
            .answer_write("/api/memory/delete", &q(&[("target", target)]))
            .unwrap_err();
        assert!(err.0 == 400 || err.0 == 404, "{target}: {err:?}");
    }
}

#[test]
fn the_chief_and_its_agents_cannot_change_the_memory() {
    let f = fixture();
    let edit = json!({"tool": "inspect", "method": "POST", "path": "/api/memory/edit",
                      "query": {"target": "message:5", "text": "rewritten by the agent"}});
    // A turn or subagent caller (`writes` off): refused.
    let got = optchat_chief::inspect::tool_answer(&f.insp, &edit, 1 << 20, false);
    assert_eq!(got["status"], 403, "{got}");
    // GET never writes; POST never reads.
    let get = json!({"tool": "inspect", "method": "GET", "path": "/api/memory/edit",
                     "query": {"target": "message:5", "text": "x"}});
    assert_eq!(
        optchat_chief::inspect::tool_answer(&f.insp, &get, 1 << 20, true)["status"],
        404
    );
    let post_read = json!({"tool": "inspect", "method": "POST", "path": "/api/status"});
    assert_eq!(
        optchat_chief::inspect::tool_answer(&f.insp, &post_read, 1 << 20, true)["status"],
        405
    );

    // Over the tools socket from this process (the host itself, as a native
    // engine's bash tool would be): refused too.
    let sock = f.dir.path().join("tools.sock");
    optchat_chief::tools::serve_all(
        &sock,
        optchat_chief::tools::Served {
            memory: f.chat.clone(),
            orchestrator: None,
            control: None,
            inspector: Some(Arc::new(
                Inspector::new(
                    f.chat.clone(),
                    f.dir.path().join("traces"),
                    f.dir.path().join("settle.json"),
                    String::new(),
                )
                .with_editor(f.editor.clone()),
            )),
            chief: None,
            turn: None,
            peers: None,
        },
    )
    .unwrap();
    use std::io::{BufRead, BufReader, Write};
    let mut s = std::os::unix::net::UnixStream::connect(&sock).unwrap();
    writeln!(s, "{edit}").unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    let got: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(got["status"], 403, "{got}");

    assert!(f.chat.message(5).unwrap().1.starts_with("SECRETXYZ"));
    assert!(!f.dir.path().join(JOURNAL).exists(), "nothing journaled");
    assert!(!f.dir.path().join("backups").exists());
}
