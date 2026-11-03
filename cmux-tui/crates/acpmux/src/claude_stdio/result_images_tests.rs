//! A Claude Code tool result's images reach the client as ACP image blocks (`result_images.rs`):
//! live, and when a subagent's transcript is replayed.

use super::agent_transcript::replay;
use super::*;
use base64::Engine as _;
use sha2::{Digest, Sha256};
use std::io::Read as _;

fn updates(msgs: &[Message]) -> Vec<Value> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { method: m, params: Some(p) } if m == method::SESSION_UPDATE => {
                Some(p["update"].clone())
            }
            _ => None,
        })
        .collect()
}

fn read_call(id: &str) -> Value {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": id, "name": "Read",
        "input": {"file_path": "/tmp/ux-after-light.png"}}]}})
}

fn image(data: &str) -> Value {
    json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}})
}

/// Claude Code's line for a tool result whose content is `blocks`.
fn result(id: &str, blocks: Value) -> Value {
    json!({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": id, "content": blocks}]}})
}

fn acp_image(data: &str) -> Value {
    json!({"type": "content", "content": {"type": "image", "mimeType": "image/png", "data": data}})
}

fn completion(out: &[Value]) -> &Value {
    out.iter().find(|u| u["sessionUpdate"] == "tool_call_update").expect("a tool_call_update")
}

/// A Read of a PNG settles with the image Claude Code returned, not only its (empty) text, so a
/// chat on another machine draws it instead of "Image unavailable".
#[tokio::test]
async fn a_read_of_an_image_completes_with_the_image() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&read_call("toolu_r1")).await;
    let out = updates(&t.inbound(&result("toolu_r1", json!([image("iVBORw0KGgo=")]))).await);
    let done = completion(&out);
    assert_eq!(done["status"], "completed");
    assert_eq!(
        done["content"],
        json!([{"type": "content", "content": {"type": "text", "text": ""}}, acp_image("iVBORw0KGgo=")]),
    );
}

/// Text and images keep their places: the text first (as before), then each image in order.
#[tokio::test]
async fn a_result_with_text_and_images_keeps_both() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&read_call("toolu_r2")).await;
    let blocks = json!([{"type": "text", "text": "Two shots"}, image("QUFB"), image("QkJC")]);
    let out = updates(&t.inbound(&result("toolu_r2", blocks)).await);
    assert_eq!(
        completion(&out)["content"],
        json!([{"type": "content", "content": {"type": "text", "text": "Two shots"}},
               acp_image("QUFB"), acp_image("QkJC")]),
    );
}

/// Images beyond the inline budget have file references. A URL source is still left to the
/// original path fallback; translation never fetches a tool's arbitrary URL.
#[tokio::test]
async fn images_past_the_budget_keep_original_file_references() {
    let cleanup = ImageSession::new();
    let t = Translator::new(cleanup.0.clone(), "default", "haiku", "default");
    t.inbound(&read_call("toolu_r3")).await;
    let big = "A".repeat((8 << 20) - 4);
    let blocks = json!([
        {"type": "image", "source": {"type": "url", "url": "https://example.test/a.png"}},
        image(&big),
        image("QkJCQkJC"),
        image("QUFB"),
    ]);
    let out = updates(&t.inbound(&result("toolu_r3", blocks)).await);
    let content = completion(&out)["content"].as_array().unwrap().clone();
    let images: Vec<&Value> = content.iter().filter(|b| b["content"]["type"] == "image").collect();
    assert_eq!(images.len(), 2, "the big one and the one that still fits: {}", images.len());
    assert_eq!(images[0]["content"]["data"].as_str().map(str::len), Some(big.len()));
    assert_eq!(images[1], &acp_image("QUFB"));
    assert!(content[2]["content"]["text"].as_str().unwrap().contains("file:///"));
}

struct ImageSession(String);

impl ImageSession {
    fn new() -> Self {
        Self(format!("result-image-{}", uuid::Uuid::now_v7()))
    }
}

impl Drop for ImageSession {
    fn drop(&mut self) {
        crate::hub::file_uploads::remove_session(&self.0);
    }
}

