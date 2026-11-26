//! The relay feed: what keeps this Mac's chat state on the relay cache while the Mac sleeps
//! (RFD 0142 R2 and R9). Off unless `LINK_RELAY_CACHE=on` ([`enabled`]); nothing here replaces
//! the link, which stays the source of truth.
//!
//! It reads each surface through the same `catch-up` answer a phone gets
//! ([`crate::catch_up::answer_args`], under the host's session exposure), so the plaintext of every
//! sealed delta is exactly what a `catch-up` reply carries for that surface
//! (`cmux-mobile-core` `catch_up::relay`):
//!
//! - `workspaces`: the reply's `workspaces` object;
//! - `chat-list`: the reply's `chatList` object (a `_acpmux/watch` follow from the last
//!   `listEpoch`/`listSeq` it published; its snapshot is the whole list);
//! - `chat/<sessionId>`: one entry of the reply's `chats` (an attach page with its `sessionId`),
//!   first the newest screenful, then forward from the last seq it published.
//!
//! One read per window ([`FeedTiming::window`]) is one delta per changed surface, so a busy chat
//! stays well inside the relay's 512 deltas a slot. Each delta is one JSON object, never framed by
//! [`crate::relay_publish::Coalescer`]: the phone decodes a delta as one `catch-up` surface.
//! Changes come from the feed's own `_acpmux/watch` (a notification naming a session marks that
//! chat and the list), and the workspaces are read again every [`FeedTiming::workspaces_every`].
//! A snapshot and its first screen ([`crate::relay_publish::RelayPublisher::publish_first_screen`])
//! follow a surface's first delta, every [`FeedTiming::snapshot_every`], after a publish some phone
//! did not get, and once [`SNAPSHOT_AFTER_DELTAS`] deltas pile up since the last one.
//!
//! Sealed with the Mac's identity key ([`crate::pairing::MacIdentity::relay_key`]), which each phone
//! pinned, to each paired phone's push key ([`crate::relay_publish::viewers`]). Every phone gets the
//! same content: the host's exposure filter is Mac-wide. A new identity, a new set of phones or a
//! new hostd starts a new epoch, so each phone opens a snapshot first.
//!
//! [`RelayHeads`] is where each surface stands; a `catch-up` reply carries it as `relay`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::relay_cache::{FIRST_SCREEN_BYTES, RelayCache, RelayCacheConfig, first_screen_stream};
use cmux_relay_snapshot::delta::delta_stream;
use cmux_relay_snapshot::{MAX_PLAINTEXT, Position};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;

use crate::auth::Tokens;
use crate::config::{AcpmuxTarget, ServiceConfig};
use crate::control::SessionExposure;
use crate::relay_publish::{Published, RelayPublishConfig, RelayPublisher, Viewer};
use crate::services::Peer;

/// The environment switch: `LINK_RELAY_CACHE=on` turns the feed on. Anything else is off.
pub const ENV: &str = "LINK_RELAY_CACHE";
/// The workspace tree's surface.
pub const WORKSPACES: &str = "workspaces";
/// The chat list's surface.
pub const CHAT_LIST: &str = "chat-list";
/// A surface's deltas since its last snapshot that call for a new one: half the relay's 512, so a
/// phone away for long lands on a snapshot, not a log that wrapped.
pub const SNAPSHOT_AFTER_DELTAS: u32 = 256;
/// The chats the feed follows: the newest of the list, then any a notification names.
pub const MAX_CHATS: usize = 32;
/// One read's budget: every chat page fits one delta's plaintext with room to spare.
const BUDGET_BYTES: u64 = (MAX_PLAINTEXT as u64) * 3 / 4;
/// The relay's longest stream name (its `valid_stream`).
const MAX_STREAM: usize = 96;
/// The feed's own device id towards acpmux: no phone credential, the dashboard's rules.
const FEED_DEVICE: &str = "relay-feed";

/// `chat/<sessionId>`: a chat's surface.
pub fn chat_surface(session: &str) -> String {
    format!("chat/{session}")
}

