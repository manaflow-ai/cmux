//! `site-data` (`site-data-handoff-v1`): on Open on iPhone, the Mac hands the
//! phone the tab's cookies and local storage for the tab's own site, so the
//! page loads signed in (hq RFD 0089 "Shared sessions"; RFD 0125 D7 and D8).
//!
//! This is a lent tab, not a synced jar. The rules, each enforced here:
//!
//! - **Off until the person turns it on.** The app says
//!   `{"type":"site_data_handoff","enabled":bool}`; before that line, and
//!   after `false`, the service refuses `off` and `version` does not list
//!   the capability.
//! - **Only a person's Open on iPhone.** The phone opens the channel with
//!   `{"surface", "url", "trigger":"open_on_iphone"}` from that menu item
//!   only; anything else is refused `no_person_action`. Machines (a Mac or a
//!   Cloud VM paired as a machine) are never offered the service
//!   (`peer::allows`), and no agent path (`acpmux`, `daemon`, the browser
//!   REPL) reaches it: a VM never holds the person's cookies (RFD 0125 D7.6).
//! - **One site.** The tab must be a browser tab the daemon lists now, at an
//!   http(s) address whose site (registrable domain) is the one asked for.
//!   Only cookies whose Domain is that site or a subdomain of it, and only
//!   local storage of origins on it, go to the phone.
//! - **Not incognito, not the Agents profile.** The app names the tab's
//!   profile; an incognito store or the Agents profile is refused. The
//!   daemon connection says `remote: true`, so an incognito workspace's tabs
//!   are not even listed.
//! - **Short-lived.** A cookie keeps its own expiry, capped at 24 hours from
//!   the hand-off ([`MAX_LIFETIME_MS`]); a session cookie stays a session
//!   cookie; an expired one is left out. Tapping Open on iPhone again hands
//!   the current ones over again.
//! - **One way.** The phone's later changes do not come back to the Mac (v1).
//!
//! The engine read is the app's (WebKit's or CEF's cookie store, the page's
//! `localStorage`): hostd asks `{"type":"need_site_data","request","surface",
//! "site","url"}` and the app answers `{"type":"site_data","request","data":
//! {"profile_id","agents_profile","incognito","cookies","local_storage"}}` or
//! `{"type":"site_data_failed","request","reason"}`. Every decision above is
//! made here, on what the app sent, before one byte goes to the phone. The
//! link is end-to-end encrypted (WireGuard or DTLS) between this Mac and the
//! paired phone; values are never logged.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use bytes::Bytes;
use cmux_mobile_link::link::ChannelSender;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::oneshot;
use tokio::time::{Duration, timeout};

use crate::services::Refusal;

/// The service name.
pub const SERVICE: &str = "site-data";

/// The only trigger the service answers: the person chose Open on iPhone.
pub const TRIGGER: &str = "open_on_iphone";

/// The longest a handed-over cookie lives on the phone: 24 hours.
pub const MAX_LIFETIME_MS: i64 = 24 * 60 * 60 * 1000;

/// At most this many cookies and storage items, and this many bytes of
/// names and values, go to the phone in one hand-off.
pub const MAX_COOKIES: usize = 300;
pub const MAX_STORAGE_ITEMS: usize = 1_000;
pub const MAX_BYTES: usize = 2 * 1024 * 1024;

/// The browser profile agents get (RFD 0125 D7.1; `AGENT_PROFILE` in
/// cmux-browser-host). Never handed over.
const AGENT_PROFILES: &[&str] = &["agent", "agents"];

/// How long the app has to read the store.
const APP_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_PENDING: usize = 8;

static ENABLED: AtomicBool = AtomicBool::new(false);

/// Whether the person turned the hand-off on (the app's `site_data_handoff`).
pub fn enabled() -> bool {
    ENABLED.load(Ordering::SeqCst)
}

/// The app's `site_data_handoff` line.
pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::SeqCst);
}

/// One cookie, as the app reads it from the engine and as the phone sets it.
#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    #[serde(default = "root_path")]
    pub path: String,
    /// Epoch milliseconds; absent: a session cookie.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<i64>,
    #[serde(default)]
    pub secure: bool,
    #[serde(default)]
    pub http_only: bool,
    /// `lax`, `strict` or `none`, as the engine has it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub same_site: Option<String>,
}

