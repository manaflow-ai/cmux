//! `browser`: a streamed browser tab (cmux-next-ios/verify/browser-stream.md).
//!
//! The phone opens `browser {tab, url?}`. hostd keeps one Mac browser host
//! per tab: `cmux-remote-browser-host --serve`, the CEF fork host the cmux-next
//! app runs for its own remote tabs, speaking `cmux.rb/1` on `cmux.rd/1` over
//! the rd stream carrier on loopback. hostd connects to it, sends the rd
//! `hello` with the host's per-launch secret (the phone never sees the
//! secret), and then splices the channel:
//!
//! - host to phone: the carrier's bytes, unchanged (video shards, control).
//! - phone to host: whole stream frames, each checked by [`filter_frame`]:
//!   datagrams (input, feedback, clock probes) pass, control passes only for
//!   the rb messages a viewer sends, `rb.navigate` only to an address
//!   [`crate::browser_policy`] allows (otherwise the phone gets
//!   `rb.navigate.refused {url, reason}`), and a second `hello` or bulk bytes
//!   never reach the host.
//! - The host's `rb.page` is checked the same way, so a link clicked inside
//!   the page follows the phone's rules: a page that is not allowed is
//!   taken back (`rb.history back`, or the last allowed page) and the phone
//!   gets `rb.navigate.refused` instead of its `rb.page`.
//!
//! A host outlives its channel, so a phone that comes back (link drop,
//! transport switch, tab switch) finds the page as it left it. A new channel
//! for the same tab takes the host over (`replaced` closes the older one).
//! At most `max_tabs` hosts run; opening another stops an idle host first,
//! then a hidden tab's, then the least recently used one, whose channel
//! closes `evicted` (the phone opens it again when it shows the tab).
//!
//! The phone says which tab it shows (`rb.visibility`, forwarded to the host
//! too). With `video: "track"` the tab shown last owns the link's media lane:
//! a newer channel takes the lane, and `rb.visibility` true takes it back
//! (transport-verify-20261019.md defect 7).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_rd_proto::control::{Control, SecretHex};
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer,
    encode_stream_frame,
};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{Mutex, oneshot};

use crate::services::{Peer, Refusal};

/// The rd cap that carries rb input inside rd input datagrams.
const INPUT_SERVICE: &str = "input.service";

/// How long a launched host has to print its listening line (CEF's first
/// start on a cold cache takes several seconds).
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(45);

/// What a launcher starts.
#[derive(Debug, Clone)]
pub struct LaunchRequest {
    pub tab: String,
    pub url: String,
}

/// Keeps a launched host alive; dropping it stops the host.
pub trait HostGuard: Send {
    fn alive(&mut self) -> bool;
}

/// A running host: where its rd stream carrier listens and its secret.
pub struct RunningHost {
    pub addr: SocketAddr,
    pub secret: String,
    pub guard: Box<dyn HostGuard>,
}

/// Starts a host for a tab.
pub type Launcher =
    Arc<dyn Fn(LaunchRequest) -> BoxFuture<'static, Result<RunningHost, String>> + Send + Sync>;

/// Why a viewer's splice ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stop {
    /// Another channel opened the same tab.
    Replaced,
    /// The host limit stopped this tab's host.
    Evicted,
}

struct Entry {
    host: RunningHost,
    last_used: Instant,
    /// The channel that views the tab now; firing it ends that splice.
    viewer: Option<(u64, oneshot::Sender<Stop>)>,
    /// The phone shows this tab (its viewer's last `rb.visibility`; streams
    /// start shown). Hidden hosts are stopped before shown ones.
    visible: Arc<AtomicBool>,
}

/// A viewer's hold on a tab's host.
pub(crate) struct Claim {
    addr: SocketAddr,
    secret: String,
    pub(crate) viewer: u64,
    /// This claim started the host (at its launch address).
    pub(crate) launched: bool,
    pub(crate) stopped: oneshot::Receiver<Stop>,
    pub(crate) visible: Arc<AtomicBool>,
}

/// The `browser` service's configuration and its running hosts.
#[derive(Clone)]
pub struct BrowserConfig {
    launcher: Option<Launcher>,
    max_tabs: usize,
    hosts: Arc<Mutex<HashMap<String, Entry>>>,
    next_viewer: Arc<std::sync::atomic::AtomicU64>,
}

impl std::fmt::Debug for BrowserConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BrowserConfig")
            .field("enabled", &self.launcher.is_some())
            .field("max_tabs", &self.max_tabs)
            .finish()
    }
}

impl Default for BrowserConfig {
    fn default() -> Self {
        Self::new(None, 4)
    }
}

impl BrowserConfig {
    /// Whether this Mac can stream browser tabs (the version service's `browser-stream-v1`).
    pub fn available(&self) -> bool {
        self.launcher.is_some()
    }

    /// `launcher` None refuses every open with `unavailable`.
    pub fn new(launcher: Option<Launcher>, max_tabs: usize) -> Self {
        Self { launcher, max_tabs: max_tabs.max(1), hosts: Arc::default(), next_viewer: Arc::default() }
    }

    /// Hosts are `exe --serve` processes; each tab's CEF cache lives in
    /// `<cache_root>/<tab>`.
    pub fn process(exe: PathBuf, cache_root: PathBuf, max_tabs: usize) -> Self {
        let launcher: Launcher = Arc::new(move |request: LaunchRequest| {
            let exe = exe.clone();
            let cache_root = cache_root.clone();
            Box::pin(async move { launch_process(&exe, &cache_root, &request).await })
        });
        Self::new(Some(launcher), max_tabs)
    }

    /// Tabs with a running host (tests and diagnostics).
    pub async fn running_tabs(&self) -> Vec<String> {
        let mut hosts = self.hosts.lock().await;
        hosts.retain(|_, entry| entry.host.guard.alive());
        let mut tabs: Vec<String> = hosts.keys().cloned().collect();
        tabs.sort();
        tabs
    }

    /// The host for `tab`, launched when needed, now owned by a new viewer.
    pub(crate) async fn claim(&self, tab: &str, url: &str) -> Result<Claim, Refusal> {
        let launcher = self
            .launcher
            .clone()
            .ok_or_else(|| Refusal::new("no_browser_host", "this Mac does not stream browser tabs"))?;
        let mut hosts = self.hosts.lock().await;
        hosts.retain(|_, entry| entry.host.guard.alive());
        let launched = !hosts.contains_key(tab);
        if launched {
            while hosts.len() >= self.max_tabs {
                // Idle hosts go first, then hidden tabs', then the least
                // recently used: the tab on the phone's screen goes last.
                let Some(oldest) = hosts
                    .iter()
                    .min_by_key(|(_, entry)| {
                        let shown = entry.viewer.is_some() && entry.visible.load(Ordering::SeqCst);
                        (entry.viewer.is_some(), shown, entry.last_used)
                    })
                    .map(|(tab, _)| tab.clone())
                else {
                    break;
                };
                tracing::info!(tab = oldest, "browser: stopping the least recently used host");
                if let Some(mut entry) = hosts.remove(&oldest)
                    && let Some((_, viewer)) = entry.viewer.take()
                {
                    let _ = viewer.send(Stop::Evicted);
                }
            }
            let request = LaunchRequest { tab: tab.to_owned(), url: url.to_owned() };
            let host = launcher(request).await.map_err(|e| Refusal::new("unavailable", e))?;
            tracing::info!(tab, addr = %host.addr, "browser: host started");
            hosts.insert(
                tab.to_owned(),
                Entry { host, last_used: Instant::now(), viewer: None, visible: Arc::default() },
            );
        }
        let entry = hosts.get_mut(tab).ok_or_else(|| Refusal::new("unavailable", "browser host vanished"))?;
        if let Some((_, previous)) = entry.viewer.take() {
            let _ = previous.send(Stop::Replaced);
        }
        let id = self.next_viewer.fetch_add(1, Ordering::Relaxed);
        let (cancel, stopped) = oneshot::channel();
        entry.viewer = Some((id, cancel));
        entry.last_used = Instant::now();
        // A new viewer starts shown; each viewer gets its own flag, so an
        // older splice's last word never marks the newer one hidden.
        entry.visible = Arc::new(AtomicBool::new(true));
        Ok(Claim {
            addr: entry.host.addr,
            secret: entry.host.secret.clone(),
            viewer: id,
            launched,
            stopped,
            visible: Arc::clone(&entry.visible),
        })
    }

