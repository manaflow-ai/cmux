//! Ordinary reply Markdown never reads local files. Chief attachments go
//! through the explicit, permission-gated `send` tool (chief_turn_tools.rs).

mod common;

use std::io::Cursor;
use std::sync::Mutex;

use cmux_conversation::{Op, Part};
use common::*;
use serde_json::json;

fn text(t: &str) -> Part {
    Part::Text {
        text: t.into(),
        runs: None,
    }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let image = image::GrayImage::from_pixel(width, height, image::Luma([90]));
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma8(image)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

fn reply_script(reply: String) -> Script {
    let reply = Mutex::new(Some(reply));
    Box::new(move |_, _| {
        let text = reply.lock().unwrap().take().unwrap();
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// The parts of the turn's reply once the owner took it.
fn sent_reply(h: &mut Harness) -> Vec<Part> {
    loop {
        let sent = h
            .owner
            .lock()
            .unwrap()
            .ops
            .iter()
            .find_map(|(key, op)| match op {
                Op::MessageSend { parts, .. } if key.starts_with("turn:") => Some(parts.clone()),
                _ => None,
            });
        if let Some(parts) = sent {
            return parts;
        }
        h.step();
    }
}

fn turn(reply: String) -> (Vec<Part>, Harness) {
    let mut h = Harness::new(reply_script(reply));
    h.connect();
    h.say("user_local", "send me the screenshot and the video");
    h.settle();
    (sent_reply(&mut h), h)
}

#[test]
fn ordinary_markdown_local_paths_stay_text_and_are_never_read() {
    let dir = tempfile::tempdir().unwrap();
    let picture = dir.path().join("shot.png");
    let video = dir.path().join("run.mov");
    std::fs::write(&picture, png(40, 30)).unwrap();
    std::fs::write(&video, b"moov").unwrap();
    let reply = format!(
        "![shot]({})\nThe recording: [run.mov]({})",
        picture.display(),
        video.display()
    );
    let (parts, h) = turn(reply.clone());
    assert_eq!(parts, vec![text(&reply)]);
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}

#[test]
fn security_a_reply_cannot_attach_an_arbitrary_local_file() {
    let dir = tempfile::tempdir().unwrap();
    let private = dir.path().join("private.png");
    std::fs::write(&private, png(8, 8)).unwrap();
    let reply = format!("![private]({})", private.display());

    let expected = reply.clone();
    let (parts, h) = turn(reply);

    assert_eq!(parts, vec![text(&expected)]);
    assert!(
        h.owner.lock().unwrap().uploads.is_empty(),
        "ordinary model-authored Markdown uploaded a local file"
    );
}

#[cfg(unix)]
#[test]
fn security_a_symlinked_markdown_path_cannot_read_another_directory() {
    use std::os::unix::fs::symlink;

    let private = tempfile::tempdir().unwrap();
    let private_file = private.path().join("private.png");
    std::fs::write(&private_file, png(8, 8)).unwrap();
    let public = tempfile::tempdir().unwrap();
    let link = public.path().join("linked.png");
    symlink(&private_file, &link).unwrap();
    let reply = format!("![private]({})", link.display());
    let (parts, h) = turn(reply.clone());

    assert_eq!(parts, vec![text(&reply)], "the path stays plain text");
    assert!(
        h.owner.lock().unwrap().uploads.is_empty(),
        "ordinary Markdown followed a symlink to a private file"
    );
    assert!(
        private_file.exists(),
        "reply processing removed a private file"
    );
}
