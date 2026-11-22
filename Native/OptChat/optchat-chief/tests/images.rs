//! Images in the Chief conversation (chief-done.md item 12): the turn's agent
//! sees each image as an ACP image block next to the message text, and the
//! OptChat log keeps a reference (its SHA-256) and a description, never the
//! bytes.

mod common;

use std::sync::Arc;

use cmux_conversation::{DerivedImage, Part};
use common::*;
use optchat_chief::brain::images::Describe;
use serde_json::{Value, json};

const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const PREVIEW: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

fn image(mime_type: &str, byte_count: u64, preview: bool) -> Part {
    Part::Attachment {
        hash: HASH.into(),
        name: "shot.png".into(),
        mime_type: mime_type.into(),
        byte_count,
        width: Some(1200),
        height: Some(800),
        duration_ms: None,
        poster: None,
        preview: preview.then(|| DerivedImage {
            hash: PREVIEW.into(),
            mime_type: "image/jpeg".into(),
            byte_count: 9,
        }),
    }
}

fn text(text: &str) -> Part {
    Part::Text {
        text: text.into(),
        runs: None,
    }
}

struct FixedDescriber(&'static str);

impl Describe for FixedDescriber {
    fn describe(&self, blocks: Vec<Value>) -> Result<String, String> {
        assert_eq!(blocks[0]["type"], "image", "the describer sees the image");
        Ok(self.0.to_owned())
    }
}

#[test]
fn the_turn_sees_the_image_and_the_log_keeps_a_reference_and_a_description() {
    let mut h = Harness::new(default_script());
    h.brain.set_describer(Arc::new(FixedDescriber(
        "A screenshot of a pricing table: Pro $50/mo, Max $200/mo.",
    )));
    h.owner
        .lock()
        .unwrap()
        .attachments
        .insert((HASH.into(), "original".into()), "QUJD".into());
    h.connect();
    h.say_parts(
        "user_local",
        vec![image("image/png", 3, true), text("what does this say?")],
    );
    h.settle();
    let prompt = h.agents.inner.lock().unwrap().prompts[0].clone();
    let n = prompt.len();
    assert_eq!(
        prompt[n - 2],
        json!({"type": "image", "mimeType": "image/png", "data": "QUJD"}),
        "the image goes just before the new messages"
    );
    let reference = "[image sha256:0123456789ab \"shot.png\" 1200x800 image/png]";
    assert_eq!(
        prompt[n - 1]["text"],
        format!("what does this say?\n{reference}")
    );
    // The description arrives from its own thread and is logged as a note.
    while !h.log().iter().any(|(kind, _)| kind == "note") {
        h.step();
    }
    let log = h.log();
    assert_eq!(
        log[0],
        (
            "user".to_owned(),
            format!("what does this say?\n{reference}")
        )
    );
    assert!(log.iter().any(|(kind, line)| kind == "note"
        && line == "image sha256:0123456789ab \"shot.png\" shows: A screenshot of a pricing table: Pro $50/mo, Max $200/mo."));
    assert!(
        log.iter().all(|(_, line)| !line.contains("QUJD")),
        "the log never holds the bytes"
    );
}

#[test]
fn an_image_without_text_wakes_the_chief() {
    let mut h = Harness::new(default_script());
    h.owner
        .lock()
        .unwrap()
        .attachments
        .insert((HASH.into(), "original".into()), "QUJD".into());
    h.connect();
    h.say_parts("user_local", vec![image("image/png", 3, false)]);
    h.settle();
    let agents = h.agents.inner.lock().unwrap();
    assert_eq!(agents.prompts.len(), 1, "an image alone starts a turn");
    let prompt = &agents.prompts[0];
    assert_eq!(prompt[prompt.len() - 2]["type"], "image");
}

#[test]
fn a_large_or_unreadable_type_sends_its_preview_and_none_sends_only_the_reference() {
    let mut h = Harness::new(default_script());
    h.owner
        .lock()
        .unwrap()
        .attachments
        .insert((HASH.into(), "preview".into()), "UFJF".into());
    h.connect();
    h.say_parts("user_local", vec![image("image/heic", 3, true)]);
    h.settle();
    {
        let agents = h.agents.inner.lock().unwrap();
        let prompt = &agents.prompts[0];
        assert_eq!(
            prompt[prompt.len() - 2],
            json!({"type": "image", "mimeType": "image/jpeg", "data": "UFJF"})
        );
    }
    assert_eq!(
        h.owner.lock().unwrap().attachment_reads,
        vec![(HASH.to_owned(), "preview".to_owned(), 9)],
        "a HEIC original is never read"
    );
    // Too large for the model and no preview: the turn gets the reference only.
    h.say_parts(
        "user_local",
        vec![image("image/png", 50_000_000, false), text("and this?")],
    );
    h.settle();
    let agents = h.agents.inner.lock().unwrap();
    let prompt = &agents.prompts[1];
    assert!(prompt.iter().all(|block| block["type"] != "image"));
    assert!(
        prompt[prompt.len() - 1]["text"]
            .as_str()
            .unwrap()
            .contains("not readable")
    );
}

/// Never answers: the host stops while the description is still running.
struct StuckDescriber;

impl Describe for StuckDescriber {
    fn describe(&self, _: Vec<Value>) -> Result<String, String> {
        loop {
            std::thread::park();
        }
    }
}

#[test]
fn a_description_the_host_stopped_before_is_written_after_the_restart() {
    let mut h = Harness::new(default_script());
    h.brain.set_describer(Arc::new(StuckDescriber));
    h.owner
        .lock()
        .unwrap()
        .attachments
        .insert((HASH.into(), "original".into()), "QUJD".into());
    h.connect();
    h.say_parts(
        "user_local",
        vec![image("image/png", 3, false), text("what does this say?")],
    );
    h.settle();
    assert!(
        h.log().iter().all(|(kind, _)| kind != "note"),
        "no description yet"
    );
    // The host stops (the stuck description dies with it) and starts again.
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
    h.brain
        .set_describer(Arc::new(FixedDescriber("A harbor notice.")));
    h.connect();
    while !h.log().iter().any(|(kind, _)| kind == "note") {
        h.step();
    }
    let notes: Vec<_> = h
        .log()
        .into_iter()
        .filter(|(kind, _)| kind == "note")
        .collect();
    assert_eq!(
        notes,
        vec![(
            "note".to_owned(),
            "image sha256:0123456789ab \"shot.png\" shows: A harbor notice.".to_owned()
        )],
        "written once, after the restart"
    );
    assert!(h.brain.state().undescribed.is_empty());
}