    pub(crate) async fn release(&self, tab: &str, viewer: u64) {
        let mut hosts = self.hosts.lock().await;
        if let Some(entry) = hosts.get_mut(tab) {
            entry.last_used = Instant::now();
            if entry.viewer.as_ref().is_some_and(|(id, _)| *id == viewer) {
                entry.viewer = None;
            }
        }
    }
}

/// A tab key: what the phone names the tab by (`s<surface>` for a daemon
/// browser surface). Also a cache folder name.
pub fn valid_tab(tab: &str) -> bool {
    !tab.is_empty()
        && tab.len() <= 64
        && !tab.starts_with('.')
        && tab.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// The shown state in a phone-to-host control frame (`rb.visibility`), if
/// it is one.
pub fn visibility(payload: &[u8]) -> Option<bool> {
    let control = serde_json::from_slice::<Value>(payload).ok()?;
    if control.get("t").and_then(Value::as_str) != Some("service") {
        return None;
    }
    let body = control.get("body")?;
    if body.get("t").and_then(Value::as_str) != Some("rb.visibility") {
        return None;
    }
    body.get("visible").and_then(Value::as_bool)
}

/// rb messages a viewer may send (cmux.rb/1 section 4, direction V). The
/// rest are host messages, or features this service does not carry yet
/// (uploads, clipboard, permissions, cookie sync).
const VIEWER_MESSAGES: &[&str] = &[
    "rb.open",
    "rb.close",
    "rb.visibility",
    "rb.screen",
    "rb.vsync",
    "rb.history",
    "rb.navigate",
    "rb.menu.result",
    "rb.dialog.result",
    "rb.open_tab.result",
    "rb.find",
    "rb.find.stop",
];

/// What happens to one phone-to-host stream frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameVerdict {
    Forward,
    /// `rb.navigate` to this address: forwarded only when
    /// [`crate::browser_policy::check`] allows it.
    Navigate(String),
    Drop(&'static str),
}

/// Checks one stream frame the phone sent toward the host.
pub fn filter_frame(kind: u8, payload: &[u8]) -> FrameVerdict {
    match kind {
        STREAM_DATAGRAM => FrameVerdict::Forward,
        STREAM_CONTROL => {
            let Ok(control) = serde_json::from_slice::<Value>(payload) else {
                return FrameVerdict::Drop("control is not JSON");
            };
            match control.get("t").and_then(Value::as_str) {
                Some("stop") => FrameVerdict::Forward,
                Some("service") => {
                    if control.get("service").and_then(Value::as_str) != Some(SERVICE_REMOTE_BROWSER) {
                        return FrameVerdict::Drop("not an rb message");
                    }
                    let body = control.get("body").unwrap_or(&Value::Null);
                    let Some(t) = body.get("t").and_then(Value::as_str) else {
                        return FrameVerdict::Drop("rb message without t");
                    };
                    if !VIEWER_MESSAGES.contains(&t) {
                        return FrameVerdict::Drop("rb message a viewer may not send");
                    }
                    if t == "rb.navigate" {
                        return match body.get("url").and_then(Value::as_str) {
                            Some(url) => FrameVerdict::Navigate(url.to_owned()),
                            None => FrameVerdict::Drop("rb.navigate without an address"),
                        };
                    }
                    FrameVerdict::Forward
                }
                // hostd sent the hello; a second one (with or without a token)
                // never reaches the host.
                Some("hello") => FrameVerdict::Drop("hostd sends the hello"),
                _ => FrameVerdict::Drop("rd control a viewer may not send"),
            }
        }
        _ => FrameVerdict::Drop("bulk transfers are not carried"),
    }
}

/// The rd `hello` hostd sends for the phone.
pub fn hello_frame(secret: &str, peer: &Peer) -> Vec<u8> {
    let hello = Control::Hello {
        user: "cmux-mobile-host".into(),
        install: peer.device_id.clone(),
        class: "viewer".into(),
        interactive: true,
        udp_port: None,
        max_datagram: MAX_DATAGRAM_DEFAULT,
        token: Some(SecretHex(secret.to_owned())),
        service: SERVICE_REMOTE_BROWSER.into(),
        caps: vec![INPUT_SERVICE.into()],
    };
    let mut out = Vec::new();
    let json = serde_json::to_vec(&hello).unwrap_or_default();
    let _ = encode_stream_frame(STREAM_CONTROL, &json, &mut out);
    out
}

/// An rb message hostd itself sends, as one rd stream frame.
fn rb_frame(body: Value) -> Vec<u8> {
    let control = serde_json::json!({"t": "service", "service": SERVICE_REMOTE_BROWSER, "body": body});
    let mut out = Vec::new();
    let _ = encode_stream_frame(STREAM_CONTROL, &serde_json::to_vec(&control).unwrap_or_default(), &mut out);
    out
}

/// `rb.navigate.refused {url, reason}`: what the phone shows for an address
/// it may not load (PROTOCOL.md `browser`).
pub fn refused_frame(url: &str, blocked: crate::browser_policy::Blocked) -> Vec<u8> {
    rb_frame(serde_json::json!({
        "t": "rb.navigate.refused", "url": url, "code": blocked.wire_code(), "reason": blocked.message(),
    }))
}

/// The address and `can_go_back` of a host's `rb.page` control frame.
pub fn page_url(payload: &[u8]) -> Option<(String, bool)> {
    let control = serde_json::from_slice::<Value>(payload).ok()?;
    if control.get("t").and_then(Value::as_str) != Some("service") {
        return None;
    }
    let body = control.get("body")?;
    if body.get("t").and_then(Value::as_str) != Some("rb.page") {
        return None;
    }
    let url = body.get("url").and_then(Value::as_str)?.to_owned();
    Some((url, body.get("can_go_back").and_then(Value::as_bool).unwrap_or(false)))
}

/// Pages a tab keeps as approved because the Mac showed them.
const MAX_APPROVED: usize = 32;
/// How long one read of the Mac's state answers the guard's checks: one
/// `list-workspaces` per burst of page reports, not one per report.
const VIEW_TTL: Duration = Duration::from_secs(2);
/// Take-backs in a row (no phone navigation and no new allowed page between)
/// after which the guard sends the host to `about:blank`: a page that bounces to a refused address on
/// load would otherwise loop.
const MAX_TAKE_BACKS: u32 = 3;
/// How long a page must stay before the take-back count starts again.
const SETTLED: Duration = Duration::from_secs(1);

/// What a viewer's tab may show, and which page it shows (the guard of
/// the phone's `rb.navigate` and the host's `rb.page`).
pub(crate) struct PageGuard<'a> {
    mac: &'a dyn crate::browser_policy::MacPages,
    /// Pages this tab may load because the Mac showed them (its open
    /// address first, kept). Files in shared folders are checked every time.
    approved: Vec<String>,
    /// The last page the phone was shown.
    shown: Option<String>,
    /// A page the host committed that is not allowed (being taken back).
    blocked: Option<String>,
    take_backs: u32,
    /// When the guard last forwarded a new page: the take-back count starts again
    /// only once a page stayed a while ([`SETTLED`]), so a page that forwards
    /// itself on to one that bounces still counts.
    shown_at: Option<Instant>,
    view: Option<(Instant, crate::browser_policy::MacView)>,
    /// The last `rb.file_policy` sent to the host (sent again only when it changes).
    sent_policy: Option<Value>,
}

