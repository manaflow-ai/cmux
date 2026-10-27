//! A page's preview metadata (MessagesLab LinkPreviews): the title from
//! `og:title`, `twitter:title` or `<title>` with a leading or trailing site
//! name dropped, the site as the page's host without `www.`, and the image
//! from `og:image`, `og:image:url` or `twitter:image` resolved against the
//! page URL. Plain scanning, no HTML parser: only the head is read.

use std::collections::HashMap;

use cmux_conversation::{MAX_LINK_SITE_CHARS, MAX_LINK_TITLE_CHARS};
use url::Url;

/// What a page says about itself.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PageMeta {
    pub title: Option<String>,
    pub site: Option<String>,
    /// Not fetched yet: the guard checks it like the page.
    pub image: Option<Url>,
}

/// The metadata of `html`, the page at `page` (its final URL).
pub fn page_meta(html: &str, page: &Url) -> PageMeta {
    let tags = meta_tags(html);
    let tag = |names: &[&str]| names.iter().find_map(|n| tags.get(*n).cloned());
    let title = tag(&["og:title", "twitter:title"])
        .or_else(|| title_tag(html))
        .map(|t| strip_site(&t, tags.get("og:site_name").map(String::as_str)))
        .and_then(|t| label(&t, MAX_LINK_TITLE_CHARS));
    let site = page.host_str().and_then(|host| {
        let host = host.strip_prefix("www.").unwrap_or(host);
        label(host, MAX_LINK_SITE_CHARS)
    });
    let image = tag(&["og:image", "og:image:url", "twitter:image"])
        .and_then(|src| page.join(src.trim()).ok())
        .filter(|u| matches!(u.scheme(), "http" | "https"));
    PageMeta { title, site, image }
}

/// Display text: whitespace runs collapsed, control characters gone, at
/// most `max` characters (cut with an ellipsis); None when empty.
fn label(text: &str, max: usize) -> Option<String> {
    let clean: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    if clean.is_empty() {
        return None;
    }
    if clean.chars().count() <= max {
        return Some(clean);
    }
    let mut cut: String = clean.chars().take(max - 1).collect();
    cut.push('…');
    Some(cut)
}

/// "GitHub - manaflow-ai/cmux: ..." shows as "manaflow-ai/cmux: ...": a
/// leading or trailing site name with a separator goes.
pub fn strip_site(title: &str, site: Option<&str>) -> String {
    let Some(site) = site.filter(|s| !s.is_empty()) else {
        return title.to_owned();
    };
    for sep in [" - ", " | ", " · ", " — ", ": "] {
        if let Some(rest) = title.strip_prefix(&format!("{site}{sep}")) {
            return rest.to_owned();
        }
        if let Some(rest) = title.strip_suffix(&format!("{sep}{site}")) {
            return rest.to_owned();
        }
    }
    title.to_owned()
}

/// `<meta property|name="..." content="...">` (any attribute order and
/// quoting), entities decoded; the first value of a name wins.
pub fn meta_tags(html: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    // ASCII lowercasing keeps every byte offset, so `lower` finds places in `html`.
    let lower = html.to_ascii_lowercase();
    let mut at = 0;
    while let Some(found) = lower.get(at..).and_then(|rest| rest.find("<meta")) {
        let start = at + found + 5;
        let Some((inside, _)) = html.get(start..).and_then(|rest| rest.split_once('>')) else {
            break;
        };
        let attrs = attributes(inside);
        at = start + inside.len() + 1;
        let name = attrs
            .get("property")
            .or_else(|| attrs.get("name"))
            .map(|n| n.to_ascii_lowercase());
        if let (Some(name), Some(content)) = (name, attrs.get("content")) {
            let content = decode(content).trim().to_owned();
            if !content.is_empty() {
                out.entry(name).or_insert(content);
            }
        }
    }
    out
}

/// The attributes of a tag's inside: `key=value`, `key="value"`,
/// `key='value'`, keys lowercased.
fn attributes(tag: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut chars = tag.chars().peekable();
    while chars.peek().is_some() {
        while chars.next_if(|c| c.is_whitespace() || *c == '/').is_some() {}
        let mut key = String::new();
        while let Some(c) = chars.next_if(|c| !c.is_whitespace() && *c != '=' && *c != '/') {
            key.push(c);
        }
        let key = key.to_ascii_lowercase();
        while chars.next_if(|c| c.is_whitespace()).is_some() {}
        if chars.next_if_eq(&'=').is_some() {
            while chars.next_if(|c| c.is_whitespace()).is_some() {}
            let mut value = String::new();
            match chars.next_if(|c| *c == '"' || *c == '\'') {
                Some(quote) => value.extend(chars.by_ref().take_while(|c| *c != quote)),
                None => {
                    while let Some(c) = chars.next_if(|c| !c.is_whitespace()) {
                        value.push(c);
                    }
                }
            }
            if !key.is_empty() {
                out.entry(key).or_insert(value);
            }
        } else if key.is_empty() {
            chars.next();
        }
    }
    out
}

/// The text of the first `<title>`, entities decoded; None when empty.
pub fn title_tag(html: &str) -> Option<String> {
    let open = html.to_ascii_lowercase().find("<title")?;
    let (_, inside) = html.get(open..)?.split_once('>')?;
    let end = inside.to_ascii_lowercase().find("</title")?;
    let title = decode(inside.get(..end)?).trim().to_owned();
    (!title.is_empty()).then_some(title)
}

/// The common HTML entities, decimal and hex references included.
fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((before, after_amp)) = rest.split_once('&') {
        out.push_str(before);
        let entity = after_amp.split_once(';').filter(|(e, _)| e.len() <= 10);
        let decoded = entity.and_then(|(e, _)| match e {
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "nbsp" => Some(' '),
            _ => {
                let code = if let Some(hex) = e.strip_prefix("#x").or_else(|| e.strip_prefix("#X"))
                {
                    u32::from_str_radix(hex, 16).ok()
                } else {
                    e.strip_prefix('#').and_then(|d| d.parse().ok())
                };
                code.and_then(char::from_u32)
            }
        });
        match (entity, decoded) {
            (Some((_, after_entity)), Some(c)) => {
                out.push(c);
                rest = after_entity;
            }
            _ => {
                out.push('&');
                rest = after_amp;
            }
        }
    }
    out.push_str(rest);
    out
}
