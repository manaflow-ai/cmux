//! A turn that says nothing but closes open work posts a done marker
//! (brain/turns.rs). The marker is no reply in a thread: the daemon counts
//! every message of a thread as a reply, so a threaded marker gave the
//! person's message a reply that opened to nothing (cmux#23810).

mod common;

use cmux_conversation::{Op, Part, PartRef, WorkStatus};
use common::*;
use optchat_chief::state::{HostState, StateFile};
use serde_json::json;

/// A turn that ends without a word.
fn silent() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// The done markers the owner took: (answers, thread_root, reply_to).
fn markers(h: &Harness) -> Vec<(Vec<String>, Option<String>, Option<PartRef>)> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::MessageSend {
                parts,
                answers,
                thread_root,
                reply_to,
                ..
            } if matches!(
                parts.as_slice(),
                [Part::Work {
                    status: WorkStatus::Done,
                    preview: None,
                    ..
                }]
            ) =>
            {
                Some((answers.clone(), thread_root.clone(), reply_to.clone()))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn a_done_marker_closes_its_message_outside_that_messages_thread() {
    // The work the turn answers is open (a subagent was at work for it).
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            open_answers: vec!["msg_1".into()],
            ..Default::default()
        })
        .unwrap();
    let owner = std::sync::Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, silent(), owner);
    // A reply would go into msg_1's thread.
    h.brain
        .set_setting("replies.thread", "always")
        .expect("replies.thread is a setting");
    h.connect();
    h.say("user_local", "how did it go?");
    h.settle_posts();
    let markers = markers(&h);
    assert_eq!(markers.len(), 1, "one done marker: {markers:?}");
    let (answers, thread_root, reply_to) = &markers[0];
    assert_eq!(answers, &vec!["msg_1".to_owned()], "it closes msg_1");
    assert_eq!(thread_root, &None, "no reply in msg_1's thread");
    assert_eq!(reply_to, &None, "it quotes nothing");
}