impl<'a> PageGuard<'a> {
    fn new(mac: &'a dyn crate::browser_policy::MacPages, opened: Option<String>) -> Self {
        Self {
            mac,
            approved: opened.into_iter().collect(),
            shown: None,
            blocked: None,
            take_backs: 0,
            shown_at: None,
            view: None,
            sent_policy: None,
        }
    }

    fn approve(&mut self, url: &str) {
        if !self.approved.iter().any(|a| a == url) {
            if self.approved.len() >= MAX_APPROVED {
                // The open address (index 0) stays; the oldest of the rest goes.
                self.approved.remove(1.min(self.approved.len() - 1));
            }
            self.approved.push(url.to_owned());
        }
    }

    async fn check(
        &mut self,
        url: &str,
    ) -> Result<crate::browser_policy::Allowed, crate::browser_policy::Blocked> {
        use crate::browser_policy::{Allowed, MacView, decide, needs_view};
        let fresh = self.view.as_ref().is_some_and(|(at, _)| at.elapsed() < VIEW_TTL);
        if needs_view(url) && !fresh {
            self.view = Some((Instant::now(), self.mac.view().await));
        }
        let empty = MacView::default();
        let view = self.view.as_ref().map_or(&empty, |(_, view)| view);
        let allowed = decide(url, view, &self.approved)?;
        if allowed == Allowed::MacShows {
            self.approve(url);
        }
        Ok(allowed)
    }

    /// The phone's `rb.navigate`: the address the host loads (a shared file
    /// at its resolved path), or why not.
    /// Reads the Mac's state now (the splice's start, before the host loads anything).
    async fn refresh_view(&mut self) {
        self.view = Some((Instant::now(), self.mac.view().await));
    }

    /// The host's `rb.file_policy` (its per-load check of every `file:` navigation
    /// and subresource) when it differs from the one sent: the shared folders and
    /// the files the Mac showed this tab.
    fn policy_update(&mut self) -> Option<Vec<u8>> {
        let view = self.view.as_ref().map(|(_, view)| view.clone()).unwrap_or_default();
        let body = file_policy(&view, &self.approved);
        if self.sent_policy.as_ref() == Some(&body) {
            return None;
        }
        self.sent_policy = Some(body.clone());
        Some(rb_frame(body))
    }

    async fn navigate(&mut self, url: &str) -> Result<String, crate::browser_policy::Blocked> {
        self.take_backs = 0;
        Ok(match self.check(url).await? {
            crate::browser_policy::Allowed::SharedFile(path) => {
                crate::browser_policy::resolved_file_url(url, &path)
            }
            _ => url.to_owned(),
        })
    }
}

/// The `rb.file_policy` body for the Mac's state and a tab's approved pages: the
/// shared folders as roots, and each page the Mac showed as one file (never its
/// folder: its siblings load only when they are in a shared folder).
fn file_policy(view: &crate::browser_policy::MacView, approved: &[String]) -> Value {
    let roots: Vec<PathBuf> = view.roots.iter().filter_map(|r| std::fs::canonicalize(r).ok()).collect();
    let mut files: Vec<PathBuf> = Vec::new();
    for url in approved {
        if let crate::browser_policy::Target::File(path) = crate::browser_policy::classify(url)
            && let Ok(file) = std::fs::canonicalize(&path)
            && !files.contains(&file)
        {
            files.push(file);
        }
    }
    serde_json::json!({"t": "rb.file_policy", "roots": roots, "files": files})
}

/// What the guard does with one host `rb.page`.
enum PageVerdict {
    Forward,
    Swallow,
    /// Swallow, tell the phone, and send the host these bytes.
    TakeBack {
        to_phone: Vec<u8>,
        to_host: Vec<u8>,
    },
}

impl PageGuard<'_> {
    async fn page(&mut self, url: &str, can_go_back: bool) -> PageVerdict {
        if url.is_empty() {
            return PageVerdict::Forward;
        }
        // The blocked page's later facts (title, loading) while the host goes back.
        if self.blocked.as_deref() == Some(url) {
            return PageVerdict::Swallow;
        }
        // The host left it: the same link followed again is taken back again.
        let returned = self.blocked.take().is_some();
        if self.shown.as_deref() == Some(url) {
            // Back on the shown page after a take-back: it has to stay a while again
            // before the count starts over (a page that bounces on load never does).
            if returned {
                self.shown_at = Some(Instant::now());
            }
            return PageVerdict::Forward;
        }
        match self.check(url).await {
            Ok(_) => {
                // The page before this one stayed a while: the bounce count starts again
                // (a redirecting page, or one bouncing back to the shown page, never does).
                if self.shown_at.is_some_and(|at| at.elapsed() >= SETTLED) {
                    self.take_backs = 0;
                }
                self.shown_at = Some(Instant::now());
                self.shown = Some(url.to_owned());
                PageVerdict::Forward
            }
            Err(blocked) => {
                // The shown page stayed a while (the person tapped a link on it): a
                // fresh count, so refused links on a page that stays never blank it.
                if self.shown_at.is_some_and(|at| at.elapsed() >= SETTLED) {
                    self.take_backs = 0;
                }
                tracing::info!(
                    ?blocked,
                    "browser: the page went somewhere the phone may not load; taking it back"
                );
                self.blocked = Some(url.to_owned());
                self.take_backs += 1;
                let back = if self.take_backs > MAX_TAKE_BACKS {
                    // A page that keeps going back to it: stop on the blank page.
                    self.shown = None;
                    serde_json::json!({"t": "rb.navigate", "url": "about:blank"})
                } else if can_go_back {
                    serde_json::json!({"t": "rb.history", "op": "back"})
                } else {
                    let to = self.shown.clone().unwrap_or_else(|| "about:blank".into());
                    serde_json::json!({"t": "rb.navigate", "url": to})
                };
                PageVerdict::TakeBack { to_phone: refused_frame(url, blocked), to_host: rb_frame(back) }
            }
        }
    }
}

