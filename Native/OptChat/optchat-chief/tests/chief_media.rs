//! Chief sends pictures and videos (the user, 2026-10-20: "are you able to send me screenshots
//! and videos?"): a Markdown image of a local picture or video in a reply, `![shot](/path.png)`
//! or `![clip](/path.mp4)`, is uploaded as an attachment record of the conversation and goes
//! out as an `attachment` part after the text (the image syntax leaves the text), so Home shows
//! it inline on every device. A link to a local media file stays a link and is attached too. A
//! file that is missing or not a picture or video stays text and is not read; any size goes.

mod common;

use std::io::Cursor;

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

fn reply_script(text: String) -> Script {
    let text: &'static str = Box::leak(text.into_boxed_str());
    Box::new(move |_, _| {
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
    let dir = tempfile::tempdir().unwrap();
    let shot = dir.path().join("shot.png");
    let picture = png(40, 30);
    std::fs::write(&shot, &picture).unwrap();
    let clip = dir.path().join("demo clip.mp4");
    let clip_bytes: &[u8] = b"\0\0\0\x18ftypmp42 not a real video";
    std::fs::write(&clip, clip_bytes).unwrap();
    let clip_len = clip_bytes.len() as u64;
    let reply = format!(
        "Here is the screenshot:\n![shot]({})\nand the video ![clip](<{}>)",
        shot.display(),
        clip.display()
    );
    let (parts, h) = turn(reply);
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
    let dir = tempfile::tempdir().unwrap();
    let clip = dir.path().join("run.mov");
    std::fs::write(&clip, b"moov").unwrap();
    let reply = format!("The recording: [run.mov]({})", clip.display());
    let (parts, _) = turn(reply.clone());
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

/// Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE". The Chief
/// left a video over 50 MB as text.
#[test]
fn a_video_over_the_old_50_mb_limit_is_sent() {
    let dir = tempfile::tempdir().unwrap();
    let clip = dir.path().join("long.mp4");
    std::fs::File::create(&clip)
        .unwrap()
        .set_len(60_000_000)
        .unwrap();
    let (parts, h) = turn(format!("![long]({})", clip.display()));
    let files: Vec<_> = parts.iter().filter_map(attachment).collect();
    assert_eq!(
        files,
        vec![(
            "long.mp4".to_owned(),
            "video/mp4".to_owned(),
            60_000_000,
            None,
            None
        )],
        "{parts:?}"
    );
    assert_eq!(h.owner.lock().unwrap().uploads.len(), 1);
}

#[test]
fn a_missing_or_non_media_file_stays_text_and_is_never_read() {
    let dir = tempfile::tempdir().unwrap();
    let notes = dir.path().join("notes.txt");
    std::fs::write(&notes, b"secret").unwrap();
    let reply = format!(
        "![notes]({})\n![gone]({}/gone.png)",
        notes.display(),
        dir.path().display()
    );
    let (parts, h) = turn(reply.clone());
    assert_eq!(parts, vec![text(&reply)]);
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}