fn root_path() -> String {
    "/".into()
}

impl std::fmt::Debug for Cookie {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cookie")
            .field("name", &self.name)
            .field("domain", &self.domain)
            .field("path", &self.path)
            .field("expires_ms", &self.expires_ms)
            .finish_non_exhaustive()
    }
}

/// One origin's `localStorage`, as `[key, value]` pairs.
#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct StorageArea {
    pub origin: String,
    #[serde(default)]
    pub items: Vec<(String, String)>,
}

impl std::fmt::Debug for StorageArea {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StorageArea").field("origin", &self.origin).field("items", &self.items.len()).finish()
    }
}

/// What the app read from the tab's store (`site_data` `data`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct FromApp {
    /// The tab's browser profile id.
    #[serde(default)]
    pub profile_id: String,
    /// The app marks the Agents profile, whatever its id.
    #[serde(default)]
    pub agents_profile: bool,
    #[serde(default)]
    pub incognito: bool,
    #[serde(default)]
    pub cookies: Vec<Cookie>,
    #[serde(default)]
    pub local_storage: Vec<StorageArea>,
}

/// A phone's ask, checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ask {
    pub surface: u64,
    pub url: String,
    pub site: String,
}

/// What the phone gets: one data frame, then `eof`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Package {
    pub v: u32,
    pub site: String,
    pub url: String,
    pub handed_at_ms: i64,
    pub cookies: Vec<Cookie>,
    pub local_storage: Vec<StorageArea>,
}

/// Checks the channel's args: `{"surface", "url", "trigger":"open_on_iphone"}`;
/// `surface` is a number, its decimal string or the tab key `s<surface>`.
pub fn parse_ask(args: &Value) -> Result<Ask, Refusal> {
    if args.get("trigger").and_then(Value::as_str) != Some(TRIGGER) {
        return Err(Refusal::new("no_person_action", "site data goes only on the person's Open on iPhone"));
    }
    // A number, or the phone's tab key `s<surface>` / its digits (link args are strings).
    let surface = match args.get("surface") {
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => s.strip_prefix('s').unwrap_or(s).parse().ok(),
        _ => None,
    }
    .ok_or_else(|| Refusal::new("bad_request", "site-data needs the tab's surface"))?;
    let url = args
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| Refusal::new("bad_request", "site-data needs the tab's url"))?;
    let site =
        web_site(url).ok_or_else(|| Refusal::new("bad_request", "only an http(s) page has site data"))?;
    Ok(Ask { surface, url: url.to_owned(), site })
}

/// The site of an http(s) address, else `None`.
pub fn web_site(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    let host = parsed.host_str()?;
    let site = site_of(host);
    (!site.is_empty()).then_some(site)
}

/// Multi-label public suffixes common enough to matter; any other host has a
/// one-label suffix. The same stand-in as cmux-browser-host `policy::site_of`
/// until a Public Suffix List lands there; a miss only makes the scope
/// narrower or (for an unlisted multi-label suffix) one label wider, never
/// another site's.
const MULTI_SUFFIXES: &[&str] = &[
    "co.uk",
    "org.uk",
    "ac.uk",
    "gov.uk",
    "me.uk",
    "ltd.uk",
    "plc.uk",
    "net.uk",
    "co.jp",
    "ne.jp",
    "or.jp",
    "ac.jp",
    "go.jp",
    "co.at",
    "or.at",
    "com.au",
    "net.au",
    "org.au",
    "edu.au",
    "gov.au",
    "co.nz",
    "org.nz",
    "govt.nz",
    "co.in",
    "net.in",
    "org.in",
    "gov.in",
    "ac.in",
    "com.br",
    "net.br",
    "org.br",
    "gov.br",
    "com.cn",
    "net.cn",
    "org.cn",
    "ngrok.io",
    "ngrok-free.app",
    "trycloudflare.com",
    "github.io",
    "vercel.app",
    "netlify.app",
    "pages.dev",
    "workers.dev",
    "herokuapp.com",
    "fly.dev",
    "onrender.com",
];