/// Whether the feed runs: `LINK_RELAY_CACHE=on`.
pub fn enabled() -> bool {
    enabled_in(|name| std::env::var(name).ok())
}

/// [`enabled`] over `var` (an environment lookup).
pub fn enabled_in(var: impl Fn(&str) -> Option<String>) -> bool {
    var(ENV).is_some_and(|value| value.trim().eq_ignore_ascii_case("on"))
}

/// Whether the relay takes `surface` with its `/first` and `/delta` streams.
fn valid_surface(surface: &str) -> bool {
    let longest = first_screen_stream(surface).len().max(delta_stream(surface).len());
    !surface.is_empty()
        && longest <= MAX_STREAM
        && surface.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-'))
}

/// Where each surface stands on the relay: the position of its newest delta, or of its snapshot
/// when it has none yet. Only surfaces this hostd published; empty while the feed is off.
#[derive(Debug, Default)]
pub struct RelayHeads {
    heads: Mutex<HashMap<String, Position>>,
}

impl RelayHeads {
    /// Every surface's head now.
    pub fn now(&self) -> HashMap<String, Position> {
        self.heads.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn set(&self, surface: &str, position: Position) {
        self.heads.lock().unwrap_or_else(PoisonError::into_inner).insert(surface.to_owned(), position);
    }

    fn clear(&self) {
        self.heads.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }
}

/// How often the feed reads and snapshots.
#[derive(Debug, Clone, Copy)]
pub struct FeedTiming {
    /// Changes within one window go out as one delta per surface.
    pub window: Duration,
    /// A surface's snapshot is put again at least this often while it changes.
    pub snapshot_every: Duration,
    /// The workspace tree is read at least this often (the daemon sends no change notice here).
    pub workspaces_every: Duration,
}

impl Default for FeedTiming {
    fn default() -> Self {
        Self {
            window: Duration::from_secs(2),
            snapshot_every: Duration::from_secs(300),
            workspaces_every: Duration::from_secs(60),
        }
    }
}

/// What one surface last published.
#[derive(Debug, Default)]
struct Surface {
    /// The last delta's plaintext: the same object again is not published.
    last: Option<Value>,
    deltas_since_snapshot: u32,
    snapshot_at: Option<Instant>,
    /// A phone did not get a publish since the last snapshot: its log has a gap.
    missed: bool,
}

/// What one flush did.
#[derive(Debug, Default)]
pub struct Flushed {
    pub deltas: usize,
    pub snapshots: usize,
    pub first_screens: usize,
    /// Surfaces read but not published (too large, a name the relay refuses), with why.
    pub skipped: Vec<(String, String)>,
    /// The read failed (acpmux and the daemon unreachable, exposure unavailable).
    pub error: Option<String>,
    /// The first publish refusal.
    pub refused: Option<String>,
}

/// The feed's state for one publisher (one epoch).
pub struct Feed {
    services: Arc<ServiceConfig>,
    peer: Peer,
    publisher: Arc<RelayPublisher>,
    heads: Arc<RelayHeads>,
    surfaces: HashMap<String, Surface>,
    /// Followed chats, newest first.
    chats: Vec<String>,
    /// The last seq published per chat.
    cursors: HashMap<String, u64>,
    /// The chat list's `listEpoch` and `listSeq` last published.
    list_cursor: Option<(String, u64)>,
    dirty: HashSet<String>,
    list_dirty: bool,
    read_at: Option<Instant>,
}

impl Feed {
    /// A feed from nothing published: its first flush reads every surface. Clears `heads`.
    pub fn new(
        services: Arc<ServiceConfig>,
        session_exposure: Option<watch::Receiver<SessionExposure>>,
        publisher: Arc<RelayPublisher>,
        heads: Arc<RelayHeads>,
    ) -> Self {
        heads.clear();
        let peer = Peer {
            device_id: FEED_DEVICE.into(),
            session_id: FEED_DEVICE.into(),
            video: None,
            session_exposure,
            route: None,
            path: None,
            viewport: None,
        };
        Self {
            services,
            peer,
            publisher,
            heads,
            surfaces: HashMap::new(),
            chats: Vec::new(),
            cursors: HashMap::new(),
            list_cursor: None,
            dirty: HashSet::new(),
            list_dirty: true,
            read_at: None,
        }
    }

