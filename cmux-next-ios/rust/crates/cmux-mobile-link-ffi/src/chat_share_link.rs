//! A chat share link the phone opens: a guest link (`https://share.cmux.dev/g/<id>#<secret>`),
//! an invite (`https://share.cmux.dev/i/<id>`), or the guest page's open-in-app form
//! (`<scheme>://share?link=<page>#<secret>`). The grammar is the Mac daemon's (`cmux-tui-core`
//! `agent_session_share_link.rs`): an id of 16 to 128 URL-safe characters, and a secret of 8 to
//! 128 in the fragment, which no request ever carries.
//!
//! The app opens the page signed in as the phone's own cmux account: `chat_share_handoff_url`
//! is where the account's token buys a one-time code (cmux-platform
//! `POST /v1/chat-shares/<id>/handoff`), and `chat_share_page_url` is the page with that code.
//! Only a known share host's page is opened this way; the token never goes to any other host.
//!
//! This was Swift's `ChatShareLink` in CmuxMobileModel; Swift now keeps the value type and maps
//! this module's result into it (Leo, 2026-11-25: "They need to just keep going"). The URL is
//! split as Foundation's `URLComponents` splits it (RFC 3986: no path normalization, a written
//! `:443` is a port), not as the `url` crate's WHATWG parser does, so the same links open.

use crate::cmux_link::{decode, is_link_scheme};

/// `g`: a guest link's page; `i`: an invite's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ChatSharePage {
    Guest,
    Invite,
}

impl ChatSharePage {
    fn letter(self) -> &'static str {
        match self {
            Self::Guest => "g",
            Self::Invite => "i",
        }
    }
}

/// A parsed chat share link.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ParsedChatShareLink {
    /// `https://<share host>`, the origin the page and its hand-off are on.
    pub origin: String,
    pub page: ChatSharePage,
    pub share_id: String,
    /// The guest link's secret (`#<secret>`); none for an invite, which is joined by account.
    pub secret: Option<String>,
}

/// The hosts that serve cmux chat share pages: the share host, and the platform's own
/// workers.dev origins (links made before the share host, which move to it).
const HOSTS: [&str; 3] = [
    "share.cmux.dev",
    "cmux-platform-production.debussy.workers.dev",
    "cmux-platform-staging.debussy.workers.dev",
];

/// The share link `url` names, or none when it is not one (another host, path or scheme, a
/// malformed id or secret).
#[uniffi::export]
pub fn chat_share_link_parse(url: String) -> Option<ParsedChatShareLink> {
    parse(&url)
}

/// The link with these parts, or none when the id or the secret is malformed.
#[uniffi::export]
pub fn chat_share_link_make(
    origin: String,
    page: ChatSharePage,
    share_id: String,
    secret: Option<String>,
) -> Option<ParsedChatShareLink> {
    make(origin, page, share_id, secret)
}

/// An id or hand-off code: 16 to 128 URL-safe characters.
#[uniffi::export]
pub fn chat_share_is_id(text: String) -> bool {
    is_id(&text)
}

/// Where the phone's account token is spent for a one-time code on this page.
#[uniffi::export]
pub fn chat_share_handoff_url(link: ParsedChatShareLink) -> String {
    format!("{}/v1/chat-shares/{}/handoff", link.origin, link.share_id)
}

/// The page to open: `<origin>/<g|i>/<id>?in_app=1[&cmux_handoff=<code>][#<secret>]`. `in_app=1`
/// keeps the page from asking the app to open it again; without a code (or with a malformed
/// one) it opens signed out.
#[uniffi::export]
pub fn chat_share_page_url(link: ParsedChatShareLink, handoff: Option<String>) -> String {
    let code =
        handoff.filter(|code| is_id(code)).map(|code| format!("&cmux_handoff={code}")).unwrap_or_default();
    let fragment = link.secret.map(|secret| format!("#{secret}")).unwrap_or_default();
    format!("{}/{}/{}?in_app=1{code}{fragment}", link.origin, link.page.letter(), link.share_id)
}

fn make(
    origin: String,
    page: ChatSharePage,
    share_id: String,
    secret: Option<String>,
) -> Option<ParsedChatShareLink> {
    if !is_id(&share_id) || secret.as_deref().is_some_and(|s| !is_secret(s)) {
        return None;
    }
    Some(ParsedChatShareLink { origin, page, share_id, secret })
}

/// A URL split into its RFC 3986 parts, the authority split again. Parts are still
/// percent-encoded.
struct Parts<'a> {
    scheme: &'a str,
    /// Whether the authority names a user (`user@`, an empty one too).
    has_user: bool,
    host: &'a str,
    /// Whether the authority names a port (`:443` too).
    has_port: bool,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

