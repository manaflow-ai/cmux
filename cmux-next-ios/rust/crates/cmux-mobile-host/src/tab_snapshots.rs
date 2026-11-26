//! The `tabs` service (`tab-snapshots-v1`): what the phone's tab overview
//! shows for every tab of this Mac, as the `cmux-tab-snapshots` frames.
//!
//! One [`Tabs`] per host process ([`TABS`]) holds the producer and its blob
//! store, so every phone shares the same blobs. Each `tabs` channel is one
//! [`Session`]. Each frame travels behind its 4-byte big-endian length
//! (`cmux_tab_snapshots::stream`), both directions. Frames from the phone go
//! into the session, and frames out are pulled
//! only when the channel takes the previous one (`ChannelSender::send`
//! waits on the channel's queue), woken when the producer changes.
//!
//! The feeder fills the producer from the daemon while at least one phone
//! has `tabs` open: the tab list (refetched on the daemon's tree events) and
//! each terminal's screen text (read again on `surface-output`, at most once
//! a second per terminal). It stops when the last phone leaves. Its daemon
//! connections say `remote: true`, so the daemon hides incognito workspaces
//! from it as from a phone. Favicons and thumbnails come from the Mac app:
//! it writes each to a file in its own cache folder and names it on a
//! `tab_picture` control line ([`PictureFile`]); [`offer_file`] reads them in
//! line order and hands them to [`Tabs::offer_image`].
//!
//! A tab's id is its daemon surface id, which only means something within
//! one run of the daemon: a new run numbers its surfaces again from its
//! saved state, so an old id can name another tab. The host learns of no
//! run id, so every time the feeder connects to the daemon again it treats
//! the daemon as a new run ([`Tabs::daemon_run`]): every row, the order and
//! the pictures held for tabs go, under a new epoch, and each phone gets a
//! manifest of the new run's tabs.
//!
//! Each phone also sees only the tabs its chat exposure allows, by the rule
//! the `daemon` service applies to its replies
//! (`acpmux_policy::filter_daemon_response`): a tab naming a blocked agent
//! session is hidden, and with the exposure unavailable every tab is.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_tab_snapshots::{
    Deframer, FaviconInput, ImageInput, Kind, Mime, Observation, Producer, RowFilter, ScreenInput, Session,
    length_prefixed,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, watch};

use crate::control::SessionExposure;
use crate::services::Refusal;

/// How many revs a reconnecting phone can resume from.
const HISTORY_CAP: usize = 256;
/// Unreferenced blobs the store keeps for a phone that comes back.
const RECENT_BLOB_CAP: usize = 64;
/// The largest favicon or thumbnail accepted.
pub const MAX_IMAGE_BYTES: usize = 2 << 20;
/// The largest screen text kept per terminal.
const MAX_SCREEN_BYTES: usize = 256 << 10;
/// Tabs with pictures but not (yet) in the daemon's list.
const MAX_UNLISTED_PICTURES: usize = 256;
/// The largest daemon reply line read.
const MAX_LINE_BYTES: usize = 64 << 20;
/// The longest frame a phone may send (its `have` lists every blob it holds).
const MAX_PHONE_FRAME: usize = 1 << 20;
/// A terminal's screen is read at most this often.
const SCREEN_INTERVAL: Duration = Duration::from_secs(1);
/// How often the feeder acts on what the daemon said changed.
const FEED_TICK: Duration = Duration::from_millis(100);
const QUERY_WAIT: Duration = Duration::from_secs(5);
const RECONNECT_WAIT: Duration = Duration::from_secs(1);

/// This host process's tab state, shared by every phone.
pub static TABS: LazyLock<Arc<Tabs>> =
    LazyLock::new(|| Arc::new(Tabs::new(uuid::Uuid::new_v4().to_string())));

/// Which picture of a tab [`Tabs::offer_image`] gives.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Part {
    Favicon,
    Thumb,
}