    pub fn publisher(&self) -> &Arc<RelayPublisher> {
        &self.publisher
    }

    /// Something changed: the list, and `session`'s chat when one is named.
    pub fn changed(&mut self, session: Option<&str>) {
        self.list_dirty = true;
        if let Some(session) = session {
            self.follow(session);
            self.dirty.insert(session.to_owned());
        }
    }

    /// Follows `session` as the newest chat; the oldest followed past [`MAX_CHATS`] is dropped.
    fn follow(&mut self, session: &str) {
        if !valid_surface(&chat_surface(session)) {
            return;
        }
        self.chats.retain(|known| known != session);
        self.chats.insert(0, session.to_owned());
        for gone in self.chats.split_off(self.chats.len().min(MAX_CHATS)) {
            self.dirty.remove(&gone);
            self.cursors.remove(&gone);
        }
    }

    /// Whether a flush now would read anything.
    pub fn wants_flush(&self, now: Instant, timing: &FeedTiming) -> bool {
        self.list_dirty
            || !self.dirty.is_empty()
            || self.read_at.is_none_or(|at| now.duration_since(at) >= timing.workspaces_every)
            || self.surfaces.values().any(|surface| snapshot_due(surface, now, timing))
    }

    /// Reads what changed and publishes it to `viewers`: one delta per changed surface, then the
    /// snapshots due. Nothing at all when the publisher is off or no phone is paired.
    pub async fn flush(&mut self, viewers: &[Viewer], now: Instant, timing: &FeedTiming) -> Flushed {
        let mut flushed = Flushed::default();
        if !self.publisher.enabled() || viewers.is_empty() {
            return flushed;
        }
        let asked: Vec<String> =
            self.chats.iter().filter(|chat| self.dirty.contains(*chat)).cloned().collect();
        let chats: Vec<Value> = asked
            .iter()
            .map(|session| match self.cursors.get(session) {
                Some(seq) => json!({"sessionId": session, "lastSeq": seq, "first": "forward"}),
                None => json!({"sessionId": session, "first": "screenful"}),
            })
            .collect();
        let mut args = json!({"v": 1, "wake": "background", "budgetBytes": BUDGET_BYTES, "chats": chats});
        if let Some((epoch, seq)) = &self.list_cursor {
            args["chatList"] = json!({"listEpoch": epoch, "afterSeq": seq});
        }
        let reply = match crate::catch_up::answer_args(&self.services, &self.peer, &args).await {
            Ok(reply) => reply,
            Err(refusal) => {
                flushed.error = Some(refusal.reason);
                return flushed;
            }
        };
        self.read_at = Some(now);
        let cut: HashSet<&str> = reply
            .get("cut")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();

        if let Some(tree) = reply.get("workspaces") {
            self.delta(viewers, WORKSPACES, tree, &mut flushed).await;
        }
        if let Some(list) = reply.get("chatList") {
            self.list_dirty = false;
            let sessions = list.get("sessions").and_then(Value::as_array).into_iter().flatten();
            let listed: Vec<String> = sessions
                .filter_map(|row| row.get("sessionId").and_then(Value::as_str).map(str::to_owned))
                .collect();
            // The list is newest first: follow its first rows, oldest of them first. Only a list
            // that changed marks its rows: an unchanged one costs no attach.
            let changed = self.surfaces.get(CHAT_LIST).and_then(|s| s.last.as_ref()) != Some(list);
            for session in listed.iter().take(MAX_CHATS).rev().filter(|_| changed) {
                self.follow(session);
                self.dirty.insert(session.clone());
            }
            let epoch = list.get("listEpoch").and_then(Value::as_str);
            let seq = list.get("listSeq").and_then(Value::as_u64);
            if let (Some(epoch), Some(seq)) = (epoch, seq) {
                self.list_cursor = Some((epoch.to_owned(), seq));
            }
            self.delta(viewers, CHAT_LIST, list, &mut flushed).await;
        }

        let entries = reply.get("chats").and_then(Value::as_array).cloned().unwrap_or_default();
        let mut answered = HashSet::new();
        for entry in &entries {
            let Some(session) = entry.get("sessionId").and_then(Value::as_str) else { continue };
            answered.insert(session.to_owned());
            self.dirty.remove(session);
            let events = entry.get("events").and_then(Value::as_array);
            let newest = events.and_then(|events| events.iter().filter_map(|e| e.get("seq")?.as_u64()).max());
            let through = entry.get("pageThrough").and_then(Value::as_u64).or(newest);
            let had = self.cursors.get(session).copied();
            if let Some(through) = through {
                self.cursors.insert(session.to_owned(), had.unwrap_or(0).max(through));
            } else {
                self.cursors.entry(session.to_owned()).or_insert(0);
            }
            if had.is_some() && events.is_none_or(Vec::is_empty) {
                continue;
            }
            if had.is_some() && entry.get("hasMore").and_then(Value::as_bool) == Some(true) {
                // Forward and more behind it: the rest next window.
                self.dirty.insert(session.to_owned());
            }
            self.delta(viewers, &chat_surface(session), entry, &mut flushed).await;
        }
        // Asked, not cut and not answered: refused (not exposed, gone). Not followed any more.
        for session in &asked {
            if !answered.contains(session) && !cut.contains(format!("chats:{session}").as_str()) {
                self.dirty.remove(session);
                self.chats.retain(|known| known != session);
                self.cursors.remove(session);
            }
        }

        self.snapshots(viewers, now, timing, &mut flushed).await;
        flushed
    }

