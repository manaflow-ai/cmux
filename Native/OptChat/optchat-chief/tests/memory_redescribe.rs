//! A screenshot whose description failed (the stuck-compactor bug of
//! 2026-11-09: "no description (... session name ... is taken)") is described
//! again on the owner's request (`optchat-chief memory redescribe`): the Chief
//! reads the image from the conversation owner once more, its description
//! note is rewritten through the memory's change book (backup, journal), and
//! every summary above the note is built again from the new words.

mod common;

use std::collections::VecDeque;
use std::io::Cursor;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use cmux_conversation::Part;
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::brain::images::Describe;
use optchat_chief::inspect::edit::Editor;
use serde_json::Value;

const HASH: &str = "8ba4b8f749d7aa00bb11cc22dd33ee44ff5566778899aabbccddeeff00112233";
const NAME: &str = "Screenshot 2026-11-09 at 3.13.46 PM.png";
const TAKEN: &str = "starting a compactor session: session/new: session name \"optchat-compact-h0me-18446744073709551613+1\" is taken";
const WORDS: &str = "A settings sheet with a red Ask pill next to the Done button.";

/// A describer that answers from a queue (the last answer repeats).
struct Answers(Mutex<VecDeque<Result<String, String>>>);

impl Describe for Answers {
    fn describe(&self, _: Vec<Value>) -> Result<String, String> {
        let mut q = self.0.lock().unwrap();
        if q.len() > 1 {
            q.pop_front().unwrap()
        } else {
            q.front().cloned().unwrap()
        }
    }
}

fn png() -> Vec<u8> {
    let image = image::GrayImage::from_pixel(64, 40, image::Luma([90]));
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma8(image)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

fn note_id(h: &Harness) -> u64 {
    h.log()
        .iter()
        .position(|(kind, text)| kind == "note" && text.contains("sha256:8ba4b8f749d7"))
        .expect("the image's description note is logged") as u64
}

/// Steps the brain's inputs until `done` holds.
fn step_until(h: &mut Harness, what: &str, done: impl Fn(&Harness) -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !done(h) {
        assert!(std::time::Instant::now() < deadline, "never: {what}");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
}

#[test]
fn a_failed_image_description_is_described_again_and_the_summaries_above_it_are_rebuilt() {
    let mut h = Harness::new(default_script());
    let editor = Editor::open(h.chat.clone(), h.dir.path());
    h.brain.set_memory_editor(Some(editor.clone()));
    let answers = Arc::new(Answers(Mutex::new(VecDeque::from([
        Err(TAKEN.to_owned()),
        Ok(WORDS.to_owned()),
    ]))));
    h.brain.set_describer(answers.clone());
    let bytes = png();
    h.owner.lock().unwrap().attachments.insert(
        (HASH.into(), "original".into()),
        base64::engine::general_purpose::STANDARD.encode(&bytes),
    );
    h.connect();

    // The person sends a screenshot; its description fails, as on 2026-11-09.
    h.say_parts(
        "user_local",
        vec![
            Part::Text {
                text: "alignment here is bad".into(),
                runs: None,
            },
            Part::Attachment {
                hash: HASH.into(),
                name: NAME.into(),
                mime_type: "image/png".into(),
                byte_count: bytes.len() as u64,
                width: Some(64),
                height: Some(40),
                duration_ms: None,
                poster: None,
                preview: None,
            },
        ],
    );
    h.settle_posts();
    step_until(&mut h, "the failed description is logged", |h| {
        h.log()
            .iter()
            .any(|(_, t)| t.contains(": no description ("))
    });
    // Later messages, so the note has summaries above it.
    for k in 0..6 {
        h.say("user_local", &format!("follow-up {k}"));
        h.settle_posts();
    }
    assert!(h.chat.settle(None, Some(Duration::from_secs(30))));
    let note = note_id(&h);
    let failed = h.chat.message(note).unwrap().1;
    assert!(failed.contains("no description"), "{failed}");

    // The owner asks for it to be described again.
    let (reply, answer) = channel();
    h.brain.step(Input::Redescribe {
        notes: vec![note],
        reply,
    });
    let answer = answer.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(answer["started"], serde_json::json!([note]), "{answer}");

    step_until(&mut h, "the note holds the new description", |h| {
        h.chat.message(note).unwrap().1.contains(" shows: ")
    });
    let now = h.chat.message(note).unwrap().1;
    assert_eq!(
        now,
        format!("image sha256:8ba4b8f749d7 \"{NAME}\" shows: {WORDS}")
    );

    // Journaled as one change, and every summary above the note is built again.
    assert!(editor.wait_rebuilt(Duration::from_secs(30)));
    let changes = editor.changes();
    let list = changes["changes"].as_array().unwrap();
    assert_eq!(list.len(), 1, "{changes}");
    assert_eq!(list[0]["op"], "redescribe");
    assert_eq!(list[0]["target"]["message"], note);
    assert_eq!(list[0]["old"], failed.as_str());
    assert!(
        changes["stale"].as_array().unwrap().is_empty(),
        "nothing left stale: {changes}"
    );
    let rebuilt = list[0]["rebuilt"].as_array().unwrap();
    assert!(!rebuilt.is_empty(), "the summaries above it: {changes}");
    // The note's own line holds the new words, not the error.
    let leaf = h
        .chat
        .node(optchat_core::NodeId::new(0, note))
        .expect("the note's line is built");
    assert!(leaf.contains("red Ask pill"), "{leaf}");
    assert!(!leaf.contains("is taken"), "{leaf}");
}

#[test]
fn a_line_that_is_not_an_image_description_is_refused() {
    let mut h = Harness::new(default_script());
    let editor = Editor::open(h.chat.clone(), h.dir.path());
    h.brain.set_memory_editor(Some(editor.clone()));
    h.brain
        .set_describer(Arc::new(Answers(Mutex::new(VecDeque::from([Ok(
            WORDS.to_owned()
        )])))));
    h.connect();
    h.say("user_local", "plain words");
    h.settle_posts();
    let (reply, answer) = channel();
    h.brain.step(Input::Redescribe {
        notes: vec![0, 99_999],
        reply,
    });
    let answer = answer.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(answer["started"], serde_json::json!([]), "{answer}");
    let refused = answer["refused"].as_array().unwrap();
    assert_eq!(refused.len(), 2, "{answer}");
    assert!(editor.changes()["changes"].as_array().unwrap().is_empty());
}