/// `browser {tab, url?}`: see the module docs. `mac` answers what the Mac
/// shares and shows ([`crate::browser_policy`]).
pub async fn serve(
    config: &BrowserConfig,
    mac: &dyn crate::browser_policy::MacPages,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let tab = args.get("tab").and_then(Value::as_str).unwrap_or("default");
    if !valid_tab(tab) {
        return Err(Refusal::new("bad_request", "invalid tab"));
    }
    let (url, opened) = match args.get("url").and_then(Value::as_str).filter(|u| !u.trim().is_empty()) {
        Some(url) => {
            use crate::browser_policy::Allowed;
            let url = url.trim().to_owned();
            match crate::browser_policy::check(&url, mac, &[]).await {
                Ok(Allowed::SharedFile(path)) => {
                    (crate::browser_policy::resolved_file_url(&url, &path), None)
                }
                Ok(Allowed::MacShows) => (url.clone(), Some(url)),
                Ok(Allowed::Web) => (url, None),
                Err(blocked) => return Err(Refusal::new(blocked.code(), blocked.message())),
            }
        }
        None => ("about:blank".to_owned(), None),
    };
    let mut guard = PageGuard::new(mac, opened);
    // A new host starts at a `file:` page only after its file policy is in place:
    // it starts blank, and hostd navigates once the policy is sent.
    let file_page = matches!(crate::browser_policy::classify(&url), crate::browser_policy::Target::File(_));
    let claim = config.claim(tab, if file_page { "about:blank" } else { &url }).await?;
    let first = (claim.launched && file_page).then(|| url.clone());
    guard.refresh_view().await;
    let viewer = claim.viewer;
    // `video: "track"`: the page's video on the link's media lane (a WebRTC
    // track or RTP inside the WireGuard tunnel) when the link has one;
    // otherwise (an older phone, or the lane off) on this channel.
    let track = (args.get("video").and_then(Value::as_str) == Some("track"))
        .then_some(peer.video.as_ref())
        .flatten()
        .filter(|video| !video.is_closed());
    // The phone's tag for this tab's lane frames (cmux_mobile_link::media::tag).
    let video_tag = args.get("video_tag").and_then(Value::as_u64).and_then(|tag| u32::try_from(tag).ok());
    let track = track.map(|video| (video, video_tag));
    let result = splice(claim, Some(guard), filter_frame, first, peer, sender, receiver, track).await;
    config.release(tab, viewer).await;
    result
}

