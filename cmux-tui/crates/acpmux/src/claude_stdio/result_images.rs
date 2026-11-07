//! Claude Code tool images: small previews inline, complete larger originals as session files.
//! References use ordinary Markdown file links, so older clients can still open the original.
//! The inline budget bounds a preview/update, never the tool's result.

use serde_json::{Value, json};

const INLINE_BYTES: usize = 8 << 20;

fn sources(content: Option<&Value>) -> impl Iterator<Item = (&str, &str)> {
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
            let mime = source.get("media_type").and_then(Value::as_str).unwrap_or("image/png");
            Some((data, mime))
        })
}

fn inline(data: &str, mime: &str) -> Value {
    json!({"type": "content", "content": {"type": "image", "mimeType": mime, "data": data}})
}

fn reference(saved: anyhow::Result<std::path::PathBuf>) -> Value {
    let text = match saved.and_then(|path| {
        reqwest::Url::from_file_path(&path).map_err(|_| anyhow::anyhow!("invalid image file path"))
    }) {
        Ok(uri) => format!("\n\n[Original tool image]({uri})\n"),
        // A filesystem/invalid-base64 failure is visible rather than silently losing the image.
        // The source remains in Claude Code's transcript and can be replayed after repair.
        Err(error) => format!("\n\nTool image could not be saved: {error}.\n"),
    };
    json!({"type": "content", "content": {"type": "text", "text": text}})
}

/// Adoption runs off the runtime. Readers without an owning session (indexing, prompt scans)
/// keep the source blocks; the paths serving a chat supply its session before sending.
pub(crate) fn result_images(content: Option<&Value>, session: Option<&str>) -> Vec<Value> {
    let mut left = INLINE_BYTES;
    sources(content)
        .map(|(data, mime)| {
            if let Some(session) = session.filter(|_| data.len() > left) {
                reference(crate::hub::result_image_files::save(session, data, mime))
            } else {
                left = left.saturating_sub(data.len());
                inline(data, mime)
            }
        })
        .collect()
}

/// A live result uses bounded decode buffers and async writes, with no extra copy of the
/// provider's full base64 string. Claude Code already supplied that string in its JSON.
pub(super) async fn live_images(content: Option<&Value>, session: &str) -> Vec<Value> {
    let mut left = INLINE_BYTES;
    let mut out = Vec::new();
    for (data, mime) in sources(content) {
        if data.len() > left {
            out.push(reference(
                crate::hub::result_image_files::save_async(session, data, mime).await,
            ));
        } else {
            left -= data.len();
            out.push(inline(data, mime));
        }
    }
    out
}
