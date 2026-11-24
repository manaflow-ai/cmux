//! What `acpmux icon` sends for the ICON a person or agent typed (`session_icon.rs`): an emoji,
//! a symbol or a mark as typed; a file's bytes, or a URL's (a site's favicon when the URL names
//! no image), as a data URL, since a daemon reads no path or URL a client names.

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;

use crate::session_icon::{MAX_IMAGE_BYTES, SessionIcon};

/// The `newIcon` value for `raw`.
pub(crate) async fn wire(raw: &str) -> Result<String> {
    let value = raw.trim();
    if crate::session_icon::clears(value) {
        return Ok("none".into());
    }
    if value.starts_with("http://") || value.starts_with("https://") {
        let (mime, bytes) = fetch(value).await?;
        return Ok(data_url(mime, &bytes));
    }
    let path = std::path::Path::new(value);
    if SessionIcon::mime_of(value).is_some() || value.contains('/') || path.is_file() {
        let bytes = std::fs::read(path).with_context(|| format!("icon file {value:?}"))?;
        let mime = SessionIcon::mime_of(value)
            .or_else(|| SessionIcon::sniff(&bytes))
            .ok_or_else(|| anyhow!("{value:?} is no SVG, PNG, ICO or JPEG image"))?;
        // Checked here too, so the refusal names the file.
        SessionIcon::image(mime, &bytes).map_err(|why| anyhow!("{value}: {why}"))?;
        return Ok(data_url(mime, &bytes));
    }
    Ok(value.to_owned())
}

fn data_url(mime: &str, bytes: &[u8]) -> String {
    format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// The image at `url`; a URL that names no image (`https://github.com`) is taken as a site and
/// its `/favicon.ico` read instead.
async fn fetch(url: &str) -> Result<(&'static str, Vec<u8>)> {
    let parsed = reqwest::Url::parse(url).with_context(|| format!("icon URL {url:?}"))?;
    let target = if SessionIcon::mime_of(parsed.path()).is_some() {
        parsed
    } else {
        parsed.join("/favicon.ico").context("the site's favicon URL")?
    };
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .user_agent("acpmux-icon")
        .build()?;
    let reply = client.get(target.clone()).send().await.with_context(|| format!("GET {target}"))?;
    if !reply.status().is_success() {
        bail!("GET {target}: {}", reply.status());
    }
    let header = reply
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap_or_default().trim().to_ascii_lowercase());
    if let Some(length) = reply.content_length().filter(|n| *n as usize > MAX_IMAGE_BYTES) {
        bail!(
            "{target} is {length} bytes; an icon is at most {MAX_IMAGE_BYTES}: give a smaller image URL"
        );
    }
    let bytes = reply.bytes().await?.to_vec();
    if bytes.len() > MAX_IMAGE_BYTES {
        bail!(
            "{target} is {} bytes; an icon is at most {MAX_IMAGE_BYTES}: give a smaller image URL",
            bytes.len()
        );
    }
    let mime = SessionIcon::sniff(&bytes)
        .or_else(|| SessionIcon::mime_of(target.path()))
        .or(match header.as_deref() {
            Some("image/svg+xml") => Some("image/svg+xml"),
            Some("image/png") => Some("image/png"),
            Some("image/x-icon" | "image/vnd.microsoft.icon") => Some("image/x-icon"),
            Some("image/jpeg") => Some("image/jpeg"),
            _ => None,
        })
        .ok_or_else(|| anyhow!("{target} gave no SVG, PNG, ICO or JPEG image"))?;
    Ok((mime, bytes))
}
