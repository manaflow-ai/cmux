//! The images a Claude Code tool returns, as ACP content (manaflow-ai/cmux "why image
//! unavailbale"). A Read of a PNG, or an MCP tool that answers with a screenshot, gives a
//! `tool_result` whose content holds Anthropic image blocks
//! (`{"type":"image","source":{"type":"base64","media_type":...,"data":...}}`). Only its text
//! reached the client, so the pane fell back to the file's path and asked the Mac for it: for a
//! chat on another machine the path is not there, and the row said "Image unavailable".
//!
//! Each such block becomes an ACP image block in the call's `tool_call_update`, the shape
//! `outbound.rs` turns back into Claude's. The update is logged like every other, so a chat
//! reopened later still draws the image. The bytes are those Claude Code already holds (it scales
//! an image to what the API takes, at most 5 MiB of base64), and the images of one result are
//! kept up to [`MAX_RESULT_IMAGE_BYTES`] of base64: the update stays well inside one message
//! (`rpc::MAX_MESSAGE_BYTES`), and the client draws an image up to the same size. An image past
//! that budget, or one given by URL, is left out, and the pane falls back to its path as before.

use serde_json::{Value, json};

/// The most base64 the images of one tool result keep (the client's limit for one image).
pub(crate) const MAX_RESULT_IMAGE_BYTES: usize = 8 << 20;

/// The image blocks of a `tool_result`'s `content`, as ACP `content` blocks, in order, within
/// [`MAX_RESULT_IMAGE_BYTES`]. Empty for text content.
pub(crate) fn result_images(content: Option<&Value>) -> Vec<Value> {
    let mut left = MAX_RESULT_IMAGE_BYTES;
    content
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|block| {
            let source = block.get("source")?;
            if source.get("type").and_then(Value::as_str) != Some("base64") {
                return None;
            }
            let data = source.get("data").and_then(Value::as_str).filter(|d| !d.is_empty())?;
            left = left.checked_sub(data.len())?;
            let mime = source.get("media_type").and_then(Value::as_str).unwrap_or("image/png");
            Some(json!({"type": "content", "content": {"type": "image", "mimeType": mime, "data": data}}))
        })
        .collect()
}
