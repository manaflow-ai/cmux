//! A cmux link the phone opens: what the Mac copies (Copy Link), what Chief
//! and agents write in their text, and the https forms cmux.com and the Cloud
//! service hand out. The grammar is the Mac's (`CmuxNextActions/DeepLink`):
//! `<scheme>://<kind>/<id>`, where the id is the Mac's public resource id
//! (`ws_`, `pane_`, `tab_` and 32 lowercase hex digits), never a handle.
//!
//! Schemes: every cmux build's (`cmux`, `cmux-nightly`, `cmux-rc`, `cmux-dev`,
//! `cmux-dev-<tag>`). https: `cmux.com/deeplink/agent?harness=&session=`
//! (schemas/deeplinks/agent-link.json), a cloud group's `/g/<grp_>[/w/<ws_>]`
//! page, `cmux.com/deeplink/screen?…`, and `cmux.com/link/<kind>/…`, the same
//! path as the native link. A link is an address, never a command: every
//! query parameter but the ones named here is ignored.
//!
//! This was Swift's `CmuxLink.init(url:)` in CmuxMobileModel; Swift now keeps
//! only the value types and maps this module's result into them (Leo,
//! 2026-11-25: "They need to just keep going"). The agent-link part reads the
//! same schema vectors as acpmux's `agent_link.rs`, so neither can drift.
//!
//! Linear in the link's length; nothing is allocated past its parts.

use url::Url;

/// What a cmux link names.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CmuxLinkTarget {
    /// A workspace by its `ws_` resource id.
    Workspace { id: String },
    /// A pane by its `pane_` resource id: its selected tab.
    Pane { id: String },
    /// A terminal, browser or agent tab by its `tab_` resource id.
    Tab { id: String },
    /// An acpmux chat session, optionally at one turn (`#turn-<id>`).
    Session { id: String, turn: Option<String> },
    /// A Chief subagent's chat (`chief/<home>/session/<id>`).
    ChiefSession { home: String, session: String },
    /// An outside agent's session by the harness's own id.
    Agent { harness: String, session: String },
    /// A cloud group, optionally one of its workspaces.
    Group { id: String, workspace: Option<String> },
    /// A Home conversation, optionally at one message.
    Conversation { id: String, message: Option<String> },
    /// A Mac's screen through the device hub: view only unless `control`.
    MacScreen {
        /// The hub device id (lowercase uuid).
        device: String,
        /// The CGDirectDisplayID in decimal; none is the host's default.
        display: Option<String>,
        control: bool,
        /// The run's label (display only, never used to route).
        name: Option<String>,
    },
}

/// A parsed cmux link.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ParsedCmuxLink {
    pub target: CmuxLinkTarget,
    /// An agent link's `?message=`: the message to scroll to (display only).
    pub message: Option<String>,
}

/// The hosts whose https links the phone opens.
const WEB_HOSTS: [&str; 2] = ["cmux.com", "www.cmux.com"];
/// The hosts that serve a cloud group's hand-off page (the Mac's `DeepLink.groupWebHosts`).
const GROUP_WEB_HOSTS: [&str; 4] =
    ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux.com", "www.cmux.com"];

/// The link `url` names, or none when it is not a cmux link (another scheme
/// or host, the sign-in callback, a malformed id).
#[uniffi::export]
pub fn cmux_link_parse(url: String) -> Option<ParsedCmuxLink> {
    parse(&url)
}

type Query = Vec<(String, Option<String>)>;

pub(crate) fn parse(text: &str) -> Option<ParsedCmuxLink> {
    let url = Url::parse(text).ok()?;
    if !url.username().is_empty() || url.password().is_some() || has_port(text) {
        return None;
    }
    let scheme = url.scheme().to_ascii_lowercase();
    let host = decode(url.host_str()?)?.to_lowercase();
    let path = segments(url.path())?;
    let query = query_items(url.query())?;
    if scheme == "https" {
        return web(&host, path, &query);
    }
    if !is_link_scheme(&scheme) || host.is_empty() {
        return None;
    }
    let fragment = match url.fragment() {
        Some(raw) => Some(decode(raw)?),
        None => None,
    };
    native(&host, &path, &query, fragment.as_deref())
}

