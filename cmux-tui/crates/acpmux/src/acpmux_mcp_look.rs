//! The `acpmux` MCP server's `look` tool: the agent looks at the chat's page as it works
//! (`_acpmux/look`, `hub/turn_frames.rs`). The daemon takes the picture of the same tab the
//! turn's frames show and answers a JPEG at most 512 px on its long edge, plus one line: the page's
//! address and how far it moved from the turn's first frame. A small image, not a browser session:
//! for an interaction the agent drives the same tab with `cmux browser` or the `cu_*` computer use
//! tools.

use super::{error_result, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "look";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "See the page this chat's workspace shows (the tab an agent opened, such as a dev server preview) as it is now: one small JPEG (at most 512 px) and a line with its URL and how much it changed since the turn's first frame. Costs only a small image. To interact with the page, drive the same tab with cmux browser or the cu_* computer use tools.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "capture": {"type": "boolean", "description": "Take a new picture (default true); false returns the turn's latest frame."}
            }
        }
    })
}

/// The one line beside the picture.
pub(super) fn line(answer: &Value) -> String {
    let url = answer.get("url").and_then(Value::as_str).unwrap_or("(no address)");
    let distance = answer.get("firstDistance").and_then(Value::as_u64).unwrap_or(0);
    let when = if answer.get("captured").and_then(Value::as_bool) == Some(true) {
        "now"
    } else {
        "latest frame"
    };
    let frame = answer
        .pointer("/frame/index")
        .and_then(Value::as_u64)
        .map(|i| format!(", frame {i}"))
        .unwrap_or_default();
    format!("{url} ({when}{frame}): dHash distance {distance}/64 from the turn's first frame")
}

/// The tool's result for the daemon's answer: the picture and its line, or why there is none.
pub(super) fn result(answer: Value) -> Value {
    let Some(image) = answer.get("image").filter(|i| i.is_object()) else {
        let reason = answer
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("no picture of this chat's page could be taken");
        return error_result(reason.to_owned());
    };
    let block = json!({
        "type": "image",
        "data": image.get("data").cloned().unwrap_or_default(),
        "mimeType": image.get("mimeType").cloned().unwrap_or_else(|| json!("image/jpeg")),
    });
    let text = line(&answer);
    // The structured copy without the picture's bytes, which the image block carries.
    let mut structured = answer;
    if let Some(fields) = structured.as_object_mut() {
        fields.remove("image");
    }
    json!({
        "content": [block, {"type": "text", "text": text}],
        "structuredContent": structured,
        "isError": false,
    })
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let capture = args.get("capture").and_then(Value::as_bool).unwrap_or(true);
    match daemon.request(method::MUX_LOOK, json!({"sessionId": session, "capture": capture})).await
    {
        Ok(answer) => result(answer),
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_comes_as_an_image_block_and_one_line() {
        let answer = json!({
            "captured": true, "url": "http://localhost:5173/", "firstDistance": 9,
            "frame": {"index": 3}, "image": {"mimeType": "image/jpeg", "data": "AAAA", "width": 512, "height": 320},
        });
        let out = result(answer);
        assert_eq!(out["content"][0]["type"], "image");
        assert_eq!(out["content"][0]["mimeType"], "image/jpeg");
        let text = out["content"][1]["text"].as_str().unwrap();
        assert!(text.contains("http://localhost:5173/") && text.contains("9/64"), "{text}");
        assert!(out["structuredContent"].get("image").is_none());
    }

    #[test]
    fn no_page_is_an_error_with_its_reason() {
        let out = result(json!({"captured": false, "reason": "no page"}));
        assert_eq!(out["isError"], true);
    }
}