/// The `tab_picture` control line: a favicon or thumbnail the Mac app wrote
/// to `path` (in its own cache folder, never a path a phone names). The
/// format comes from the bytes; a `mime` the app also sends is ignored.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct PictureFile {
    /// The tab's daemon surface id, the id [`listed_tabs`] gives it.
    pub surface: u64,
    pub part: Part,
    pub path: String,
    /// The image's pixels (a thumbnail's; 0 when unknown).
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
    #[serde(default)]
    pub captured_at_ms: i64,
}

/// One tab as the daemon lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct ListedTab {
    pub id: String,
    pub title: String,
    pub kind: Kind,
    /// Terminal size, for the screen text.
    pub cols: u32,
    pub rows: u32,
    /// The daemon's tab object, for the exposure rule.
    pub raw: Value,
}

#[derive(Default)]
struct Pictures {
    favicon: Option<FaviconInput>,
    thumb: Option<ImageInput>,
    captured_at_ms: i64,
}

struct Known {
    tab: ListedTab,
    screen: Option<ScreenInput>,
    captured_at_ms: i64,
}

struct State {
    producer: Producer,
    tabs: HashMap<String, Known>,
    pictures: HashMap<String, Pictures>,
    /// A feeder reached the daemon at least once.
    fed: bool,
    /// The daemon run the feeder last reached, as its `identify` named it.
    run: Option<String>,
}

struct Life {
    phones: usize,
    feeder: bool,
    /// Feeders started, for tests and logs.
    feeds: u64,
}

pub struct Tabs {
    state: Mutex<State>,
    /// Bumped on every producer change.
    changed: watch::Sender<u64>,
    life: Mutex<Life>,
    /// The phone count, for the feeder to see the last one leave.
    phones: watch::Sender<usize>,
}

/// Held by a serving channel; dropping it counts the phone out.
pub struct PhoneGuard {
    tabs: Arc<Tabs>,
}

