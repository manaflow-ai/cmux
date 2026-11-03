//! A Claude Code tool result's images reach the client as ACP image blocks (`result_images.rs`):
//! live, and when a subagent's transcript is replayed.

use super::agent_transcript::replay;
use super::result_images::MAX_RESULT_IMAGE_BYTES;
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

/// An image by URL, or one past the budget, is left out: the pane falls back to its path.
#[tokio::test]
async fn images_past_the_budget_or_by_url_are_left_out() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&read_call("toolu_r3")).await;
    let big = "A".repeat(MAX_RESULT_IMAGE_BYTES - 4);
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
    let id = format!("result-image-{}", uuid::Uuid::now_v7());
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            crate::hub::file_uploads::remove_session(&self.0);
        }
    }
    let _cleanup = Cleanup(id.clone());
    let t = Translator::new(id, "default", "haiku", "default");
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.resize(12 << 20, 73);
    let expected = Sha256::digest(&bytes);
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    t.inbound(&read_call("large-result")).await;
    let out = updates(&t.inbound(&result("large-result", json!([image(&data)]))).await);
    let done = completion(&out);
    let link = done["content"].as_array().unwrap().iter()
        .filter_map(|block| block.pointer("/content/text").and_then(Value::as_str))
        .find(|text| text.contains("file:///"))
        .expect("a result image beyond the inline budget must retain its original file link");
    let start = link.find("file:///").unwrap();
    let uri = link[start..].split(')').next().unwrap();
    let path = url::Url::parse(uri).unwrap().to_file_path().unwrap();
    let mut file = std::fs::File::open(path).unwrap();
    let mut got = Sha256::new();
    let mut total = 0;
    let mut chunk = [0; 64 << 10];
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 { break }
        total += read;
        got.update(&chunk[..read]);
    }
    assert_eq!(total, bytes.len());
    assert_eq!(got.finalize(), expected);
    assert!(serde_json::to_vec(done).unwrap().len() < 2048, "the original goes by reference");
}
