//! A message the person deletes in the Chief chat (https://github.com/manaflow-ai/cmux/issues/36019):
//! the app retracts it at its owner, and the Chief's memory forgets it. The
//! next turn's input names the line as `deleted <id>` after `</chat>`, the
//! memory's copy of the message holds the tombstone (what the Memory
//! Inspector shows), the change book journals it like an inspector delete,
//! and all of it holds after the host restarts.

mod common;

use std::sync::Arc;

use cmux_conversation::Change;
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use optchat_chief::inspect::edit::{Editor, JOURNAL, TOMBSTONE};
use serde_json::Value;

const SECRET: &str = "my bank PIN is 4417, keep it handy";

fn joined(blocks: &[Value]) -> String {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect()
}

fn with_editor(h: &mut Harness) -> Arc<Editor> {
    let editor = Editor::open(h.chat.clone(), h.dir.path());
    h.brain.set_memory_editor(Some(editor.clone()));
    editor
}

#[test]
fn a_deleted_chat_message_leaves_the_chiefs_memory_and_stays_deleted_after_a_restart() {
    let mut h = Harness::new(default_script());
    let editor = with_editor(&mut h);
    h.connect();
    let first = h.say("user_local", SECRET);
    h.settle_posts();
    let target = h
        .log()
        .iter()
        .position(|(kind, text)| kind == "user" && text == SECRET)
        .expect("the message is logged") as u64;

    // The person deletes it: the owner retracts it and the brain hears the update.
    let mut deleted = first.clone();
    deleted.parts = Vec::new();
    deleted.retracted_at = Some("2026-11-04T12:00:00.000Z".into());
    h.owner.lock().unwrap().messages[0] = deleted.clone();
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated {
            message: deleted.clone(),
        },
    }));

    // The memory's copy is the tombstone, journaled as a delete.
    assert_eq!(h.chat.message(target).unwrap().1, TOMBSTONE);
    let changes = editor.changes();
    let list = changes["changes"].as_array().unwrap();
    assert_eq!(list.len(), 1, "one change: {changes}");
    assert_eq!(list[0]["op"], "delete");
    assert_eq!(list[0]["target"]["message"], target);
    assert!(
        h.dir.path().join(JOURNAL).exists(),
        "the change book journals it"
    );

    // The next turn names the line as deleted and holds the text nowhere.
    h.say("user_local", "what did I tell you before?");
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let next = joined(prompts.last().expect("a second turn"));
    let after = &next[next.find("</chat>").expect("the view") + "</chat>".len()..];
    assert!(
        after.lines().any(|l| l.ends_with(&format!("|deleted {target}"))),
        "the turn's input names line {target} as deleted after </chat>: {after}"
    );
    assert!(
        !next.contains("4417"),
        "the deleted text is in no part of the turn's input: {next}"
    );

    // A replayed update (a reconnect's catch-up) changes nothing again.
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: deleted },
    }));
    assert_eq!(
        editor.changes()["changes"].as_array().unwrap().len(),
        1,
        "a replay is not a second delete"
    );

    // After a restart the memory still holds only the tombstone.
    drop(editor);
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
    let editor = with_editor(&mut h);
    assert_eq!(h.chat.message(target).unwrap().1, TOMBSTONE);
    assert!(
        !h.log().iter().any(|(_, text)| text.contains("4417")),
        "no line of the memory holds the deleted text"
    );
    let changes = editor.changes();
    assert_eq!(
        changes["changes"][0]["op"], "delete",
        "the reopened change book lists the delete: {changes}"
    );
}
