//! A Claude Code tool result's images reach the client as ACP image blocks (`result_images.rs`):
//! live, and when a subagent's transcript is replayed.

use super::agent_transcript::replay;
use super::result_images::MAX_RESULT_IMAGE_BYTES;
use super::*;

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
