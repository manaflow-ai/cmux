//! An icon image made to fit [`MAX_IMAGE_BYTES`] before `acpmux icon` sends it, so a site's
//! favicon is taken whatever its size (Leo, 2026-11-22: "SYMBOLS, SVGS, EMOJIS, FAVICONS,
//! WHATEVER ... AND WE'D BETTER NOT HAVE BULLSHIT LOCKS"). The cap stays: the icon rides every
//! summary of the chat (`session_icon.rs`). What changes is that a too-large image is made
//! smaller here instead of refused:
//!
//! - An ICO keeps the largest of its frames that fits alone (github.com's 6518-byte favicon has a
//!   16 px and a 32 px frame; the 32 px one is 5160 bytes): a PNG frame as that PNG, a bitmap
//!   frame as a one-frame ICO.
//! - A PNG, or an ICO whose frames are all too large (news.ycombinator.com's is one 256 px PNG of
//!   7505 bytes), is scaled down by area averaging in linear light
//!   ([`crate::model_copies::downscale`]) until it fits.
//! - An SVG or JPEG past the cap is still refused, with what to give instead: there is no SVG
//!   rasterizer or JPEG decoder in acpmux.
//!
//! [`icon_links`] reads a page's `<link rel="icon" href=...>` tags, for a site whose
//! `/favicon.ico` is missing or is not an image (www.rust-lang.org's answers with a page).

use anyhow::{Result, bail};

use crate::session_icon::MAX_IMAGE_BYTES;

/// The long edges a PNG is scaled to, largest first, until one fits.
const EDGES: [u32; 6] = [128, 96, 64, 48, 32, 16];

/// `bytes` (an image of type `mime`) as an image within [`MAX_IMAGE_BYTES`]: as it is when it
/// fits, else made smaller (module docs).
pub(crate) fn fit(mime: &'static str, bytes: Vec<u8>) -> Result<(&'static str, Vec<u8>)> {
    if bytes.len() <= MAX_IMAGE_BYTES {
        return Ok((mime, bytes));
    }
    let made = match mime {
        "image/x-icon" => ico_frame(&bytes),
        "image/png" => shrink_png(&bytes).map(|png| ("image/png", png)),
        _ => None,
    };
    match made {
        Some(made) => Ok(made),
        None => bail!(
            "the image is {} bytes and could not be made smaller; an icon is at most \
             {MAX_IMAGE_BYTES} (it rides every row of the chat): give a PNG, an ICO or a small SVG",
            bytes.len()
        ),
    }
}

/// One frame of an ICO file: its size in pixels (0 in the directory means 256) and its bytes.
struct Frame<'a> {
    edge: u32,
    bytes: &'a [u8],
    entry: &'a [u8],
}

impl Frame<'_> {
    fn is_png(&self) -> bool {
        self.bytes.starts_with(b"\x89PNG\r\n\x1a\n")
    }

    /// The frame as an image of its own: a PNG frame as that PNG, a bitmap one as a one-frame ICO.
    fn alone(&self) -> (&'static str, Vec<u8>) {
        if self.is_png() {
            return ("image/png", self.bytes.to_vec());
        }
        let mut ico = Vec::with_capacity(22 + self.bytes.len());
        ico.extend_from_slice(&[0, 0, 1, 0, 1, 0]);
        // The directory entry as it was but its offset: right after this one entry.
        ico.extend_from_slice(&self.entry[..12]);
        ico.extend_from_slice(&22u32.to_le_bytes());
        ico.extend_from_slice(self.bytes);
        ("image/x-icon", ico)
    }
}

/// The frames of an ICO file; empty for one that is not valid.
fn frames(ico: &[u8]) -> Vec<Frame<'_>> {
    let Some(count) = ico.get(4..6).map(|n| u16::from_le_bytes([n[0], n[1]])) else {
        return Vec::new();
    };
    (0..usize::from(count))
        .filter_map(|i| {
            let entry = ico.get(6 + 16 * i..22 + 16 * i)?;
            let edge = |b: u8| if b == 0 { 256 } else { u32::from(b) };
            let size = u32::from_le_bytes(entry.get(8..12)?.try_into().ok()?) as usize;
            let offset = u32::from_le_bytes(entry.get(12..16)?.try_into().ok()?) as usize;
            let bytes = ico.get(offset..offset.checked_add(size)?)?;
            let (w, h) = (edge(*entry.first()?), edge(*entry.get(1)?));
            Some(Frame { edge: w.max(h), bytes, entry })
        })
        .collect()
}

