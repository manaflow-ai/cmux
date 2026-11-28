//! What `acpmux icon` sends for the ICON a person or agent typed (`session_icon.rs`): an emoji,
//! a symbol or a mark as typed; a file's bytes, or a URL's (a site's favicon when the URL names
//! no image), made to fit (`icon_fit.rs`) and sent as a data URL, since a daemon reads no path or
//! URL a client names.

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;

use super::icon_fit::fit;
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
        let (mime, bytes) = fit(mime, bytes).map_err(|why| anyhow!("{value}: {why}"))?;
        // Checked here too, so the refusal names the file.
        SessionIcon::image(mime, &bytes).map_err(|why| anyhow!("{value}: {why}"))?;
        return Ok(data_url(mime, &bytes));
    }
    Ok(value.to_owned())
}

fn data_url(mime: &str, bytes: &[u8]) -> String {
    format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// The most bytes read from an icon URL before [`fit`](super::icon_fit::fit) makes the image
/// small enough to send.
const MAX_DOWNLOAD_BYTES: usize = 2 << 20;

/// The image at `url`, made to fit; a URL that names no image (`https://github.com`) is taken as
/// a site: its `/favicon.ico`, or when that is no image, the icons its page's `<link rel="icon">`
/// tags name.
async fn fetch(url: &str) -> Result<(&'static str, Vec<u8>)> {
    let parsed = reqwest::Url::parse(url).with_context(|| format!("icon URL {url:?}"))?;
    let client = crate::happy_dial::http_client()
        .timeout(std::time::Duration::from_secs(10))
        .user_agent("acpmux-icon")
        .build()?;
    if SessionIcon::mime_of(parsed.path()).is_some() {
        return fetch_image(&client, parsed).await;
    }
    let favicon = parsed.join("/favicon.ico").context("the site's favicon URL")?;
    let first = match fetch_image(&client, favicon).await {
        Ok(image) => return Ok(image),
        Err(why) => why,
    };
    // The page the person named, read for its icon links.
    cmux_egress::allow_named(parsed.as_str());
    let page = get(&client, &parsed).await.map(|(_, bytes)| bytes).unwrap_or_default();
    for link in super::icon_fit::icon_links(&String::from_utf8_lossy(&page)) {
        let Ok(target) = parsed.join(&link) else { continue };
        if !matches!(target.scheme(), "http" | "https") {
            continue;
        }
        if let Ok(image) = fetch_image(&client, target).await {
            return Ok(image);
        }
    }
    Err(first.context(format!("{parsed} names no icon in its page either")))
}

/// The image at `target`, made to fit [`MAX_IMAGE_BYTES`].
async fn fetch_image(
    client: &reqwest::Client,
    target: reqwest::Url,
) -> Result<(&'static str, Vec<u8>)> {
    // The person passed this icon URL on the command line, or its site's page named it.
    cmux_egress::allow_named(target.as_str());
    let (header, bytes) = get(client, &target).await?;
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
    let (mime, bytes) = fit(mime, bytes).map_err(|why| anyhow!("{target}: {why}"))?;
    SessionIcon::image(mime, &bytes).map_err(|why| anyhow!("{target}: {why}"))?;
    Ok((mime, bytes))
}

/// The body at `target` (at most [`MAX_DOWNLOAD_BYTES`]) and its content type.
async fn get(client: &reqwest::Client, target: &reqwest::Url) -> Result<(Option<String>, Vec<u8>)> {
    let mut reply =
        client.get(target.clone()).send().await.with_context(|| format!("GET {target}"))?;
    if !reply.status().is_success() {
        bail!("GET {target}: {}", reply.status());
    }
    let header = reply
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap_or_default().trim().to_ascii_lowercase());
    let too_big = || anyhow!("{target} is over {MAX_DOWNLOAD_BYTES} bytes: give a smaller image");
    if reply.content_length().is_some_and(|n| n > MAX_DOWNLOAD_BYTES as u64) {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = reply.chunk().await.with_context(|| format!("GET {target}"))? {
        bytes.extend_from_slice(&chunk);
        if bytes.len() > MAX_DOWNLOAD_BYTES {
            return Err(too_big());
        }
    }
    Ok((header, bytes))
}
