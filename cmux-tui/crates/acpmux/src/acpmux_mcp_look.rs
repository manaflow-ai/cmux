//! The `acpmux` MCP server's `look` tool (cmuxterm-hq RFD 0153): the agent sees the page it is
//! building, cheaply. It takes a frame of the chat's agent-driven page now (`hub/turn_frames.rs`,
//! kept in the turn's frames strip as `look` when the page moved, so the person sees it too) and
//! hands back one picture at most 512 px on its long edge (about 350-700 image tokens) plus one line.
//! The frames themselves reach the person at no agent tokens; this is the one place they cost any.

use super::{error_result, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "look";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "See the page you are building, now: a picture (at most 512 px) of this chat's agent-driven browser page (a dev server or file you opened beside the chat with the browser or open tools), plus how far it moved since the turn's first frame. The person already sees frames of it live in the chat as you edit, at no cost to you; call this only when you need to check the result yourself. To click or type in it, use the browser or computer-use tools on the same tab.",
        "inputSchema": {"type": "object", "properties": {}}
    })
}

/// The tool's answer from the daemon's `look` reply.
pub(super) fn answer(reply: &Value) -> Value {
    if let Some(error) = reply.get("error").and_then(Value::as_str) {
        return error_result(error.to_owned());
    }
    let Some(image) = reply.get("image") else {
        return error_result("the daemon sent no picture".to_owned());
    };
    let moved = reply.get("movedBits").and_then(Value::as_u64).unwrap_or(0);
    let tab = reply.get("tab").and_then(Value::as_str).unwrap_or("?");
    let kept = match reply.get("kept").and_then(Value::as_u64) {
        Some(i) => format!("kept as frame {i} in the chat's strip"),
        None => "same picture as the last frame".to_owned(),
    };
    let line = format!(
        "tab {tab}, {}x{} px; {moved}/64 bits moved since the turn's first frame; {kept}.",
        reply["width"], reply["height"]
    );
    json!({
        "content": [
            {"type": "image", "data": image["data"], "mimeType": image["mimeType"]},
            {"type": "text", "text": line}
        ],
        "isError": false
    })
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str) -> Value {
    if session.is_empty() {
        return error_result("look needs the chat's session (ACPMUX_SESSION_ID)".to_owned());
    }
    match daemon.request(method::MUX_TURN_FRAMES, json!({"sessionId": session, "look": true})).await
    {
        Ok(reply) => answer(&reply),
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_look_hands_back_one_picture_and_one_line() {
        let reply = json!({"image": {"mimeType": "image/png", "data": "AAAA"}, "width": 512, "height": 320, "tab": "t1", "movedBits": 12, "kept": 3});
        let out = answer(&reply);
        assert_eq!(out["content"][0]["type"], "image");
        assert_eq!(out["content"][0]["data"], "AAAA");
        let line = out["content"][1]["text"].as_str().unwrap();
        assert!(line.contains("12/64") && line.contains("frame 3"), "{line}");
    }

    #[test]
    fn no_page_is_said_plainly() {
        let out = answer(&json!({"error": "no agent-driven page"}));
        assert_eq!(out["isError"], true);
    }
}