/// The largest frame of `ico` that fits alone; else its largest PNG frame scaled down.
fn ico_frame(ico: &[u8]) -> Option<(&'static str, Vec<u8>)> {
    let mut frames = frames(ico);
    frames.sort_by_key(|f| std::cmp::Reverse(f.edge));
    if let Some(alone) =
        frames.iter().map(Frame::alone).find(|(_, bytes)| bytes.len() <= MAX_IMAGE_BYTES)
    {
        return Some(alone);
    }
    let png = frames.iter().find(|f| f.is_png())?;
    shrink_png(png.bytes).map(|png| ("image/png", png))
}

/// `png` scaled down until it fits [`MAX_IMAGE_BYTES`]; None when even 16 px does not.
fn shrink_png(png: &[u8]) -> Option<Vec<u8>> {
    EDGES.iter().find_map(|&edge| {
        let (made, _, _) = crate::model_copies::downscale(std::io::Cursor::new(png), edge)?;
        (made.len() <= MAX_IMAGE_BYTES).then_some(made)
    })
}

/// The icon URLs a page's `<link rel="... icon ..." href="...">` tags name, as written (relative
/// ones too), an SVG first (it fits any size), then the rest in page order.
pub(crate) fn icon_links(html: &str) -> Vec<String> {
    let lower = html.to_ascii_lowercase();
    let mut links: Vec<String> = Vec::new();
    let mut at = 0;
    while let Some(start) = lower.get(at..).and_then(|rest| rest.find("<link")) {
        let start = at + start;
        let end = lower.get(start..).and_then(|rest| rest.find('>')).map_or(lower.len(), |e| start + e);
        let (tag, tag_lower) = (html.get(start..end).unwrap_or_default(), &lower[start..end]);
        at = end;
        let rel = attribute(tag_lower, tag_lower, "rel").unwrap_or_default();
        if !rel.split_ascii_whitespace().any(|word| word == "icon" || word == "apple-touch-icon") {
            continue;
        }
        if let Some(href) = attribute(tag, tag_lower, "href").filter(|h| !h.is_empty()) {
            links.push(href.replace("&amp;", "&"));
        }
    }
    let svg = |link: &String| !link.to_ascii_lowercase().split(['?', '#']).next().unwrap_or_default().ends_with(".svg");
    links.sort_by_key(svg);
    links.dedup();
    links
}

/// The value of attribute `name` in `tag` (`tag_lower` is `tag` lowercased, to find it): quoted
/// with `"` or `'`, or bare up to a space.
fn attribute<'a>(tag: &'a str, tag_lower: &str, name: &str) -> Option<&'a str> {
    let mut from = 0;
    loop {
        let found = from + tag_lower.get(from..)?.find(name)?;
        from = found + name.len();
        let before = tag_lower.as_bytes().get(found.checked_sub(1)?).copied()?;
        let rest = tag_lower.get(from..)?.trim_start();
        if !before.is_ascii_whitespace() || !rest.starts_with('=') {
            continue;
        }
        let value_at = tag_lower.len() - rest.len() + 1;
        let value = tag.get(value_at..)?.trim_start();
        let value_start = tag.len() - value.len();
        return match value.chars().next()? {
            quote @ ('"' | '\'') => {
                let inner = tag.get(value_start + 1..)?;
                inner.find(quote).and_then(|e| inner.get(..e))
            }
            _ => {
                let e = value.find(|c: char| c.is_ascii_whitespace() || c == '/').unwrap_or(value.len());
                value.get(..e)
            }
        };
    }
}

#[cfg(test)]
#[path = "icon_fit_tests.rs"]
mod tests;