/// Splices a viewer channel to its tab's host (a browser host, or a
/// simulator surface's host, `surface.rs`): `filter` checks each phone frame,
/// and `guard` (browser tabs only) checks addresses both ways.
#[allow(clippy::too_many_arguments)] // one viewer's whole splice: its claim, checks, peer, channel and lane
pub(crate) async fn splice(
    claim_of_host: Claim,
    mut guard: Option<PageGuard<'_>>,
    filter: fn(u8, &[u8]) -> FrameVerdict,
    first: Option<String>,
    peer: &Peer,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
    track: Option<(&cmux_mobile_link::media::VideoOut, Option<u32>)>,
) -> Result<(), Refusal> {
    let Claim { addr, secret, stopped: mut cancelled, visible, .. } = claim_of_host;
    let secret = secret.as_str();
    let video_tag = track.and_then(|(_, tag)| tag);
    // A tagged phone keeps only its own tab's lane frames (the lane changes
    // tabs without telling it when); an older phone sent no tag.
    let lane_frame = |frame: cmux_rd_core::reassembly::CompleteFrame| {
        let access_unit = Bytes::from(frame.body.access_unit);
        cmux_mobile_link::media::OutgoingFrame {
            access_unit: match video_tag {
                Some(tag) => cmux_mobile_link::media::tag::append(&access_unit, tag),
                None => access_unit,
            },
            capture_us: frame.body.t_capture_us,
        }
    };
    let stream = TcpStream::connect(addr)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("browser host: {e}")))?;
    let _ = stream.set_nodelay(true);
    let (mut host_read, mut host_write) = stream.into_split();
    // The hello, the file policy, then (a new host of a `file:` page) the page.
    let mut start = hello_frame(secret, peer);
    start.extend(guard.as_mut().and_then(PageGuard::policy_update).unwrap_or_default());
    if let Some(url) = first {
        start.extend(rb_frame(serde_json::json!({"t": "rb.navigate", "url": url})));
    }
    host_write
        .write_all(&start)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("browser host: {e}")))?;
    let mut deframer = StreamDeframer::default();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut dropped = 0u64;
    // Track mode (browser_track.rs): hostd is the main stream's viewer and
    // the page's frames ride the media lane. A newer browser channel on the
    // same link takes the lane over; this one then carries its video on
    // the channel again (the host deframer stays, so frames stay whole).
    let mut claim = track.map(|(video, _)| video.claim());
    // Every host frame is read whole: the guard reads the host's `rb.page`,
    // and track mode takes the video datagrams out.
    let mut host_deframer = StreamDeframer::default();
    let mut bridge = crate::browser_track::TrackBridge::new();
    let epoch = Instant::now();
    let now_us = || u64::try_from(epoch.elapsed().as_micros()).unwrap_or(u64::MAX);
    let mut last_report_us = 0u64;
    if claim.is_some() {
        tracing::info!("browser: video on the link's media lane");
    }
    loop {
        if claim.as_ref().is_some_and(|c| !c.owns()) {
            tracing::info!("browser: another tab took the media lane; video returns to the channel");
            claim = None;
            // The phone's own viewer starts on the channel at a keyframe.
            bridge.request_keyframe();
            let recovery = bridge.feedback(false, now_us());
            if host_write.write_all(&recovery).await.is_err() {
                return Ok(());
            }
        }
        let wake = if claim.is_some() { bridge.next_deadline_us(now_us()) } else { now_us() + 3_600_000_000 };
        let sleep = tokio::time::sleep(Duration::from_micros(wake.saturating_sub(now_us())));
        // While the lane's window is full the host's ack is held; reopen the
        // frame gate the moment it drains, not at the next wake.
        let uncongested = claim.as_ref().filter(|c| c.state().congested).map(|c| c.uncongested());
        let keyframe = async {
            match claim.as_mut() {
                // A lagged receiver missed requests: still one request.
                Some(c) => {
                    !matches!(c.keyframes.recv().await, Err(tokio::sync::broadcast::error::RecvError::Closed))
                }
                None => std::future::pending().await,
            }
        };
        let uncongested = async {
            // A lane whose sender ended stays "congested" forever; never
            // wake for it (the claim goes when its channel does).
            let drained = match uncongested {
                Some(drained) => drained.await,
                None => false,
            };
            if !drained {
                std::future::pending::<()>().await;
            }
        };
        tokio::select! {
            read = host_read.read(&mut buffer) => match read {
                Ok(0) | Err(_) => return Ok(()),
                Ok(n) => {
                    host_deframer.extend(&buffer[..n]);
                    let mut to_phone = Vec::new();
                    let mut frames = Vec::new();
                    loop {
                        match host_deframer.next_frame() {
                            Ok(Some((STREAM_DATAGRAM, payload))) => {
                                match (claim.as_ref(), cmux_rd_proto::DatagramHeader::decode(&payload)) {
                                    (Some(c), Ok((header, body))) if crate::browser_track::TrackBridge::takes(&header) => {
                                        let target = c.state().target_bps;
                                        frames.extend(bridge.on_datagram(&header, body, payload.len() + 5, target, now_us()));
                                    }
                                    _ => {
                                        let _ = encode_stream_frame(STREAM_DATAGRAM, &payload, &mut to_phone);
                                    }
                                }
                            }
                            Ok(Some((STREAM_CONTROL, payload))) => {
                                let verdict = match (guard.as_mut(), page_url(&payload)) {
                                    (Some(guard), Some((url, can_go_back))) => guard.page(&url, can_go_back).await,
                                    _ => PageVerdict::Forward,
                                };
                                if let Some(policy) = guard.as_mut().and_then(PageGuard::policy_update)
                                    && host_write.write_all(&policy).await.is_err()
                                {
                                    return Ok(());
                                }
                                match verdict {
                                    PageVerdict::Forward => {
                                        let _ = encode_stream_frame(STREAM_CONTROL, &payload, &mut to_phone);
                                    }
                                    PageVerdict::Swallow => {}
                                    PageVerdict::TakeBack { to_phone: notice, to_host } => {
                                        to_phone.extend(notice);
                                        if host_write.write_all(&to_host).await.is_err() {
                                            return Ok(());
                                        }
                                    }
                                }
                            }
                            Ok(Some((kind, payload))) => {
                                let _ = encode_stream_frame(kind, &payload, &mut to_phone);
                            }
                            Ok(None) => break,
                            Err(_) => return Err(Refusal::new("unavailable", "the browser host sent an invalid rd stream")),
                        }
                    }
                    if let Some(c) = claim.as_ref() {
                        for frame in frames {
                            if c.send(lane_frame(frame)).await.is_err() {
                                break;
                            }
                        }
                    }
                    if !to_phone.is_empty() && sender.send(Bytes::from(to_phone)).await.is_err() {
                        return Ok(());
                    }
                }
            },
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    deframer.extend(&bytes);
                    let mut out = Vec::new();
                    loop {
                        match deframer.next_frame() {
                            // In track mode hostd answers for the main stream.
                            Ok(Some((STREAM_DATAGRAM, payload)))
                                if claim.is_some() && crate::browser_track::phone_datagram_superseded(&payload) => {}
                            Ok(Some((kind, payload))) => match filter(kind, &payload) {
                                FrameVerdict::Forward => {
                                    let _ = encode_stream_frame(kind, &payload, &mut out);
                                    if kind == STREAM_CONTROL && let Some(shown) = visibility(&payload) {
                                        visible.store(shown, Ordering::SeqCst);
                                        // The tab on screen takes the lane back
                                        // from a hidden tab that opened later.
                                        if shown
                                            && claim.as_ref().is_none_or(|c| !c.owns())
                                            && let Some((video, _)) = track
                                            && !video.is_closed()
                                        {
                                            tracing::info!("browser: the shown tab takes the media lane back");
                                            claim = Some(video.claim());
                                            // A fresh viewer of the main stream,
                                            // starting at a keyframe.
                                            bridge = crate::browser_track::TrackBridge::new();
                                            let recovery = bridge.feedback(false, now_us());
                                            out.extend(recovery);
                                        }
                                    }
                                }
                                FrameVerdict::Navigate(url) => match guard.as_mut() {
                                    // A viewer with no address checks (a surface) never navigates.
                                    None => {}
                                    Some(guard) => match guard.navigate(url.trim()).await {
                                    Ok(load) => {
                                        // The host's policy first, so the page it loads may load.
                                        out.extend(guard.policy_update().unwrap_or_default());
                                        // The address as checked (trimmed; a shared file resolved), not as sent.
                                        out.extend(rb_frame(serde_json::json!({"t": "rb.navigate", "url": load})));
                                    }
                                    Err(blocked) => {
                                        tracing::info!(?blocked, "browser: refused a phone navigation");
                                        if sender.send(Bytes::from(refused_frame(&url, blocked))).await.is_err() {
                                            return Ok(());
                                        }
                                    }
                                    },
                                },
                                FrameVerdict::Drop(reason) => {
                                    dropped += 1;
                                    if dropped <= 8 {
                                        tracing::warn!(reason, "browser: dropped a phone frame");
                                    }
                                }
                            },
                            Ok(None) => break,
                            Err(_) => return Err(Refusal::new("bad_request", "not an rd stream")),
                        }
                    }
                    if !out.is_empty() && host_write.write_all(&out).await.is_err() {
                        return Ok(());
                    }
                }
                _ => return Ok(()),
            },
            requested = keyframe => {
                if requested {
                    bridge.request_keyframe();
                }
            }
            () = sleep => {}
            () = uncongested => {}
            stop = &mut cancelled => {
                return Err(match stop {
                    Ok(Stop::Evicted) => Refusal::new("evicted", "the Mac stopped this page to make room for another tab"),
                    _ => Refusal::new("replaced", "another viewer opened this tab"),
                });
            }
        }
        if let Some(c) = claim.as_ref() {
            let now = now_us();
            if now.saturating_sub(last_report_us) >= 5_000_000 {
                last_report_us = now;
                let state = c.state();
                tracing::info!(
                    frames = bridge.frames,
                    held_acks = bridge.held_acks,
                    host_datagrams = bridge.datagrams,
                    target_kbps = state.target_bps / 1000,
                    in_flight = state.in_flight_bytes,
                    congested = state.congested,
                    feedback_delay_ms = state.feedback_delay_us / 1000,
                    loss = state.loss,
                    packets = state.packets_sent,
                    nacks = state.nacks_received,
                    keyframe_requests = state.keyframe_requests,
                    "browser: media lane"
                );
            }
            for frame in bridge.tick(now) {
                let _ = c.send(lane_frame(frame)).await;
            }
            let feedback = bridge.feedback(c.state().congested, now);
            if !feedback.is_empty() && host_write.write_all(&feedback).await.is_err() {
                return Ok(());
            }
        }
    }
}

/// Supervised mode: the app starts browser hosts (its own bundled
/// `cmux-remote-browser-host`, the one its remote tabs use). hostd asks with
/// `need_browser {request, tab, url}` on stdout and the app answers on stdin
/// with `browser {request, addr, secret}` or `browser_failed`; it reports a
/// host that exited with `browser_gone {tab}`, and hostd asks it to stop one
/// with `browser_stop {tab}`.
/// The app's answer: the host's address and secret, or why it did not start.
type BrowserAnswer = Result<(String, String), String>;

pub struct BrowserBroker {
    emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>,
    /// The line that asks the app for a host (`need_browser`, `need_surface`).
    need: fn(u64, LaunchRequest) -> crate::control::Event,
    /// The line that tells the app a host is no longer needed.
    stop: fn(String) -> crate::control::Event,
    /// What the app starts, for messages ("browser", "surface").
    what: &'static str,
    next: std::sync::atomic::AtomicU64,
    pending: std::sync::Mutex<HashMap<u64, oneshot::Sender<BrowserAnswer>>>,
    alive: std::sync::Mutex<HashMap<String, Arc<std::sync::atomic::AtomicBool>>>,
}