    /// Publishes `value` as `surface`'s next delta unless it is the same as the last.
    async fn delta(&mut self, viewers: &[Viewer], surface: &str, value: &Value, flushed: &mut Flushed) {
        if !valid_surface(surface) {
            flushed.skipped.push((surface.to_owned(), "name".into()));
            return;
        }
        let state = self.surfaces.entry(surface.to_owned()).or_default();
        if state.last.as_ref() == Some(value) {
            return;
        }
        let Ok(bytes) = serde_json::to_vec(value) else { return };
        if bytes.len() > MAX_PLAINTEXT {
            // The phone gets it from the Mac; the next snapshot that fits carries it.
            flushed.skipped.push((surface.to_owned(), format!("{} bytes", bytes.len())));
            state.missed = true;
            return;
        }
        let published = self.publisher.publish_delta(viewers, surface, &bytes).await;
        state.last = Some(value.clone());
        state.deltas_since_snapshot += 1;
        note(flushed, &published, &mut state.missed);
        flushed.deltas += 1;
        if let Some(position) = published.position {
            self.heads.set(surface, position);
        }
    }

    /// Puts a snapshot and its first screen for every surface due one, from one fresh read.
    async fn snapshots(
        &mut self,
        viewers: &[Viewer],
        now: Instant,
        timing: &FeedTiming,
        flushed: &mut Flushed,
    ) {
        let due: Vec<String> = self
            .surfaces
            .iter()
            .filter(|(_, surface)| surface.last.is_some() && snapshot_due(surface, now, timing))
            .map(|(name, _)| name.clone())
            .collect();
        if due.is_empty() {
            return;
        }
        let chats: Vec<Value> = due
            .iter()
            .filter_map(|surface| surface.strip_prefix("chat/"))
            .take(crate::catch_up::MAX_CHATS)
            .map(|session| json!({"sessionId": session, "first": "screenful"}))
            .collect();
        // The whole list (no cursor) and each due chat's newest screenful, read after every delta
        // above: at least as new as the position each snapshot is put at.
        let args = json!({"v": 1, "wake": "background", "budgetBytes": BUDGET_BYTES, "chats": chats});
        let reply = match crate::catch_up::answer_args(&self.services, &self.peer, &args).await {
            Ok(reply) => reply,
            Err(refusal) => {
                flushed.error.get_or_insert(refusal.reason);
                return;
            }
        };
        let mut states: Vec<(String, Value)> = Vec::new();
        for surface in &due {
            let value = match surface.as_str() {
                WORKSPACES => reply.get("workspaces").cloned(),
                CHAT_LIST => reply.get("chatList").cloned(),
                chat => {
                    let session = chat.strip_prefix("chat/").unwrap_or_default();
                    reply
                        .get("chats")
                        .and_then(Value::as_array)
                        .and_then(|entries| {
                            entries
                                .iter()
                                .find(|e| e.get("sessionId").and_then(Value::as_str) == Some(session))
                        })
                        .cloned()
                }
            };
            if let Some(value) = value {
                states.push((surface.clone(), value));
            }
        }
        for (surface, value) in states {
            let Ok(bytes) = serde_json::to_vec(&value) else { continue };
            if bytes.len() > MAX_PLAINTEXT {
                flushed.skipped.push((surface.clone(), format!("snapshot {} bytes", bytes.len())));
                // Not again before the next is due: the phone gets this one from the Mac.
                let state = self.surfaces.entry(surface.clone()).or_default();
                state.missed = false;
                state.deltas_since_snapshot = 0;
                state.snapshot_at = Some(now);
                continue;
            }
            let published = self.publisher.publish_snapshot(viewers, &surface, &bytes).await;
            let state = self.surfaces.entry(surface.clone()).or_default();
            state.missed = false;
            note(flushed, &published, &mut state.missed);
            state.deltas_since_snapshot = 0;
            state.snapshot_at = Some(now);
            flushed.snapshots += 1;
            if let Some(screen) = first_screen(&surface, &value) {
                let published = self.publisher.publish_first_screen(viewers, &surface, &screen).await;
                let mut missed = false;
                note(flushed, &published, &mut missed);
                flushed.first_screens += 1;
            }
        }
    }
}

fn note(flushed: &mut Flushed, published: &Published, missed: &mut bool) {
    if published.failed > 0 {
        *missed = true;
        if flushed.refused.is_none() {
            flushed.refused.clone_from(&published.first_error);
        }
    }
}

fn snapshot_due(surface: &Surface, now: Instant, timing: &FeedTiming) -> bool {
    surface.last.is_some()
        && (surface.missed
            || surface.deltas_since_snapshot >= SNAPSHOT_AFTER_DELTAS
            || surface.snapshot_at.is_none_or(|at| {
                surface.deltas_since_snapshot > 0 && now.duration_since(at) >= timing.snapshot_every
            }))
}

/// What a cold open shows first, at most [`FIRST_SCREEN_BYTES`]: the whole state when it fits,
/// else a chat's newest events (with `hasMore` and `olderBefore`, as a screenful page says) or the
/// list's first rows. `None` when not even that fits (the phone opens the whole snapshot).
pub fn first_screen(surface: &str, value: &Value) -> Option<Vec<u8>> {
    let whole = serde_json::to_vec(value).ok()?;
    if whole.len() <= FIRST_SCREEN_BYTES {
        return Some(whole);
    }
    let (key, newest_last) = match surface {
        CHAT_LIST => ("sessions", false),
        _ if surface.starts_with("chat/") => ("events", true),
        _ => return None,
    };
    let rows = value.get(key)?.as_array()?;
    let mut trimmed = value.clone();
    trimmed[key] = json!([]);
    // Room for the fields a trimmed chat page gains.
    let mut used = serde_json::to_vec(&trimmed).ok()?.len() + 64;
    let order: Box<dyn Iterator<Item = &Value>> =
        if newest_last { Box::new(rows.iter().rev()) } else { Box::new(rows.iter()) };
    let mut kept = Vec::new();
    for row in order {
        let size = serde_json::to_vec(row).ok()?.len() + 1;
        if used + size > FIRST_SCREEN_BYTES {
            break;
        }
        used += size;
        kept.push(row.clone());
    }
    if kept.is_empty() {
        return None;
    }
    if newest_last {
        kept.reverse();
        if let Some(seq) = kept.first().and_then(|e| e.get("seq")).and_then(Value::as_u64) {
            trimmed["olderBefore"] = json!(seq);
        }
        trimmed["hasMore"] = json!(true);
    }
    trimmed[key] = Value::Array(kept);
    let bytes = serde_json::to_vec(&trimmed).ok()?;
    (bytes.len() <= FIRST_SCREEN_BYTES).then_some(bytes)
}

/// The feed for a running hostd, until it is dropped: waits for the app's identity key, follows
/// acpmux on its own watch connection, and flushes every window with a fresh access token.
pub async fn run(
    services: Arc<ServiceConfig>,
    base_url: String,
    build_space: Option<cmux_mobile_link::BuildSpace>,
    device_id: String,
    tokens: Arc<Tokens>,
    session_exposure: Option<watch::Receiver<SessionExposure>>,
    timing: FeedTiming,
) {
    let Some(pairing) = services.pairing.clone() else { return };
    let (changes, mut changed) = mpsc::unbounded_channel();
    let _watcher =
        Aborts(tokio::spawn(follow_acpmux(services.acpmux.clone(), session_exposure.clone(), changes)));
    let mut feed: Option<(Feed, String, Vec<String>)> = None;
    let mut last_epoch = 0u64;
    let mut tick = tokio::time::interval(timing.window);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let mut seen = Vec::new();
        while let Ok(change) = changed.try_recv() {
            seen.push(change);
        }
        let identity = pairing.identity.borrow().clone();
        let Some(identity) = identity else {
            feed = None;
            pairing.relay_heads.clear();
            continue;
        };
        let trust = pairing.trust.borrow().clone().unwrap_or_default();
        let viewers = crate::relay_publish::viewers(&pairing.push_keys, &trust);
        let mut devices: Vec<String> = viewers.iter().map(|v| v.device.clone()).collect();
        devices.sort();
        let current =
            feed.as_ref().is_some_and(|(_, key, known)| key == identity.public_key() && *known == devices);
        if !current {
            // A new history: each phone opens a snapshot before it applies a delta of it.
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64);
            last_epoch = now_ms.max(last_epoch + 1);
            let cache =
                RelayCache::new(ApiClient::new(&base_url, ""), &device_id, RelayCacheConfig::default());
            let publisher = Arc::new(RelayPublisher::new(
                cache,
                identity.relay_key().clone(),
                last_epoch,
                RelayPublishConfig { enabled: true },
            ));
            let fresh = Feed::new(
                Arc::clone(&services),
                session_exposure.clone(),
                publisher,
                Arc::clone(&pairing.relay_heads),
            );
            feed = Some((fresh, identity.public_key().to_owned(), devices));
        }
        let Some((feed, _, _)) = feed.as_mut() else { continue };
        for change in seen {
            feed.changed(change.as_deref());
        }
        if viewers.is_empty() || !feed.wants_flush(Instant::now(), &timing) {
            continue;
        }
        let token = match tokens.access_token().await {
            Ok(token) => token,
            Err(error) => {
                tracing::debug!("relay feed: no access token: {error:#}");
                continue;
            }
        };
        let api = ApiClient::new(&base_url, &token).with_build_space(build_space.clone());
        feed.publisher().set_cache(RelayCache::new(api, &device_id, RelayCacheConfig { enabled: true }));
        let flushed = feed.flush(&viewers, Instant::now(), &timing).await;
        if let Some(error) = flushed.error.as_ref().or(flushed.refused.as_ref()) {
            tracing::debug!(deltas = flushed.deltas, snapshots = flushed.snapshots, "relay feed: {error}");
        }
    }
}