impl Drop for PhoneGuard {
    fn drop(&mut self) {
        let mut life = self.tabs.lock_life();
        life.phones = life.phones.saturating_sub(1);
        self.tabs.phones.send_replace(life.phones);
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

impl Tabs {
    /// `epoch`: fresh per host start (see `Producer::new`); a new one per
    /// daemon run after the first ([`Tabs::daemon_run`]).
    pub fn new(epoch: impl Into<String>) -> Self {
        Self {
            state: Mutex::new(State {
                producer: Producer::new(epoch, 0, HISTORY_CAP, RECENT_BLOB_CAP),
                tabs: HashMap::new(),
                pictures: HashMap::new(),
                fed: false,
                run: None,
            }),
            changed: watch::channel(0).0,
            life: Mutex::new(Life { phones: 0, feeder: false, feeds: 0 }),
            phones: watch::channel(0).0,
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_life(&self) -> MutexGuard<'_, Life> {
        self.life.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn bump(&self) {
        self.changed.send_modify(|n| *n = n.wrapping_add(1));
    }

    /// The producer's rev now.
    pub fn rev(&self) -> u64 {
        self.lock().producer.rev()
    }

    /// The tab ids the producer lists, in order.
    pub fn tab_ids(&self) -> Vec<String> {
        self.lock().producer.rows().iter().map(|r| r.tab_id.clone()).collect()
    }

    /// Distinct blobs the shared store holds.
    pub fn stored_blobs(&self) -> usize {
        let state = self.lock();
        let mut hashes = HashSet::new();
        for row in state.producer.rows() {
            hashes.extend(row.hashes());
        }
        hashes.len()
    }

    pub fn phones(&self) -> usize {
        self.lock_life().phones
    }

    pub fn feeder_running(&self) -> bool {
        self.lock_life().feeder
    }

    /// How many feeders have started in this process.
    pub fn feeds_started(&self) -> u64 {
        self.lock_life().feeds
    }

    /// A tab's favicon or thumbnail from the Mac app. `w` and `h` are the
    /// image's pixels (ignored for a favicon). Only JPEG and PNG of at most
    /// [`MAX_IMAGE_BYTES`] are taken. A picture for a tab the daemon has
    /// not listed yet is kept until it does. Returns true when the phone's
    /// view changed (a new rev).
    #[allow(clippy::too_many_arguments)]
    pub fn offer_image(
        &self,
        tab_id: &str,
        part: Part,
        bytes: Vec<u8>,
        w: u32,
        h: u32,
        mime: Mime,
        captured_at_ms: i64,
    ) -> bool {
        if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES || !matches!(mime, Mime::Jpeg | Mime::Png) {
            return false;
        }
        let mut state = self.lock();
        let listed = state.tabs.contains_key(tab_id);
        let unlisted = state.pictures.keys().filter(|id| !state.tabs.contains_key(*id)).count();
        if !listed && !state.pictures.contains_key(tab_id) && unlisted >= MAX_UNLISTED_PICTURES {
            return false;
        }
        let pictures = state.pictures.entry(tab_id.to_owned()).or_default();
        match part {
            Part::Favicon => pictures.favicon = Some(FaviconInput { mime, bytes }),
            Part::Thumb => pictures.thumb = Some(ImageInput { mime, bytes, width: w, height: h }),
        }
        pictures.captured_at_ms = captured_at_ms;
        if !listed {
            return false;
        }
        let changed = observe(&mut state, tab_id);
        drop(state);
        if changed {
            self.bump();
        }
        changed
    }

    /// Reads `file` and offers it ([`Tabs::offer_image`]): an absolute path
    /// to a regular file (not a link) of at most [`MAX_IMAGE_BYTES`] holding
    /// a JPEG or PNG. Returns true when the phone's view changed.
    pub async fn offer_file(&self, file: &PictureFile) -> bool {
        match read_picture(Path::new(&file.path)).await {
            Ok((mime, bytes)) => self.offer_image(
                &file.surface.to_string(),
                file.part,
                bytes,
                file.w,
                file.h,
                mime,
                file.captured_at_ms,
            ),
            Err(reason) => {
                tracing::warn!(surface = file.surface, part = ?file.part, reason, "ignoring a tab picture");
                false
            }
        }
    }

    /// The daemon's tab list now, in order. Closed tabs leave.
    pub fn set_tabs(&self, listed: Vec<ListedTab>) -> bool {
        let mut state = self.lock();
        let ids: Vec<String> = listed.iter().map(|t| t.id.clone()).collect();
        let keep: HashSet<&str> = ids.iter().map(String::as_str).collect();
        let mut changed = false;
        let gone: Vec<String> = state
            .producer
            .rows()
            .iter()
            .map(|r| r.tab_id.clone())
            .filter(|id| !keep.contains(id.as_str()))
            .collect();
        for id in gone {
            changed |= state.producer.remove(&id);
            state.tabs.remove(&id);
            state.pictures.remove(&id);
        }
        state.tabs.retain(|id, _| keep.contains(id.as_str()));
        for tab in listed {
            let id = tab.id.clone();
            let known = state.tabs.remove(&id);
            let (screen, captured_at_ms) = match known {
                Some(k) => (k.screen, k.captured_at_ms),
                None => (None, now_ms()),
            };
            let screen = screen.map(|s| ScreenInput { cols: tab.cols, rows: tab.rows, ..s });
            state.tabs.insert(id.clone(), Known { tab, screen, captured_at_ms });
            changed |= observe(&mut state, &id);
        }
        changed |= state.producer.set_order(&ids);
        drop(state);
        if changed {
            self.bump();
        }
        changed
    }

    /// A terminal's screen text. Ignored for a tab not listed.
    pub fn set_screen(&self, tab_id: &str, text: String) -> bool {
        let mut state = self.lock();
        let Some(known) = state.tabs.get_mut(tab_id) else { return false };
        let text = truncate(text, MAX_SCREEN_BYTES);
        known.screen = Some(ScreenInput { text, cols: known.tab.cols, rows: known.tab.rows });
        known.captured_at_ms = now_ms();
        let changed = observe(&mut state, tab_id);
        drop(state);
        if changed {
            self.bump();
        }
        changed
    }

    /// The ids of the tabs `exposure` hides, or `None` when it hides all.
    fn hidden(&self, exposure: &SessionExposure) -> Option<HashSet<String>> {
        if !exposure.available {
            return None;
        }
        if !exposure.configured {
            return Some(HashSet::new());
        }
        let state = self.lock();
        Some(
            state
                .tabs
                .iter()
                .filter(|(_, k)| crate::acpmux_policy::daemon_chat_blocked(&k.tab.raw, exposure, true))
                .map(|(id, _)| id.clone())
                .collect(),
        )
    }

    /// The feeder reached the daemon, whose run `run` names (its pid,
    /// registry and generation; None when it did not say). The first time,
    /// the daemon is the one this host's epoch began with. A later time on
    /// the run it last reached keeps everything: the feeder only stopped
    /// with the last phone. Any other later time may be a new run of the
    /// daemon, whose surface ids are not the old run's: every row, the order
    /// and every picture held go, and `epoch` replaces the epoch, so a phone,
    /// open or resuming, gets a manifest of the tabs listed from now on.
    /// Returns true when it started over.
    pub fn daemon_run(&self, epoch: impl Into<String>, run: Option<String>) -> bool {
        let mut state = self.lock();
        let same = run.is_some() && state.run == run;
        state.run = run;
        if !std::mem::replace(&mut state.fed, true) || same {
            return false;
        }
        state.producer.new_epoch(epoch);
        state.tabs.clear();
        state.pictures.clear();
        drop(state);
        self.bump();
        true
    }

    /// The producer's epoch now.
    pub fn epoch(&self) -> String {
        self.lock().producer.epoch().to_owned()
    }

    /// Counts a phone in and starts the feeder on `socket` if none runs.
    pub fn join(self: &Arc<Self>, socket: Option<PathBuf>) -> PhoneGuard {
        let mut life = self.lock_life();
        life.phones = life.phones.saturating_add(1);
        self.phones.send_replace(life.phones);
        if let Some(socket) = socket
            && !life.feeder
        {
            life.feeder = true;
            life.feeds = life.feeds.saturating_add(1);
            let tabs = Arc::clone(self);
            tokio::spawn(async move { feed(tabs, socket).await });
        }
        PhoneGuard { tabs: Arc::clone(self) }
    }

    /// Clears the feeder flag if no phone is left. Checked under the same
    /// lock as [`Tabs::join`], so a phone that joins as the feeder leaves
    /// either sees it running or starts a new one.
    fn feeder_may_stop(&self) -> bool {
        let mut life = self.lock_life();
        if life.phones == 0 {
            life.feeder = false;
            return true;
        }
        false
    }
}

/// Hands the app's `tab_picture` line to one reader task, so the files are
/// read off the control loop and still in line order (an older thumbnail
/// never lands over a newer one).
pub fn offer_file(file: PictureFile) {
    static QUEUE: LazyLock<mpsc::UnboundedSender<PictureFile>> = LazyLock::new(|| {
        let (tx, mut rx) = mpsc::unbounded_channel::<PictureFile>();
        tokio::spawn(async move {
            while let Some(file) = rx.recv().await {
                TABS.offer_file(&file).await;
            }
        });
        tx
    });
    let _ = QUEUE.send(file);
}

/// The picture at `path` and its format, or why it cannot be taken.
async fn read_picture(path: &Path) -> Result<(Mime, Vec<u8>), &'static str> {
    if !path.is_absolute() {
        return Err("not an absolute path");
    }
    let metadata = tokio::fs::symlink_metadata(path).await.map_err(|_| "no such file")?;
    if !metadata.is_file() {
        return Err("not a regular file");
    }
    if metadata.len() == 0 || metadata.len() > MAX_IMAGE_BYTES as u64 {
        return Err("empty or too large");
    }
    let bytes = tokio::fs::read(path).await.map_err(|_| "unreadable")?;
    if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return Err("empty or too large");
    }
    let mime = if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Mime::Jpeg
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Mime::Png
    } else {
        return Err("not a JPEG or PNG");
    };
    Ok((mime, bytes))
}

fn truncate(mut text: String, cap: usize) -> String {
    if text.len() > cap {
        let mut end = cap;
        while end > 0 && !text.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        text.truncate(end);
    }
    text
}

/// Feeds a listed tab's current parts to the producer.
fn observe(state: &mut State, tab_id: &str) -> bool {
    let Some(known) = state.tabs.get(tab_id) else { return false };
    let pictures = state.pictures.get(tab_id);
    let captured_at_ms = known.captured_at_ms.max(pictures.map_or(0, |p| p.captured_at_ms));
    let obs = Observation {
        tab_id: tab_id.to_owned(),
        title: known.tab.title.clone(),
        kind: known.tab.kind.clone(),
        favicon: pictures.and_then(|p| p.favicon.clone()),
        thumb: pictures.and_then(|p| p.thumb.clone()),
        screen: known.screen.clone(),
        frame: None,
        captured_at_ms,
    };
    state.producer.observe(obs)
}

/// The filter key: whether the exposure is available, and what it hides.
type Hidden = Option<HashSet<String>>;

fn row_filter(hidden: Hidden) -> RowFilter {
    RowFilter::new(move |id| hidden.as_ref().is_some_and(|h| !h.contains(id)))
}

async fn exposure_changed(exposure: &mut Option<watch::Receiver<SessionExposure>>) {
    match exposure {
        Some(rx) => {
            if rx.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
        None => std::future::pending::<()>().await,
    }
}

/// Serves one `tabs` channel until the phone closes it. `socket` is the
/// daemon the feeder reads (none: the producer is filled only by others).
pub async fn serve(
    tabs: &Arc<Tabs>,
    socket: Option<PathBuf>,
    exposure: Option<watch::Receiver<SessionExposure>>,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let _guard = tabs.join(socket);
    let mut session = Session::new();
    let mut deframer = Deframer::new(MAX_PHONE_FRAME);
    let mut changed = tabs.changed.subscribe();
    let mut exposure = exposure;
    let mut filter: Option<Hidden> = None;
    loop {
        changed.borrow_and_update();
        if let Some(rx) = exposure.as_mut() {
            let state = rx.borrow_and_update().clone();
            let hidden = tabs.hidden(&state);
            if filter.as_ref() != Some(&hidden) {
                session.set_row_filter(Some(row_filter(hidden.clone())));
                filter = Some(hidden);
            }
        }
        loop {
            let frame = {
                let state = tabs.lock();
                session.next_frame(&state.producer)
            };
            let Some(frame) = frame.and_then(|f| length_prefixed(&f)) else { break };
            if sender.send(Bytes::from(frame)).await.is_err() {
                return Ok(());
            }
        }
        tokio::select! {
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    deframer.push(&bytes);
                    while let Some(frame) =
                        deframer.next_frame().map_err(|e| Refusal::new("bad_request", e.to_string()))?
                    {
                        session.on_frame(&frame).map_err(|e| Refusal::new("bad_request", e.to_string()))?;
                    }
                }
                Some(ChannelEvent::Closed(_)) | None => return Ok(()),
            },
            result = changed.changed() => {
                if result.is_err() {
                    return Ok(());
                }
            }
            () = exposure_changed(&mut exposure) => {}
        }
    }
}

