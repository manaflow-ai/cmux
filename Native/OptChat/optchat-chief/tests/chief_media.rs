//! Chief sends pictures and videos (the user, 2026-10-20: "are you able to send me screenshots
//! and videos?"): a Markdown image of a local picture or video in a reply, `![shot](/path.png)`
//! or `![clip](/path.mp4)`, is uploaded as an attachment record of the conversation and goes
//! out as an `attachment` part after the text (the image syntax leaves the text), so Home shows
//! it inline on every device. A link to a local media file stays a link and is attached too. A
//! file that is missing or not a picture or video stays text and is not read.

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

#[test]
fn a_video_past_the_old_fifty_mb_cap_is_delivered_whole() {
    let dir = tempfile::tempdir().unwrap();
    let clip = dir.path().join("large.mp4");
    let file = std::fs::File::create(&clip).unwrap();
    let bytes = 64 * 1024 * 1024 + 17;
    file.set_len(bytes).unwrap();
    let (parts, h) = turn(format!("![clip](<{}>)", clip.display()));
    assert_eq!(
        parts.iter().filter_map(attachment).collect::<Vec<_>>(),
        vec![("large.mp4".into(), "video/mp4".into(), bytes, None, None)]
    );
    assert_eq!(h.owner.lock().unwrap().uploads[0].1.byte_count, bytes);
}

#[test]
fn a_pending_file_survives_restart_and_an_expired_preview_deadline() {
    use optchat_chief::state::{HostState, StateFile};
    use std::sync::{Arc, Mutex};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pending.mp4");
    std::fs::write(&path, b"a complete recording").unwrap();
    let entry = serde_json::from_value(json!({
        "conversation": CONV,
        "idempotency_key": "turn:pending-media",
        "op": {"kind": "message.send", "client_msg_id": "turn:pending-media", "parts": [text("Here it is.")]},
        "plain_text": "Here it is.",
        "previews_until": 1,
        "pending_media": [{"path": path, "mime_type": "video/mp4", "image_syntax": null}],
    })).unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            outbox: vec![entry],
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Default::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    assert!(
        !h.owner
            .lock()
            .unwrap()
            .ops
            .iter()
            .any(|(key, _)| key == "turn:pending-media"),
        "even an expired 60-second hold must not send before the upload completes"
    );
    let parts = sent_reply(&mut h);
    assert_eq!(parts[0], text("Here it is."));
    assert_eq!(parts.iter().filter_map(attachment).count(), 1);
    assert!(h.brain.state().outbox.is_empty());
}

#[test]
fn an_upload_worker_panic_sends_file_links_and_releases_the_queue() {
    use optchat_chief::brain::Input;
    use optchat_chief::state::{HostState, StateFile};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pending.pdf");
    std::fs::write(&path, b"an original report").unwrap();
    let entries = serde_json::from_value(json!([
        {
            "conversation": CONV,
            "idempotency_key": "turn:pending-media",
            "op": {"kind": "message.send", "client_msg_id": "turn:pending-media", "parts": [text("Here it is.")]},
            "pending_media": [{"path": path, "mime_type": "application/pdf", "image_syntax": null}],
        },
        {
            "conversation": CONV,
            "idempotency_key": "turn:following",
            "op": {"kind": "message.send", "client_msg_id": "turn:following", "parts": [text("The following message.")]},
        }
    ])).unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            outbox: entries,
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        panic_uploads: true,
        ..Default::default()
    }));
    let logs = Arc::new(Mutex::new(Vec::new()));
    let captured = logs.clone();
    let config = settings(dir.path());
    let mut h = Harness::configured(
        dir,
        default_script(),
        owner,
        config,
        Arc::new(move |line| captured.lock().unwrap().push(line.to_owned())),
    );
    h.connect();
    assert!(h.owner.lock().unwrap().sends().is_empty());
    assert_eq!(h.brain.state().outbox.len(), 2);
    // The worker completion is the gate: no timer or sleep releases the queue.
    let completed =
        h.rx.recv_timeout(Duration::from_secs(5))
            .expect("terminal worker event");
    assert!(
        matches!(&completed, Input::Previews { key, parts: Some(_) } if key == "turn:pending-media")
    );
    h.brain.step(completed);
    assert!(h.brain.state().outbox.is_empty());
    let delivered = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        delivered.contains(&format!(
            "Attachment upload failed: [pending.pdf]({})",
            url::Url::from_file_path(path).unwrap()
        )),
        "{delivered}"
    );
    assert!(delivered.contains("The following message."), "{delivered}");
    assert!(
        logs.lock()
            .unwrap()
            .iter()
            .any(|line| line.contains("worker panicked: injected attachment upload panic"))
    );
}

/// Before and after shots in a table (the user, 2026-11-03, msg 19904: "i want to see the images, like
/// how one might see in a github PR"): each picture in a table cell is still uploaded once, and its image
/// syntax stays in the cell, pointing at its attachment (`cmux-attachment:<hash>`), so Home draws the
/// thumbnail in the cell instead of an empty cell over a row of loose pictures.
#[test]
fn a_picture_in_a_table_cell_stays_in_the_cell_as_its_attachment() {
    let dir = tempfile::tempdir().unwrap();
    let before = dir.path().join("before.png");
    let after = dir.path().join("after.png");
    std::fs::write(&before, png(40, 30)).unwrap();
    std::fs::write(&after, png(30, 40)).unwrap();
    let reply = format!(
        "The fix:\n\n| | Before | After |\n|---|---|---|\n| Light | ![before, light]({}) | ![after, light]({}) |\n\nLanded.",
        before.display(),
        after.display()
    );
    let (parts, _) = turn(reply);
    let hashes: Vec<String> = parts
        .iter()
        .filter_map(|part| match part {
            Part::Attachment { hash, .. } => Some(hash.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(hashes.len(), 2, "both shots are attached: {parts:?}");
    assert_eq!(
        parts[0],
        text(&format!(
            "The fix:\n\n| | Before | After |\n|---|---|---|\n| Light | ![before, light](cmux-attachment:{}) | ![after, light](cmux-attachment:{}) |\n\nLanded.",
            hashes[0], hashes[1]
        )),
        "{parts:?}"
    );
}