/// The site (registrable domain) of a host; an IP address, a single label
/// (`localhost`) or a bracketed IPv6 address is its own site.
pub fn site_of(host: &str) -> String {
    let h = host.trim_start_matches('.').trim_end_matches('.').to_ascii_lowercase();
    let is_ipv4 = h.split('.').count() == 4
        && h.split('.').all(|l| !l.is_empty() && l.bytes().all(|c| c.is_ascii_digit()));
    if h.is_empty() || h.starts_with('[') || h.contains(':') || is_ipv4 || !h.contains('.') {
        return h;
    }
    let labels: Vec<&str> = h.split('.').collect();
    for i in 1..labels.len() {
        if MULTI_SUFFIXES.contains(&labels[i..].join(".").as_str()) {
            return labels[i - 1..].join(".");
        }
    }
    labels[labels.len() - 2..].join(".")
}

/// Whether a cookie Domain (or a host) is `site` or below it.
pub fn on_site(domain: &str, site: &str) -> bool {
    let host = domain.trim_start_matches('.').trim_end_matches('.').to_ascii_lowercase();
    !host.is_empty() && (host == site || host.ends_with(&format!(".{site}")))
}

/// The address of browser tab `surface` in a `list-workspaces` reply, if the
/// daemon lists it as a browser tab now.
pub fn browser_tab_url(reply: &Value, surface: u64) -> Option<String> {
    let data = reply.get("data").unwrap_or(reply);
    let list =
        |value: &Value, key: &str| value.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    for workspace in list(data, "workspaces") {
        for screen in list(&workspace, "screens") {
            for pane in list(&screen, "panes") {
                for tab in list(&pane, "tabs") {
                    if tab.get("surface").and_then(Value::as_u64) == Some(surface)
                        && tab.get("kind").and_then(Value::as_str) == Some("browser")
                    {
                        return tab.get("url").and_then(Value::as_str).map(str::to_owned);
                    }
                }
            }
        }
    }
    None
}

/// The tab check: `surface` is a browser tab the daemon lists now, on the
/// site the phone asked for.
pub fn check_tab(reply: &Value, ask: &Ask) -> Result<(), Refusal> {
    let url = browser_tab_url(reply, ask.surface)
        .ok_or_else(|| Refusal::new("forbidden", "that is not a browser tab this Mac shows the phone"))?;
    match web_site(&url) {
        Some(site) if site == ask.site => Ok(()),
        _ => Err(Refusal::new("forbidden", "the tab is no longer on that site")),
    }
}

/// The package for the phone from what the app read: every rule of the
/// module doc that needs the store's contents.
pub fn package(ask: &Ask, from_app: FromApp, now_ms: i64) -> Result<Package, Refusal> {
    if from_app.incognito {
        return Err(Refusal::new("forbidden", "an incognito tab's site data never leaves the Mac"));
    }
    if from_app.agents_profile || AGENT_PROFILES.contains(&from_app.profile_id.to_ascii_lowercase().as_str())
    {
        return Err(Refusal::new("forbidden", "the Agents profile's site data never leaves the Mac"));
    }
    let cap = now_ms.saturating_add(MAX_LIFETIME_MS);
    let mut bytes = 0usize;
    let mut cookies = Vec::new();
    for mut cookie in from_app.cookies {
        if !on_site(&cookie.domain, &ask.site) || cookie.name.is_empty() {
            continue;
        }
        match cookie.expires_ms {
            Some(at) if at <= now_ms => continue,
            Some(at) => cookie.expires_ms = Some(at.min(cap)),
            None => {}
        }
        bytes += cookie.name.len() + cookie.value.len() + cookie.domain.len() + cookie.path.len();
        if cookies.len() == MAX_COOKIES || bytes > MAX_BYTES {
            return Err(Refusal::new("too_large", "the site's data is larger than a hand-off carries"));
        }
        cookies.push(cookie);
    }
    let mut local_storage = Vec::new();
    let mut items = 0usize;
    for area in from_app.local_storage {
        let Some(site) = web_site(&area.origin) else { continue };
        if site != ask.site || area.items.is_empty() {
            continue;
        }
        items += area.items.len();
        bytes += area.items.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>();
        if items > MAX_STORAGE_ITEMS || bytes > MAX_BYTES {
            return Err(Refusal::new("too_large", "the site's data is larger than a hand-off carries"));
        }
        local_storage.push(area);
    }
    Ok(Package {
        v: 1,
        site: ask.site.clone(),
        url: ask.url.clone(),
        handed_at_ms: now_ms,
        cookies,
        local_storage,
    })
}