/// Stops the watch when the feed stops.
struct Aborts(tokio::task::JoinHandle<()>);
impl Drop for Aborts {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// The feed's own `_acpmux/watch`: each notification that names a session sends it, any other
/// sends `None` (the list), and a reconnect sends `None` too (what changed meanwhile is unknown).
async fn follow_acpmux(
    acpmux: AcpmuxTarget,
    session_exposure: Option<watch::Receiver<SessionExposure>>,
    changes: mpsc::UnboundedSender<Option<String>>,
) {
    let mut backoff = Duration::from_secs(2);
    loop {
        match follow_once(&acpmux, session_exposure.as_ref(), &changes).await {
            Ok(()) => backoff = Duration::from_secs(2),
            Err(reason) => {
                tracing::debug!(reason, "relay feed watch ended");
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
        if changes.is_closed() {
            return;
        }
        tokio::time::sleep(backoff).await;
        if changes.send(None).is_err() {
            return;
        }
    }
}

async fn follow_once(
    acpmux: &AcpmuxTarget,
    session_exposure: Option<&watch::Receiver<SessionExposure>>,
    changes: &mpsc::UnboundedSender<Option<String>>,
) -> Result<(), String> {
    let socket = crate::services::connect_acpmux(acpmux).await.map_err(|r| r.reason)?;
    let (mut sink, mut source) = socket.split();
    let requests = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"cmux-mobile-host-relay-feed","version":"1"},"clientCapabilities":{}}}),
        // The first page only, one row: the feed reads the list through `catch-up`.
        json!({"jsonrpc":"2.0","id":2,"method":"_acpmux/watch","params":{"enabled":true,"limit":1}}),
    ];
    for request in requests {
        sink.send(Message::Text(request.to_string().into())).await.map_err(|e| e.to_string())?;
    }
    while let Some(message) = source.next().await {
        let text = match message.map_err(|e| e.to_string())? {
            Message::Text(text) => text.to_string(),
            Message::Close(_) => break,
            _ => continue,
        };
        let exposure = session_exposure.map(|receiver| receiver.borrow().clone()).unwrap_or_default();
        let Some(text) = crate::acpmux_policy::filter_response(&text, &exposure, &HashSet::new()) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(&text) else { continue };
        if value.get("id").is_some() || value.get("method").is_none() {
            continue;
        }
        let params = value.get("params");
        let session = params
            .and_then(|p| p.pointer("/session/sessionId").or_else(|| p.get("sessionId")))
            .and_then(Value::as_str)
            .map(str::to_owned);
        if changes.send(session).is_err() {
            return Ok(());
        }
    }
    Err("acpmux closed".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_on_turns_it_on() {
        assert!(!enabled_in(|_| None));
        assert!(!enabled_in(|_| Some("1".into())));
        assert!(!enabled_in(|_| Some("off".into())));
        assert!(enabled_in(|name| (name == ENV).then(|| " ON ".into())));
    }

    #[test]
    fn surface_names_stay_in_the_relays_bound() {
        assert!(valid_surface("chat/00000000-0000-7000-8000-000000000001"));
        assert!(valid_surface(WORKSPACES));
        assert!(!valid_surface("chat/has space"));
        assert!(!valid_surface(&chat_surface(&"x".repeat(90))));
    }

    #[test]
    fn a_first_screen_keeps_a_chats_newest_events() {
        let events: Vec<Value> = (1..=100)
            .map(|seq| json!({"seq": seq, "kind": "transcript", "msg": {"text": "y".repeat(400)}}))
            .collect();
        let page = json!({"sessionId": "s", "events": events, "hasMore": false, "lastSeq": 100});
        let screen: Value = serde_json::from_slice(&first_screen("chat/s", &page).unwrap()).unwrap();
        assert!(serde_json::to_vec(&screen).unwrap().len() <= FIRST_SCREEN_BYTES);
        let kept = screen["events"].as_array().unwrap();
        assert_eq!(kept.last().unwrap()["seq"], 100);
        assert_eq!(screen["olderBefore"], kept[0]["seq"]);
        assert_eq!(screen["hasMore"], true);
        assert_eq!(screen["sessionId"], "s");
        let small = json!({"sessionId": "s", "events": []});
        assert_eq!(first_screen("chat/s", &small).unwrap(), serde_json::to_vec(&small).unwrap());
        assert!(first_screen(WORKSPACES, &json!({"w": "z".repeat(FIRST_SCREEN_BYTES)})).is_none());
    }
}