/// Splits `text` as URLComponents does; none when it has no `scheme://` authority or holds a
/// character no URL may (URLComponents(string:) refuses those).
fn split(text: &str) -> Option<Parts<'_>> {
    if !is_url_text(text) {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    if scheme.is_empty()
        || !scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let (rest, fragment) = match rest.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (rest, None),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((rest, query)) => (rest, Some(query)),
        None => (rest, None),
    };
    let (authority, path) = match rest.find('/') {
        Some(at) => rest.split_at(at),
        None => (rest, ""),
    };
    let (has_user, host_port) = match authority.rsplit_once('@') {
        Some((_, host_port)) => (true, host_port),
        None => (false, authority),
    };
    let (host, has_port) = match host_port.rsplit_once(':') {
        Some((host, port)) => (host, !port.is_empty()),
        None => (host_port, false),
    };
    Some(Parts { scheme, has_user, host, has_port, path, query, fragment })
}

/// Whether every character may appear in a URL: printable ASCII but space and `"<>\^`{|}`, and
/// each `%` the start of a `%XX` escape. `[` and `]` are only an IPv6 host's, and no share host
/// is one.
fn is_url_text(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'%' {
            if i + 2 >= bytes.len() || !bytes[i + 1].is_ascii_hexdigit() || !bytes[i + 2].is_ascii_hexdigit()
            {
                return false;
            }
            i += 3;
            continue;
        }
        if !b.is_ascii_graphic()
            || matches!(b, b'"' | b'<' | b'>' | b'\\' | b'^' | b'`' | b'{' | b'|' | b'}' | b'[' | b']')
        {
            return false;
        }
        i += 1;
    }
    // A second `#` is no fragment character.
    text.matches('#').count() <= 1
}

fn parse(text: &str) -> Option<ParsedChatShareLink> {
    let parts = split(text)?;
    if parts.has_user {
        return None;
    }
    let scheme = parts.scheme.to_ascii_lowercase();
    if scheme == "https" {
        let fragment = parts.fragment.map(decode).transpose()?;
        return page(&parts, fragment);
    }
    // The guest page's open-in-app link carries the page, and the secret in its own fragment.
    if !is_link_scheme(&scheme) || decode(parts.host)?.to_lowercase() != "share" {
        return None;
    }
    if !(parts.path.is_empty() || parts.path == "/") {
        return None;
    }
    let mut links = Vec::new();
    for item in parts.query.filter(|q| !q.is_empty()).into_iter().flat_map(|q| q.split('&')) {
        let (name, value) = match item.split_once('=') {
            Some((name, value)) => (decode(name)?, Some(decode(value)?)),
            None => (decode(item)?, None),
        };
        if name == "link" {
            links.push(value);
        }
    }
    let [Some(inner_text)] = links.as_slice() else { return None };
    let inner = split(inner_text)?;
    if !inner.scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    // `?app=<scheme>` names the build that made the link; the page is the same without it.
    let fragment = match inner.fragment.or(parts.fragment) {
        Some(raw) => Some(decode(raw)?),
        None => None,
    };
    page(&inner, fragment)
}

fn page(parts: &Parts<'_>, fragment: Option<String>) -> Option<ParsedChatShareLink> {
    if parts.has_user || parts.has_port {
        return None;
    }
    let host = decode(parts.host)?.to_lowercase();
    if !HOSTS.contains(&host.as_str()) {
        return None;
    }
    let path = decode(parts.path)?;
    let mut segments: Vec<&str> = path.split('/').collect();
    if segments.len() == 4 && segments.last() == Some(&"") {
        segments.pop();
    }
    let [first, letter, id] = segments.as_slice() else { return None };
    if !first.is_empty() {
        return None;
    }
    let page = match *letter {
        "g" => ChatSharePage::Guest,
        "i" => ChatSharePage::Invite,
        _ => return None,
    };
    let fragment = fragment.filter(|f| !f.is_empty());
    // An invite is joined by account: a fragment on it is not a secret and is dropped.
    let secret = if page == ChatSharePage::Guest { fragment } else { None };
    make(format!("https://{host}"), page, (*id).to_owned(), secret)
}

fn is_id(text: &str) -> bool {
    (16..=128).contains(&text.len()) && text.bytes().all(is_url_safe)
}

fn is_secret(text: &str) -> bool {
    (8..=128).contains(&text.len()) && text.bytes().all(is_url_safe)
}

fn is_url_safe(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'
}

#[cfg(test)]
#[path = "chat_share_link_tests.rs"]
mod tests;
