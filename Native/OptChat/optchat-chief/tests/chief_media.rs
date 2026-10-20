//! Chief sends pictures and videos (the user, 2026-10-20: "are you able to send me screenshots
//! and videos?"): a Markdown image of a local picture or video in a reply, `![shot](/path.png)`
//! or `![clip](/path.mp4)`, is uploaded as an attachment record of the conversation and goes
//! out as an `attachment` part after the text (the image syntax leaves the text), so Home shows
//! it inline on every device. A link to a local media file stays a link and is attached too. A
//! file that is missing, not a picture or video, or too big stays text and is not read.

mod common;

use std::io::Cursor;
use std::path::Path;
use std::sync::{Arc, Mutex};

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

fn reply_script(make_reply: impl FnOnce(&Path) -> String + Send + 'static) -> Script {
    let make_reply = Mutex::new(Some(make_reply));
    Box::new(move |_, blocks| {
        let prompt = blocks
            .iter()
            .filter_map(|block| block["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let outbox = prompt
            .split_once("<cmux-media-outbox>")
            .and_then(|(_, tail)| tail.split_once("</cmux-media-outbox>"))
            .map(|(path, _)| std::path::PathBuf::from(path.trim()))
            .unwrap_or_else(|| panic!("the turn names its media outbox; prompt: {prompt}"));
        let text = make_reply.lock().unwrap().take().unwrap()(&outbox);
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

fn turn(make_reply: impl FnOnce(&Path) -> String + Send + 'static) -> (Vec<Part>, Harness) {
    let mut h = Harness::new(reply_script(make_reply));
    h.connect();
    h.say("user_local", "send me the screenshot and the video");
    h.settle();
    (sent_reply(&mut h), h)
}

/// An attachment part's (name, type, bytes, width, height).
type Sent = (String, String, u64, Option<u32>, Option<u32>);

fn attachment(part: &Part) -> Option<Sent> {
    match part {
        Part::Attachment {
            name,
            mime_type,
            byte_count,
            width,
            height,
            ..
        } => Some((
            name.clone(),
            mime_type.clone(),
            *byte_count,
            *width,
            *height,
        )),
        _ => None,
    }
}

#[test]
fn a_markdown_image_of_a_local_picture_or_video_goes_as_an_attachment() {
    let picture = png(40, 30);
    let clip_bytes: &[u8] = b"\0\0\0\x18ftypmp42 not a real video";
    let clip_len = clip_bytes.len() as u64;
    let picture_file = picture.clone();
    let (parts, h) = turn(move |outbox| {
        let shot = outbox.join("shot.png");
        std::fs::write(&shot, picture_file).unwrap();
        let clip = outbox.join("demo clip.mp4");
        std::fs::write(&clip, clip_bytes).unwrap();
        format!(
            "Here is the screenshot:\n![shot]({})\nand the video ![clip](<{}>)",
            shot.display(),
            clip.display()
        )
    });
    assert_eq!(
        parts[0],
        text("Here is the screenshot:\nand the video"),
        "{parts:?}"
    );
    let files: Vec<_> = parts.iter().filter_map(attachment).collect();
    assert_eq!(
        files,
        vec![
            (
                "shot.png".to_owned(),
                "image/png".to_owned(),
                picture.len() as u64,
                Some(40),
                Some(30)
            ),
            (
                "demo clip.mp4".to_owned(),
                "video/mp4".to_owned(),
                clip_len,
                None,
                None
            ),
        ]
    );
    let uploads = h.owner.lock().unwrap().uploads.clone();
    assert_eq!(uploads.len(), 2, "each file is uploaded once: {uploads:?}");
    assert!(
        uploads
            .iter()
            .all(|(conversation, ..)| conversation == CONV)
    );
}

#[test]
fn a_link_to_a_local_video_stays_a_link_and_is_attached() {
    let reply = Arc::new(Mutex::new(String::new()));
    let seen = reply.clone();
    let (parts, _) = turn(move |outbox| {
        let clip = outbox.join("run.mov");
        std::fs::write(&clip, b"moov").unwrap();
        let text = format!("The recording: [run.mov]({})", clip.display());
        *seen.lock().unwrap() = text.clone();
        text
    });
    let reply = reply.lock().unwrap().clone();
    assert_eq!(parts[0], text(&reply));
    let files: Vec<_> = parts.iter().filter_map(attachment).collect();
    assert_eq!(
        files,
        vec![(
            "run.mov".to_owned(),
            "video/quicktime".to_owned(),
            4,
            None,
            None
        )]
    );
}

#[test]
fn a_missing_or_non_media_file_stays_text_and_is_never_read() {
    let reply = Arc::new(Mutex::new(String::new()));
    let seen = reply.clone();
    let (parts, h) = turn(move |outbox| {
        let notes = outbox.join("notes.txt");
        std::fs::write(&notes, b"secret").unwrap();
        let text = format!(
            "![notes]({})\n![gone]({})",
            notes.display(),
            outbox.join("gone.png").display()
        );
        *seen.lock().unwrap() = text.clone();
        text
    });
    let reply = reply.lock().unwrap().clone();
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
    let (parts, h) = turn(move |_| reply);

    assert_eq!(parts, vec![text(&expected)]);
    assert!(
        h.owner.lock().unwrap().uploads.is_empty(),
        "a model-authored path outside this turn's media outbox was uploaded"
    );
}

#[cfg(unix)]
#[test]
fn security_a_symlinked_media_outbox_cannot_escape_to_another_directory() {
    use std::os::unix::fs::symlink;

    let private = tempfile::tempdir().unwrap();
    let target = private.path().to_owned();
    let escaped = Arc::new(Mutex::new(None));
    let wrote = escaped.clone();
    let (parts, h) = turn(move |outbox| {
        let base = outbox.parent().unwrap();
        let name = outbox.file_name().unwrap();
        std::fs::remove_dir(outbox).unwrap();
        std::fs::remove_dir(base).unwrap();
        symlink(&target, base).unwrap();
        let redirected = target.join(name);
        std::fs::create_dir(&redirected).unwrap();
        let private = redirected.join("private.png");
        std::fs::write(&private, png(8, 8)).unwrap();
        *wrote.lock().unwrap() = Some(private);
        format!("![private]({})", outbox.join("private.png").display())
    });

    assert_eq!(parts.len(), 1, "the path stays plain text");
    assert!(
        h.owner.lock().unwrap().uploads.is_empty(),
        "the media reader followed a symlinked outbox parent"
    );
    assert!(
        escaped.lock().unwrap().as_ref().unwrap().exists(),
        "outbox cleanup followed a symlinked parent and deleted another directory's file"
    );
}