/// Whether the authority names a port (`https://cmux.com:443/` too, which
/// the `url` crate drops as the default).
fn has_port(text: &str) -> bool {
    let Some((_, rest)) = text.split_once("://") else { return false };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    authority.contains(':')
}

/// Whether `scheme` is a cmux build's link scheme. `cmux-next` is never a link.
fn is_link_scheme(scheme: &str) -> bool {
    let scheme = scheme.to_ascii_lowercase();
    matches!(scheme.as_str(), "cmux" | "cmux-nightly" | "cmux-rc" | "cmux-dev")
        || scheme.starts_with("cmux-dev-")
}

fn link(target: CmuxLinkTarget) -> Option<ParsedCmuxLink> {
    Some(ParsedCmuxLink { target, message: None })
}

fn segments(path: &str) -> Option<Vec<String>> {
    path.split('/').filter(|s| !s.is_empty()).map(decode).collect()
}

fn query_items(query: Option<&str>) -> Option<Query> {
    let Some(query) = query else { return Some(Vec::new()) };
    if query.is_empty() {
        return Some(Vec::new());
    }
    query
        .split('&')
        .map(|item| match item.split_once('=') {
            Some((name, value)) => Some((decode(name)?, Some(decode(value)?))),
            None => Some((decode(item)?, None)),
        })
        .collect()
}

/// Percent-decoding as Foundation's URLComponents does it: `%XX` only (`+` stays),
/// none when the bytes are not UTF-8.
fn decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |b: u8| (b as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).ok()
}

/// The one value of `name`: `Some(None)` when it is absent, `Some(Some(v))`
/// when it appears once (with a value or without), none when repeated.
fn single<'a>(query: &'a Query, name: &str) -> Option<Option<Option<&'a str>>> {
    let mut items = query.iter().filter(|(n, _)| n == name);
    let first = items.next();
    if items.next().is_some() {
        return None;
    }
    Some(first.map(|(_, v)| v.as_deref()))
}

fn native(host: &str, path: &[String], query: &Query, fragment: Option<&str>) -> Option<ParsedCmuxLink> {
    if host == "mac-screen" {
        if !path.is_empty() || fragment.is_some() {
            return None;
        }
        return mac_screen(query);
    }
    let first = path.first()?;
    let one = path.len() == 1 && fragment.is_none();
    match host {
        "workspace" if one && is_resource_id(first, "ws_") => {
            link(CmuxLinkTarget::Workspace { id: first.clone() })
        }
        "pane" if one && is_resource_id(first, "pane_") => link(CmuxLinkTarget::Pane { id: first.clone() }),
        "tab" if one && is_resource_id(first, "tab_") => link(CmuxLinkTarget::Tab { id: first.clone() }),
        "session" if path.len() == 1 && is_token(first) => {
            let turn = match fragment {
                None => None,
                Some(fragment) => {
                    let turn = fragment.strip_prefix("turn-")?;
                    if !is_token(turn) {
                        return None;
                    }
                    Some(turn.to_owned())
                }
            };
            link(CmuxLinkTarget::Session { id: first.clone(), turn })
        }
        "chief"
            if path.len() == 3
                && path[1] == "session"
                && fragment.is_none()
                && is_chief_home(first)
                && is_token(&path[2]) =>
        {
            link(CmuxLinkTarget::ChiefSession { home: first.clone(), session: path[2].clone() })
        }
        "agent" if path.len() == 2 && fragment.is_none() => agent(first, &path[1], query),
        "group" if fragment.is_none() && is_group_id(first) => match path.len() {
            1 => link(CmuxLinkTarget::Group { id: first.clone(), workspace: None }),
            3 if path[1] == "workspace" && is_resource_id(&path[2], "ws_") => {
                link(CmuxLinkTarget::Group { id: first.clone(), workspace: Some(path[2].clone()) })
            }
            _ => None,
        },
        "conversation" if is_token(first) => match path.len() {
            1 => link(CmuxLinkTarget::Conversation { id: first.clone(), message: None }),
            3 if path[1] == "message" && is_token(&path[2]) => {
                link(CmuxLinkTarget::Conversation { id: first.clone(), message: Some(path[2].clone()) })
            }
            _ => None,
        },
        // Includes `auth-callback`, the sign-in callback.
        _ => None,
    }
}

