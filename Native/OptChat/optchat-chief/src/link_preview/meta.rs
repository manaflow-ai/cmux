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
    let lower = html.to_ascii_lowercase();
    let mut at = 0;
    while let Some(found) = lower[at..].find("<meta") {
        let start = at + found + 5;
        let Some(len) = lower[start..].find('>') else {
            break;
        };
        let attrs = attributes(&html[start..start + len]);
        at = start + len + 1;
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
    let chars: Vec<char> = tag.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        while i < chars.len() && (chars[i].is_whitespace() || chars[i] == '/') {
            i += 1;
        }
        let key_start = i;
        while i < chars.len() && !chars[i].is_whitespace() && chars[i] != '=' && chars[i] != '/' {
            i += 1;
        }
        let key: String = chars[key_start..i]
            .iter()
            .collect::<String>()
            .to_ascii_lowercase();
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        if i < chars.len() && chars[i] == '=' {
            i += 1;
            while i < chars.len() && chars[i].is_whitespace() {
                i += 1;
            }
            let value: String = if i < chars.len() && (chars[i] == '"' || chars[i] == '\'') {
                let quote = chars[i];
                i += 1;
                let value_start = i;
                while i < chars.len() && chars[i] != quote {
                    i += 1;
                }
                let value = chars[value_start..i].iter().collect();
                i += 1;
                value
            } else {
                let value_start = i;
                while i < chars.len() && !chars[i].is_whitespace() {
                    i += 1;
                }
                chars[value_start..i].iter().collect()
            };
            if !key.is_empty() {
                out.entry(key).or_insert(value);
            }
        } else if key.is_empty() {
            i += 1;
        }
    }
    out
}

/// The text of the first `<title>`, entities decoded; None when empty.
pub fn title_tag(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let open = lower.find("<title")?;
    let start = open + lower[open..].find('>')? + 1;
    let end = start + lower[start..].find("</title")?;
    let title = decode(&html[start..end]).trim().to_owned();
    (!title.is_empty()).then_some(title)
}

/// The common HTML entities, decimal and hex references included.
fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let entity = rest[1..]
            .find(';')
            .filter(|&n| n <= 10)
            .map(|n| &rest[1..=n]);
        let decoded = entity.and_then(|e| match e {
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
            (Some(e), Some(c)) => {
                out.push(c);
                rest = &rest[e.len() + 2..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}