/// Runs while a phone has `tabs` open; reconnects to the daemon after a
/// failure, and returns once no phone is left.
async fn feed(tabs: Arc<Tabs>, socket: PathBuf) {
    let mut phones = tabs.phones.subscribe();
    loop {
        tokio::select! {
            result = feed_once(&tabs, &socket) => {
                if let Err(err) = result {
                    tracing::debug!(err, "tabs feeder lost the daemon");
                }
            }
            _ = phones.wait_for(|n| *n == 0) => {}
        }
        if tabs.feeder_may_stop() {
            tracing::debug!("tabs feeder stopped: no phone left");
            return;
        }
        tokio::select! {
            () = tokio::time::sleep(RECONNECT_WAIT) => {}
            _ = phones.wait_for(|n| *n == 0) => {}
        }
        if tabs.feeder_may_stop() {
            return;
        }
    }
}

fn hello(id: &str) -> Value {
    json!({
        "cmd": "set-client-info",
        "id": id,
        "name": "cmux-mobile-host tabs",
        "kind": "cli",
        "remote": true,
        "device_id": "cmux-mobile-host-tabs",
        "capabilities": ["conversation-tabs-v1", "page-tabs-v1"],
    })
}

/// One request on `query`, its reply (`id` matched).
async fn query<R: AsyncBufRead + Unpin, W: AsyncWriteExt + Unpin>(
    reader: &mut R,
    writer: &mut W,
    request: &Value,
    id: &str,
) -> Result<Value, String> {
    let mut line = request.to_string();
    line.push('\n');
    let read = async {
        writer.write_all(line.as_bytes()).await.map_err(|e| e.to_string())?;
        loop {
            let line = read_line(reader, MAX_LINE_BYTES).await.map_err(|e| e.to_string())?;
            let Some(line) = line else { return Err("closed".to_owned()) };
            let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
            if value.get("id").and_then(Value::as_str) == Some(id) {
                return Ok(value);
            }
        }
    };
    tokio::time::timeout(QUERY_WAIT, read).await.map_err(|_| "timed out".to_owned())?
}