impl BrowserBroker {
    pub fn new(emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>) -> Self {
        Self::with_lines(
            emit,
            |request, launch| crate::control::Event::NeedBrowser {
                request,
                tab: launch.tab,
                url: launch.url,
            },
            |tab| crate::control::Event::BrowserStop { tab },
            "browser",
        )
    }

    /// A broker of the app's simulator surface sources (`need_surface`,
    /// `surface_stop`; `surface.rs`).
    pub fn for_surfaces(emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>) -> Self {
        Self::with_lines(
            emit,
            |request, launch| crate::control::Event::NeedSurface { request, tab: launch.tab },
            |tab| crate::control::Event::SurfaceStop { tab },
            "surface",
        )
    }

    fn with_lines(
        emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>,
        need: fn(u64, LaunchRequest) -> crate::control::Event,
        stop: fn(String) -> crate::control::Event,
        what: &'static str,
    ) -> Self {
        Self {
            emit,
            need,
            stop,
            what,
            next: std::sync::atomic::AtomicU64::new(1),
            pending: std::sync::Mutex::default(),
            alive: std::sync::Mutex::default(),
        }
    }

    /// The app's answer to `need_browser` `request`.
    pub fn answer(&self, request: u64, result: BrowserAnswer) {
        let waiter = self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&request);
        if let Some(waiter) = waiter {
            let _ = waiter.send(result);
        }
    }

    /// The app's host for `tab` exited.
    pub fn gone(&self, tab: &str) {
        let flag = self.alive.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(tab);
        if let Some(flag) = flag {
            flag.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// A launcher that asks the app.
    pub fn launcher(self: &Arc<Self>) -> Launcher {
        let broker = Arc::clone(self);
        Arc::new(move |request: LaunchRequest| {
            let broker = Arc::clone(&broker);
            Box::pin(async move { broker.launch(request).await })
        })
    }

    async fn launch(self: Arc<Self>, request: LaunchRequest) -> Result<RunningHost, String> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(id, tx);
        (self.emit)(&(self.need)(id, request.clone()));
        let answer = tokio::time::timeout(LAUNCH_TIMEOUT + Duration::from_secs(15), rx).await;
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
        let (addr, secret) = match answer {
            Ok(Ok(result)) => result?,
            Ok(Err(_)) => return Err(format!("the app dropped the {} request", self.what)),
            Err(_) => return Err(format!("the app did not start a {} host in time", self.what)),
        };
        let addr = addr
            .parse::<SocketAddr>()
            .ok()
            .filter(|a| a.ip().is_loopback())
            .ok_or_else(|| format!("the app's {} host is not on loopback", self.what))?;
        let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
        self.alive
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(request.tab.clone(), Arc::clone(&alive));
        Ok(RunningHost {
            addr,
            secret,
            guard: Box::new(SuppliedGuard { tab: request.tab, alive, broker: Arc::clone(&self) }),
        })
    }
}

struct SuppliedGuard {
    tab: String,
    alive: Arc<std::sync::atomic::AtomicBool>,
    broker: Arc<BrowserBroker>,
}