fn web(host: &str, mut path: Vec<String>, query: &Query) -> Option<ParsedCmuxLink> {
    if GROUP_WEB_HOSTS.contains(&host) && path.len() >= 2 && path[0] == "g" && is_group_id(&path[1]) {
        return match path.len() {
            2 => link(CmuxLinkTarget::Group { id: path[1].clone(), workspace: None }),
            4 if path[2] == "w" && is_resource_id(&path[3], "ws_") => {
                link(CmuxLinkTarget::Group { id: path[1].clone(), workspace: Some(path[3].clone()) })
            }
            _ => None,
        };
    }
    if !WEB_HOSTS.contains(&host) {
        return None;
    }
    // cmux.com's locale prefix (`/en/deeplink/agent`, `/zh-CN/link/…`).
    if path.len() > 1 {
        let count = path[0].chars().count();
        if (count == 2 || (count == 5 && path[0].contains('-')))
            && (path[1] == "deeplink" || path[1] == "link")
        {
            path.remove(0);
        }
    }
    if path == ["deeplink", "screen"] {
        return mac_screen(query);
    }
    if path == ["deeplink", "agent"] {
        let harness = single(query, "harness")???;
        let session = single(query, "session")???;
        return agent(harness, session, query);
    }
    // `cmux.com/link/<kind>/…` is the native link's path on the web.
    if path.len() < 3 || path[0] != "link" {
        return None;
    }
    native(&path[1], &path[2..], query, None)
}

/// `device=` (required, a uuid), `display=` (decimal), `control=1`, `name=`; each at most once.
fn mac_screen(query: &Query) -> Option<ParsedCmuxLink> {
    let device = single(query, "device")???;
    if !is_device_id(device) {
        return None;
    }
    let display = single(query, "display")?.flatten();
    let control = single(query, "control")?.flatten();
    let name = single(query, "name")?.flatten();
    if let Some(display) = display
        && !is_display_id(display)
    {
        return None;
    }
    let name = name.map(str::trim).filter(|n| !n.is_empty()).map(|n| n.chars().take(200).collect());
    link(CmuxLinkTarget::MacScreen {
        device: device.to_ascii_lowercase(),
        display: display.map(str::to_owned),
        control: control == Some("1"),
        name,
    })
}

fn agent(harness: &str, session: &str, query: &Query) -> Option<ParsedCmuxLink> {
    if !is_harness(harness) || !is_agent_session(session) {
        return None;
    }
    let message = single(query, "message")
        .flatten()
        .flatten()
        .filter(|m| is_token(m) && !is_only_dots(m))
        .map(str::to_owned);
    Some(ParsedCmuxLink {
        target: CmuxLinkTarget::Agent { harness: harness.to_owned(), session: session.to_owned() },
        message,
    })
}

// Grammar (the Mac's DeepLink).

fn is_resource_id(text: &str, prefix: &str) -> bool {
    text.strip_prefix(prefix).is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// A hub device id: a uuid (any case), 8-4-4-4-12 hex digits.
fn is_device_id(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(g, n)| g.len() == n && g.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// A CGDirectDisplayID in decimal (a u32).
fn is_display_id(text: &str) -> bool {
    (1..=10).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_digit()) && text.parse::<u32>().is_ok()
}

fn is_group_id(text: &str) -> bool {
    text.strip_prefix("grp_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase())
    })
}

fn is_chief_home(text: &str) -> bool {
    text.len() == 8 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_token(text: &str) -> bool {
    (1..=200).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

fn is_harness(text: &str) -> bool {
    (1..=64).contains(&text.len())
        && text.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase() || b == b'-')
}

fn is_agent_session(text: &str) -> bool {
    (1..=256).contains(&text.len())
        && !is_only_dots(text)
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
}

fn is_only_dots(text: &str) -> bool {
    text.bytes().all(|b| b == b'.')
}

#[cfg(test)]
#[path = "cmux_link_tests.rs"]
mod tests;