/// One line without its newline, at most `cap` bytes; `None` at the end.
async fn read_line<R: AsyncBufRead + Unpin>(reader: &mut R, cap: usize) -> std::io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    loop {
        let buf = reader.fill_buf().await?;
        if buf.is_empty() {
            return Ok((!line.is_empty()).then_some(line));
        }
        if let Some(at) = buf.iter().position(|b| *b == b'\n') {
            line.extend_from_slice(buf.get(..at).unwrap_or_default());
            reader.consume(at.saturating_add(1));
            return Ok(Some(line));
        }
        let n = buf.len();
        line.extend_from_slice(buf);
        reader.consume(n);
        if line.len() > cap {
            return Err(std::io::Error::other("line too long"));
        }
    }
}

/// The tabs of a `list-workspaces` reply, in tree order.
pub fn listed_tabs(reply: &Value) -> Vec<ListedTab> {
    let data = reply.get("data").unwrap_or(reply);
    let list = |value: &Value, key: &str| -> Vec<Value> {
        value.get(key).and_then(Value::as_array).cloned().unwrap_or_default()
    };
    let mut out = Vec::new();
    for workspace in list(data, "workspaces") {
        for screen in list(&workspace, "screens") {
            for pane in list(&screen, "panes") {
                for tab in list(&pane, "tabs") {
                    let Some(id) = tab.get("surface").and_then(Value::as_u64) else { continue };
                    let text = |key: &str| tab.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
                    let title = text("title").or_else(|| text("name")).unwrap_or_default().to_owned();
                    let kind = match text("kind").unwrap_or_default() {
                        "browser" => Kind::Browser,
                        "pty" | "remote-terminal" => Kind::Terminal,
                        "conversation" => Kind::Agent,
                        other => Kind::Other(other.to_owned()),
                    };
                    let size = |key: &str| {
                        tab.pointer(&format!("/size/{key}"))
                            .and_then(Value::as_u64)
                            .and_then(|n| u32::try_from(n).ok())
                            .unwrap_or(0)
                    };
                    let (cols, rows) = (size("cols"), size("rows"));
                    out.push(ListedTab { id: id.to_string(), title, kind, cols, rows, raw: tab });
                }
            }
        }
    }
    out
}