/// Requests to the app waiting for `site_data`.
#[derive(Default)]
struct Broker {
    next: AtomicU64,
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<FromApp, String>>>>,
}

fn broker() -> Arc<Broker> {
    static BROKER: OnceLock<Arc<Broker>> = OnceLock::new();
    BROKER.get_or_init(|| Arc::new(Broker::default())).clone()
}

struct Pending {
    broker: Arc<Broker>,
    request: u64,
}

impl Drop for Pending {
    fn drop(&mut self) {
        self.broker.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.request);
    }
}

/// The app's `site_data` / `site_data_failed` for `request`.
pub fn answer(request: u64, result: Result<FromApp, String>) {
    if let Some(sender) = broker().pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request) {
        let _ = sender.send(result);
    }
}

/// Asks the app to read the tab's store through `emit` (the control line).
pub async fn ask_app(ask: &Ask, emit: &(dyn Fn(&crate::control::Event) + Sync)) -> Result<FromApp, Refusal> {
    let broker = broker();
    let request = broker.next.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
    let (sender, receiver) = oneshot::channel();
    {
        let mut pending = broker.pending.lock().unwrap_or_else(|e| e.into_inner());
        if pending.len() >= MAX_PENDING {
            return Err(Refusal::new("busy", "too many site data hand-offs at once"));
        }
        pending.insert(request, sender);
    }
    let _pending = Pending { broker: Arc::clone(&broker), request };
    emit(&crate::control::Event::NeedSiteData {
        request,
        surface: ask.surface,
        site: ask.site.clone(),
        url: ask.url.clone(),
    });
    match timeout(APP_TIMEOUT, receiver).await {
        Ok(Ok(Ok(data))) => Ok(data),
        Ok(Ok(Err(reason))) => Err(Refusal::new("unavailable", reason)),
        Ok(Err(_)) | Err(_) => {
            Err(Refusal::new("unavailable", "the Mac app did not read the tab's site data"))
        }
    }
}

/// The `list-workspaces` query, as a remote client: the daemon hides
/// incognito workspaces from it as from a phone.
pub fn tabs_query() -> String {
    format!(
        "{}\n{{\"cmd\":\"list-workspaces\",\"id\":\"cmux-mobile-site-data\"}}\n",
        serde_json::json!({
            "cmd": "set-client-info",
            "id": "cmux-mobile-site-data-hello",
            "name": "cmux-mobile-host site-data",
            "kind": "cli",
            "remote": true,
            "device_id": "cmux-mobile-host-site-data",
            "capabilities": [cmux_mobile_link::names::CONVERSATION_TABS, cmux_mobile_link::names::PAGE_TABS],
        })
    )
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Serves one `site-data` channel: checks, asks the app, sends the package.
pub async fn serve(
    daemon_reply: impl std::future::Future<Output = Result<Value, Refusal>>,
    args: &Value,
    emit: &(dyn Fn(&crate::control::Event) + Sync),
    sender: &ChannelSender,
) -> Result<(), Refusal> {
    if !enabled() {
        return Err(Refusal::new("off", "sign-in hand-off to iPhone is off on this Mac"));
    }
    let ask = parse_ask(args)?;
    check_tab(&daemon_reply.await?, &ask)?;
    let package = package(&ask, ask_app(&ask, emit).await?, now_ms())?;
    tracing::info!(
        surface = ask.surface,
        site = ask.site,
        cookies = package.cookies.len(),
        origins = package.local_storage.len(),
        "site data handed to the phone"
    );
    let body = serde_json::to_vec(&package).map_err(|_| Refusal::new("unavailable", "could not encode"))?;
    sender.send(Bytes::from(body)).await.map_err(|_| Refusal::new("closed", "phone channel closed"))
}

#[cfg(test)]
#[path = "site_data_tests.rs"]
mod tests;