/// A subagent's replayed transcript keeps the images its tool results returned.
#[tokio::test]
async fn a_replayed_subagent_transcript_keeps_result_images() {
    let lines = vec![read_call("toolu_r4"), result("toolu_r4", json!([image("iVBORw0KGgo=")]))];
    let pages = replay(&lines, 0, false).await;
    let done = completion(&pages[1]);
    assert_eq!(done["content"][1], acp_image("iVBORw0KGgo="));
}

/// The source is larger than both the former result-image budget and the media preview
/// limit. Its complete bytes must survive the translator, with a small update on the wire.
#[tokio::test]
async fn a_large_result_keeps_its_full_image_as_a_file_reference() {
    let cleanup = ImageSession::new();
    let t = Translator::new(cleanup.0.clone(), "default", "haiku", "default");
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.resize(12 << 20, 73);
    let expected = Sha256::digest(&bytes);
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    t.inbound(&read_call("large-result")).await;
    let out = updates(&t.inbound(&result("large-result", json!([image(&data)]))).await);
    let done = completion(&out);
    let link = done["content"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|block| block.pointer("/content/text").and_then(Value::as_str))
        .find(|text| text.contains("file:///"))
        .expect("a result image beyond the inline budget must retain its original file link");
    let start = link.find("file:///").unwrap();
    let uri = link[start..].split(')').next().unwrap();
    let path = reqwest::Url::parse(uri).unwrap().to_file_path().unwrap();
    let mut file = std::fs::File::open(&path).unwrap();
    let mut got = Sha256::new();
    let mut total = 0;
    let mut chunk = [0; 64 << 10];
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        total += read;
        got.update(&chunk[..read]);
    }
    assert_eq!(total, bytes.len());
    assert_eq!(got.finalize(), expected);
    assert!(serde_json::to_vec(done).unwrap().len() < 2048, "the original goes by reference");

    // The exact file reference remains readable by bounded ranges past the ordinary media
    // preview limit. Another chat's originals scope grants no exemption to that limit.
    use crate::hub::media_read::{MAX_RANGE, open_in, open_in_originals, read_range};
    let root = crate::hub::file_uploads::session_dir(&cleanup.0).unwrap();
    let originals = crate::hub::result_image_files::root(&cleanup.0).unwrap();
    let spelling = path.to_str().unwrap();
    assert!(open_in(std::slice::from_ref(&root), spelling, None, &mut |_| {}).is_err());
    assert!(
        open_in_originals(
            std::slice::from_ref(&root),
            spelling,
            None,
            Some(&root.join("another-chat")),
            &mut |_| {}
        )
        .is_err()
    );
    let opened = open_in_originals(
        std::slice::from_ref(&root),
        spelling,
        None,
        Some(&originals),
        &mut |_| {},
    )
    .unwrap();
    let mut digest = Sha256::new();
    let mut offset = 0;
    while offset < opened.identity.size {
        let chunk = read_range(&opened.file, &opened.identity, offset, MAX_RANGE as u64).unwrap();
        digest.update(&chunk);
        offset += chunk.len() as u64;
    }
    assert_eq!(digest.finalize(), expected);
    assert!(read_range(&opened.file, &opened.identity, 0, MAX_RANGE as u64 + 1).is_err());
}

/// Adoption uses the same owning-chat references and bounded writer. Replaying a subagent
/// also stores below that owner, not the translator's synthetic `read` session.
#[tokio::test]
async fn adopted_and_replayed_results_keep_every_original_image() {
    let owner = ImageSession::new();
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.resize(4 << 20, 81);
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let result = result("many-images", json!([image(&data), image(&data), image(&data)]));
    let adopted = crate::adopt_tools::claude_tool_results_for_session(
        &result["message"]["content"],
        None,
        Some(&owner.0),
    );
    let content = adopted[0].done["content"].as_array().unwrap();
    assert_eq!(content.len(), 4, "text and all three images survive");
    let uri = content[2]["content"]["text"].as_str().unwrap();
    assert!(uri.contains(&owner.0));
    assert_eq!(
        std::fs::read_dir(crate::hub::result_image_files::root(&owner.0).unwrap()).unwrap().count(),
        1,
        "equal originals share one durable path"
    );
    let lines = vec![read_call("many-images"), result];
    let pages = super::agent_transcript::replay_for_session(&lines, 0, false, &owner.0).await;
    assert_eq!(completion(&pages[1])["content"], adopted[0].done["content"]);
}