impl HostGuard for SuppliedGuard {
    fn alive(&mut self) -> bool {
        self.alive.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl Drop for SuppliedGuard {
    fn drop(&mut self) {
        if self.alive.swap(false, std::sync::atomic::Ordering::SeqCst) {
            {
                let mut alive = self.broker.alive.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if alive.get(&self.tab).is_some_and(|flag| Arc::ptr_eq(flag, &self.alive)) {
                    alive.remove(&self.tab);
                }
            }
            (self.broker.emit)(&(self.broker.stop)(self.tab.clone()));
        }
    }
}

/// A host process: its stdin is the lifeline (the host quits at end of
/// file), and `kill_on_drop` stops it with hostd.
struct ProcessGuard {
    child: tokio::process::Child,
    _lifeline: tokio::process::ChildStdin,
    _stdout: BufReader<tokio::process::ChildStdout>,
}

impl HostGuard for ProcessGuard {
    fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

fn new_secret() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

/// Runs `exe --serve --listen 127.0.0.1:0 --lifeline --url URL` with the
/// launch contract of `cmux-remote-browser-host` (launch.rs): the secret is
/// the first stdin line, the host prints `{"listening":"ADDR"}`.
async fn launch_process(
    exe: &std::path::Path,
    cache_root: &std::path::Path,
    request: &LaunchRequest,
) -> Result<RunningHost, String> {
    let cache = cache_root.join(&request.tab);
    std::fs::create_dir_all(&cache).map_err(|e| format!("cache {}: {e}", cache.display()))?;
    let log = std::fs::File::create(cache.join("host.log")).map_err(|e| format!("host log: {e}"))?;
    let mut child = tokio::process::Command::new(exe)
        // `--use-mock-keychain` reaches Chromium through the host's argv: a host binary
        // built without the switch in rb_shim.mm (the pin e9bed2bc) otherwise waits for
        // the login Keychain's "Chromium Safe Storage" key it can never read, and every
        // http(s) load hangs on about:blank (PR #22555 smoke).
        .args([
            "--serve",
            "--listen",
            "127.0.0.1:0",
            "--lifeline",
            "--use-mock-keychain",
            "--url",
            &request.url,
        ])
        .env("CMUX_RB_CACHE_DIR", &cache)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log))
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("starting {}: {e}", exe.display()))?;
    let secret = new_secret();
    let mut lifeline = child.stdin.take().ok_or("no host stdin")?;
    lifeline.write_all(format!("{secret}\n").as_bytes()).await.map_err(|e| format!("host stdin: {e}"))?;
    let mut stdout = BufReader::new(child.stdout.take().ok_or("no host stdout")?);
    let mut line = String::new();
    let read = tokio::time::timeout(LAUNCH_TIMEOUT, stdout.read_line(&mut line))
        .await
        .map_err(|_| "the browser host did not start in time".to_owned())?;
    if !matches!(read, Ok(n) if n > 0) {
        return Err("the browser host exited before listening".into());
    }
    let addr = serde_json::from_str::<Value>(line.trim())
        .ok()
        .and_then(|v| v.get("listening").and_then(Value::as_str).and_then(|a| a.parse::<SocketAddr>().ok()))
        .filter(|a| a.ip().is_loopback())
        .ok_or_else(|| format!("unexpected host output: {}", line.trim()))?;
    Ok(RunningHost {
        addr,
        secret,
        guard: Box::new(ProcessGuard { child, _lifeline: lifeline, _stdout: stdout }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control(value: Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    fn rb(body: Value) -> Vec<u8> {
        control(serde_json::json!({"t": "service", "service": "rb/1", "body": body}))
    }

    #[test]
    fn viewer_messages_pass_and_host_ones_do_not() {
        assert_eq!(filter_frame(STREAM_DATAGRAM, &[0x10, 4]), FrameVerdict::Forward);
        for body in [
            serde_json::json!({"t": "rb.screen", "seq": 1, "screen": {}}),
            serde_json::json!({"t": "rb.history", "op": "back"}),
        ] {
            assert_eq!(filter_frame(STREAM_CONTROL, &rb(body)), FrameVerdict::Forward);
        }
        // Every rb.navigate waits for the address check (browser_policy), whatever its scheme.
        for url in ["https://example.com/a", "about:blank", "file:///etc/passwd", "javascript:alert(1)"] {
            assert_eq!(
                filter_frame(STREAM_CONTROL, &rb(serde_json::json!({"t": "rb.navigate", "url": url}))),
                FrameVerdict::Navigate(url.into())
            );
        }
        assert_eq!(
            filter_frame(STREAM_CONTROL, &control(serde_json::json!({"t": "stop"}))),
            FrameVerdict::Forward
        );
        for (frame, kind) in [
            (rb(serde_json::json!({"t": "rb.navigate"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.page", "url": "x"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.clipboard.push", "seq": 1, "items": []})), STREAM_CONTROL),
            (
                control(serde_json::json!({"t": "service", "service": "desktop", "body": {"t": "rb.open"}})),
                STREAM_CONTROL,
            ),
            (control(serde_json::json!({"t": "hello", "token": "00"})), STREAM_CONTROL),
            (control(serde_json::json!({"t": "start", "key": "k", "mode": "m"})), STREAM_CONTROL),
            (b"not json".to_vec(), STREAM_CONTROL),
            (vec![0; 16], cmux_rd_proto::STREAM_BULK),
        ] {
            assert!(
                matches!(filter_frame(kind, &frame), FrameVerdict::Drop(_)),
                "{}",
                String::from_utf8_lossy(&frame)
            );
        }
    }

    #[tokio::test]
    async fn the_broker_asks_the_app_and_tells_it_to_stop() {
        let events = Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = Arc::clone(&events);
        let broker = Arc::new(BrowserBroker::new(Arc::new(move |event: &crate::control::Event| {
            seen.lock().unwrap().push(serde_json::to_value(event).unwrap());
        })));
        let launch = broker.launcher();
        let pending =
            tokio::spawn(launch(LaunchRequest { tab: "s4".into(), url: "https://example.com".into() }));
        while events.lock().unwrap().is_empty() {
            tokio::task::yield_now().await;
        }
        let asked = events.lock().unwrap()[0].clone();
        assert_eq!(asked["type"], "need_browser");
        assert_eq!(asked["tab"], "s4");
        let request = asked["request"].as_u64().unwrap();
        broker.answer(request, Ok(("127.0.0.1:4100".into(), "secret".into())));
        let mut host = pending.await.unwrap().unwrap();
        assert_eq!(host.addr.port(), 4100);
        assert!(host.guard.alive());
        broker.gone("s4");
        assert!(!host.guard.alive());
        drop(host);
        // Already gone: no stop request.
        assert_eq!(events.lock().unwrap().len(), 1);

        let pending = tokio::spawn(launch(LaunchRequest { tab: "s5".into(), url: "about:blank".into() }));
        while events.lock().unwrap().len() < 2 {
            tokio::task::yield_now().await;
        }
        let request = events.lock().unwrap()[1]["request"].as_u64().unwrap();
        broker.answer(request, Ok(("10.0.0.1:4100".into(), "secret".into())));
        assert!(pending.await.unwrap().is_err(), "a non-loopback host is refused");

        let pending = tokio::spawn(launch(LaunchRequest { tab: "s6".into(), url: "about:blank".into() }));
        while events.lock().unwrap().len() < 3 {
            tokio::task::yield_now().await;
        }
        let request = events.lock().unwrap()[2]["request"].as_u64().unwrap();
        broker.answer(request, Ok(("127.0.0.1:4101".into(), "secret".into())));
        drop(pending.await.unwrap().unwrap());
        let stop = events.lock().unwrap()[3].clone();
        assert_eq!(stop, serde_json::json!({"type": "browser_stop", "tab": "s6"}));
    }

    struct Alive;
    impl HostGuard for Alive {
        fn alive(&mut self) -> bool {
            true
        }
    }

    fn fake_launcher() -> Launcher {
        Arc::new(|_request: LaunchRequest| {
            Box::pin(async {
                Ok(RunningHost {
                    addr: "127.0.0.1:9".parse().unwrap(),
                    secret: "s".into(),
                    guard: Box::new(Alive),
                })
            })
        })
    }

    /// transport-verify-20261019.md defect 7: the host limit stopped the
    /// shown tab's page. A host the phone shows is stopped last, and its
    /// viewer hears `evicted` (the page reopens), not `replaced`.
    #[tokio::test]
    async fn the_host_limit_stops_a_hidden_tab_before_the_shown_one() {
        let config = BrowserConfig::new(Some(fake_launcher()), 2);
        let shown = config.claim("s1", "about:blank").await.unwrap();
        let mut hidden = config.claim("s2", "about:blank").await.unwrap();
        // s2 opened last (it was used more recently), but the phone hides it.
        hidden.visible.store(false, std::sync::atomic::Ordering::SeqCst);
        let _third = config.claim("s3", "about:blank").await.unwrap();
        assert_eq!(config.running_tabs().await, vec!["s1".to_owned(), "s3".to_owned()]);
        assert_eq!(hidden.stopped.try_recv(), Ok(Stop::Evicted));
        drop(shown);
    }

    #[tokio::test]
    async fn a_second_viewer_of_a_tab_replaces_the_first() {
        let config = BrowserConfig::new(Some(fake_launcher()), 2);
        let mut first = config.claim("s1", "about:blank").await.unwrap();
        let _second = config.claim("s1", "about:blank").await.unwrap();
        assert_eq!(first.stopped.try_recv(), Ok(Stop::Replaced));
    }

    #[test]
    fn the_phone_says_which_tab_is_shown() {
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.visibility", "visible": true}))), Some(true));
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.visibility", "visible": false}))), Some(false));
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.screen", "visible": true}))), None);
        assert_eq!(visibility(b"not json"), None);
    }

    #[test]
    fn tabs_and_urls() {
        assert!(valid_tab("s12"));
        assert!(valid_tab("t-abc_1.x"));
        assert!(!valid_tab("../x"));
        assert!(!valid_tab(".x"));
        assert!(!valid_tab(""));
        assert!(!valid_tab("a/b"));
    }

    struct NoMac(std::sync::atomic::AtomicUsize);
    impl crate::browser_policy::MacPages for NoMac {
        fn view(&self) -> BoxFuture<'_, crate::browser_policy::MacView> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { crate::browser_policy::MacView::default() })
        }
    }

    fn rb_body(frame: &[u8]) -> Value {
        let mut deframer = StreamDeframer::default();
        deframer.extend(frame);
        let (kind, payload) = deframer.next_frame().unwrap().unwrap();
        assert_eq!(kind, STREAM_CONTROL);
        let control: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(control["service"], "rb/1");
        control["body"].clone()
    }

    #[tokio::test]
    async fn a_page_the_phone_may_not_load_is_taken_back() {
        let mac = NoMac(Default::default());
        let mut guard = PageGuard::new(&mac, Some("file:///Users/me/opened-by-mac.html".into()));
        // The page the Mac opened, then the web: shown.
        assert!(matches!(
            guard.page("file:///Users/me/opened-by-mac.html", false).await,
            PageVerdict::Forward
        ));
        assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        // A link out to a file that is not shared: swallowed, the phone told, the host sent back.
        let PageVerdict::TakeBack { to_phone, to_host } =
            guard.page("file:///Users/me/.ssh/id_ed25519", true).await
        else {
            panic!("not taken back")
        };
        let notice = rb_body(&to_phone);
        assert_eq!(notice["t"], "rb.navigate.refused");
        assert_eq!(notice["url"], "file:///Users/me/.ssh/id_ed25519");
        assert_eq!(notice["reason"], "This file isn't in a folder this Mac shares with your iPhone.");
        assert_eq!(notice["code"], "file_not_shared");
        assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.history", "op": "back"}));
        // Its later facts (title, loading) are swallowed too, then the page it went back to shows.
        assert!(matches!(guard.page("file:///Users/me/.ssh/id_ed25519", true).await, PageVerdict::Swallow));
        assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        // The same link followed again is taken back again, not swallowed.
        assert!(matches!(
            guard.page("file:///Users/me/.ssh/id_ed25519", true).await,
            PageVerdict::TakeBack { .. }
        ));
        assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        // With no history (the page replaced itself), the host goes to the last shown page.
        let PageVerdict::TakeBack { to_host, .. } = guard.page("chrome://settings", false).await else {
            panic!("not taken back")
        };
        assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.navigate", "url": "https://example.com/"}));
        // A page that keeps bouncing back to the shown page: the fourth take-back in a
        // row stops on the blank page.
        assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        let PageVerdict::TakeBack { to_host, .. } = guard.page("chrome://settings", true).await else {
            panic!("not taken back")
        };
        assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.navigate", "url": "about:blank"}));
        // A redirecting page (a new allowed page that did not stay) does not reset it.
        assert!(matches!(guard.page("https://redirect.example/", true).await, PageVerdict::Forward));
        let PageVerdict::TakeBack { to_host, .. } = guard.page("chrome://flags", true).await else {
            panic!("not taken back")
        };
        assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.navigate", "url": "about:blank"}));
        // Browsing on from a page that stayed starts the count again.
        guard.shown_at = guard.shown_at.map(|at| at - SETTLED);
        assert!(matches!(guard.page("https://example.org/", true).await, PageVerdict::Forward));
        let PageVerdict::TakeBack { to_host, .. } = guard.page("chrome://flags", true).await else {
            panic!("not taken back")
        };
        assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.history", "op": "back"}));
        // Web pages never ask the Mac.
        let before = mac.0.load(Ordering::SeqCst);
        assert!(guard.navigate("https://cmux.com/").await.is_ok());
        assert_eq!(mac.0.load(Ordering::SeqCst), before);
    }

    #[tokio::test]
    async fn refused_links_on_a_page_that_stays_never_blank_it() {
        let mac = NoMac(Default::default());
        let mut guard = PageGuard::new(&mac, None);
        assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        for i in 0..(MAX_TAKE_BACKS + 3) {
            // The person reads the page a while, then taps a refused link.
            guard.shown_at = guard.shown_at.map(|at| at - SETTLED);
            let PageVerdict::TakeBack { to_host, .. } = guard.page(&format!("chrome://link-{i}"), true).await
            else {
                panic!("not taken back")
            };
            assert_eq!(rb_body(&to_host), serde_json::json!({"t": "rb.history", "op": "back"}), "link {i}");
            assert!(matches!(guard.page("https://example.com/", true).await, PageVerdict::Forward));
        }
    }

    #[test]
    fn the_hosts_file_policy_names_the_shared_folders_and_the_macs_pages() {
        let base = tempfile::tempdir().unwrap();
        let home = std::fs::canonicalize(base.path()).unwrap().join("home");
        let shared = home.join("work");
        let downloads = home.join("Downloads");
        for dir in [&shared, &downloads] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(downloads.join("mac page.html"), "x").unwrap();
        let view = crate::browser_policy::MacView { roots: vec![shared.clone()], browser_urls: vec![] };
        let approved = vec![
            crate::browser_policy::file_url(&downloads.join("mac page.html")),
            "chrome://version/".to_owned(),
        ];
        let body = file_policy(&view, &approved);
        assert_eq!(body["t"], "rb.file_policy");
        // The Mac's page is one file; its folder (Downloads) is never a root.
        assert_eq!(body["roots"], serde_json::json!([shared]));
        assert_eq!(body["files"], serde_json::json!([downloads.join("mac page.html")]));
    }

    #[tokio::test]
    async fn the_policy_is_sent_once_and_again_when_it_changes() {
        let mac = NoMac(Default::default());
        let mut guard = PageGuard::new(&mac, None);
        guard.refresh_view().await;
        let first = guard.policy_update().expect("first policy");
        assert_eq!(rb_body(&first)["t"], "rb.file_policy");
        assert!(guard.policy_update().is_none());
        guard.approve("file:///");
        assert!(guard.policy_update().is_some());
    }

    #[tokio::test]
    async fn checks_share_one_read_of_the_mac_per_burst() {
        let mac = NoMac(Default::default());
        let mut guard = PageGuard::new(&mac, None);
        assert!(guard.navigate("chrome://a").await.is_err());
        assert!(guard.navigate("file:///b").await.is_err());
        assert_eq!(mac.0.load(Ordering::SeqCst), 1);
        // An old read is read again.
        if let Some((at, _)) = guard.view.as_mut() {
            *at -= VIEW_TTL;
        }
        assert!(guard.navigate("chrome://c").await.is_err());
        assert_eq!(mac.0.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn the_open_address_stays_approved() {
        let mac = NoMac(Default::default());
        let opened = "file:///Users/me/opened-by-mac.html";
        let mut guard = PageGuard::new(&mac, Some(opened.into()));
        for i in 0..(MAX_APPROVED + 5) {
            guard.approve(&format!("chrome://page-{i}"));
        }
        assert_eq!(guard.approved.len(), MAX_APPROVED);
        assert_eq!(guard.approved[0], opened);
        assert!(guard.navigate(opened).await.is_ok());
        // A shared file is not remembered: with no folder shared it no longer loads.
        assert!(guard.navigate("file:///Users/me/was-shared.html").await.is_err());
    }

    #[test]
    fn host_pages_are_read() {
        let page =
            rb(serde_json::json!({"t": "rb.page", "url": "https://a.b/", "title": "", "loading": false,
                                          "can_go_back": true, "can_go_forward": false}));
        assert_eq!(page_url(&page), Some(("https://a.b/".into(), true)));
        assert_eq!(page_url(&rb(serde_json::json!({"t": "rb.title", "url": "x"}))), None);
        assert_eq!(page_url(b"nope"), None);
    }

    #[test]
    fn hello_carries_the_secret_and_the_rb_service() {
        let frame = hello_frame(
            "ab".repeat(32).as_str(),
            &Peer { device_id: "phone".into(), session_id: "s".into(), video: None },
        );
        let mut deframer = StreamDeframer::default();
        deframer.extend(&frame);
        let (kind, payload) = deframer.next_frame().unwrap().unwrap();
        assert_eq!(kind, STREAM_CONTROL);
        let value: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(value["t"], "hello");
        assert_eq!(value["service"], "rb/1");
        assert_eq!(value["token"], "ab".repeat(32));
        assert_eq!(value["caps"][0], INPUT_SERVICE);
    }
}