/// True for the daemon events after which the tab list may differ.
fn tree_event(name: &str) -> bool {
    name == "tree-changed"
        || name == "title-changed"
        || ["tab-", "workspace-", "pane-", "screen-"].iter().any(|p| name.starts_with(p))
}

/// The run an `identify` reply names: its pid, registry and generation, or
/// None when it names none of them.
fn daemon_run_key(reply: &Value) -> Option<String> {
    let data = reply.get("data").unwrap_or(reply);
    let part = |key: &str| data.get(key).filter(|v| !v.is_null()).map(Value::to_string);
    let parts = ["pid", "registry_id", "generation"].map(part);
    parts.iter().any(Option::is_some).then(|| parts.map(Option::unwrap_or_default).join("/"))
}

/// One pass: connects, follows the daemon's events, and returns on error.
async fn feed_once(tabs: &Tabs, socket: &Path) -> Result<(), String> {
    let events = UnixStream::connect(socket).await.map_err(|e| e.to_string())?;
    let (events_read, mut events_write) = events.into_split();
    let subscribe = json!({"cmd": "subscribe", "id": "tabs-subscribe", "tree_events": "deltas"});
    let opening = format!("{}\n{subscribe}\n", hello("tabs-hello"));
    events_write.write_all(opening.as_bytes()).await.map_err(|e| e.to_string())?;
    let mut events = BufReader::new(events_read).lines();

    let queries = UnixStream::connect(socket).await.map_err(|e| e.to_string())?;
    let (query_read, mut query_write) = queries.into_split();
    let mut query_read = BufReader::new(query_read);
    query(&mut query_read, &mut query_write, &hello("tabs-query-hello"), "tabs-query-hello").await?;
    let identify = query(
        &mut query_read,
        &mut query_write,
        &json!({"cmd": "identify", "id": "tabs-identify"}),
        "tabs-identify",
    )
    .await;
    if tabs.daemon_run(uuid::Uuid::new_v4().to_string(), identify.ok().as_ref().and_then(daemon_run_key)) {
        tracing::debug!("tabs feeder reconnected: a new epoch");
    }

    let mut list_dirty = true;
    let mut dirty: HashSet<String> = HashSet::new();
    let mut last_read: HashMap<String, Instant> = HashMap::new();
    let mut tick = tokio::time::interval(FEED_TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            line = events.next_line() => {
                let Some(line) = line.map_err(|e| e.to_string())? else { return Err("closed".to_owned()) };
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                match value.get("event").and_then(Value::as_str) {
                    Some("surface-output") => {
                        if let Some(surface) = value.get("surface").and_then(Value::as_u64) {
                            dirty.insert(surface.to_string());
                        }
                    }
                    Some(name) if tree_event(name) => list_dirty = true,
                    _ => {}
                }
            }
            _ = tick.tick() => {
                if list_dirty {
                    list_dirty = false;
                    let reply = query(&mut query_read, &mut query_write, &json!({"cmd": "list-workspaces", "id": "tabs-list"}), "tabs-list").await?;
                    let listed = listed_tabs(&reply);
                    for tab in &listed {
                        if tab.kind == Kind::Terminal && !last_read.contains_key(&tab.id) {
                            dirty.insert(tab.id.clone());
                        }
                    }
                    let terminals: HashSet<&str> =
                        listed.iter().filter(|t| t.kind == Kind::Terminal).map(|t| t.id.as_str()).collect();
                    dirty.retain(|id| terminals.contains(id.as_str()));
                    last_read.retain(|id, _| terminals.contains(id.as_str()));
                    tabs.set_tabs(listed);
                }
                let now = Instant::now();
                let due: Vec<String> = dirty
                    .iter()
                    .filter(|id| last_read.get(*id).is_none_or(|at| now.saturating_duration_since(*at) >= SCREEN_INTERVAL))
                    .cloned()
                    .collect();
                for id in due {
                    dirty.remove(&id);
                    last_read.insert(id.clone(), now);
                    let Ok(surface) = id.parse::<u64>() else { continue };
                    let request_id = format!("tabs-screen-{id}");
                    let request = json!({"cmd": "read-screen", "surface": surface, "id": request_id});
                    let reply = query(&mut query_read, &mut query_write, &request, &request_id).await?;
                    if let Some(text) = reply.pointer("/data/text").and_then(Value::as_str) {
                        tabs.set_screen(&id, text.to_owned());
                    }
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "tab_snapshots_tests.rs"]
mod tests;
