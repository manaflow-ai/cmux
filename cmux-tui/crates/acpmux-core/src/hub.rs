//! The published summary hub.
//!
//! A chat actor submits one small summary to the writer. The writer appends the
//! record, applies it to the persistent ordered maps and publishes the new
//! snapshot through [`ArcSwap`]. Readers load that snapshot without taking a
//! lock and a list window copies only the rows it will send.

use acpmux_book::index::{
    DiskSnapshot, IndexEdition, IndexLog, OriginRecord, OriginState, ReadSide, RowKey, SortKey,
    Summary, SummaryIndex, replay_generation_logs,
};
use arc_swap::ArcSwap;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use thiserror::Error;
use tokio::sync::Notify;

use crate::wire::{Frame, FrameError, FrameKind, Origin, Sub};
mod compaction;
mod disk;
#[cfg(test)]
mod folder_tests;
mod folders;
mod history;
mod keyed_page;
mod origins;
pub use compaction::CompactionStats;
use history::History;
pub use origins::{Source, refused_held_rows};

pub use crate::wire::{DeltaFrame, Window};

/// The default list window and the hard row count ceiling for one window.
pub const DEFAULT_WINDOW_ROWS: usize = 100;
pub const MAX_WINDOW_ROWS: usize = 400;
const EVENT_CAPACITY: usize = 1024;
static REFUSED_SOURCE_SUBMITS: AtomicU64 = AtomicU64::new(0);
static REFUSED_ORIGINS: AtomicU64 = AtomicU64::new(0);

pub fn refused_source_submits() -> u64 {
    REFUSED_SOURCE_SUBMITS.load(Ordering::Relaxed)
}

pub fn refused_origins() -> u64 {
    REFUSED_ORIGINS.load(Ordering::Relaxed)
}

/// A summary change in index sequence order. The summary is shared with the
/// published snapshot, so sending it to subscribers is O(1) in chat count.
#[derive(Clone, Debug)]
pub struct SummaryEvent {
    pub seq: u64,
    pub summary: Arc<Summary>,
}

#[derive(Clone, Debug)]
pub enum ListItem {
    Summary(SummaryEvent),
    Gone { seq: u64, chat_id: String, origin: String },
    Origin { seq: u64, origin: Origin },
    Folders { seq: u64, ops: Vec<acpmux_book::index::folders::FolderOp> },
    Lagged { cursor: u64 },
}

enum PendingUpdate {
    Summary { source: Source, summary: Box<Summary> },
    Gone { source: Source },
    Origin { record: OriginRecord },
    Takeover { origin: String, source: Source },
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Ord, PartialOrd)]
enum UpdateKey {
    Row(RowKey),
    Origin(Arc<str>),
    Source(Arc<str>),
}

#[derive(Default)]
struct Pending {
    rows: HashMap<(RowKey, Source), PendingUpdate>,
    controls: std::collections::BTreeMap<UpdateKey, std::collections::VecDeque<PendingUpdate>>,
}

impl Pending {
    fn is_empty(&self) -> bool {
        self.rows.is_empty() && self.controls.is_empty()
    }
}

struct UpdateQueue {
    pending: Mutex<Pending>,
    notify: Notify,
    closed: AtomicBool,
}

impl UpdateQueue {
    fn new() -> Self {
        Self {
            pending: Mutex::new(Pending::default()),
            notify: Notify::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn submit(&self, source: Source, summary: Summary) -> Result<(), HubError> {
        self.enqueue(
            UpdateKey::Row(summary.key()),
            PendingUpdate::Summary { source, summary: Box::new(summary) },
        )
    }

    fn submit_remove(&self, source: Source, key: RowKey) -> Result<(), HubError> {
        self.enqueue(UpdateKey::Row(key), PendingUpdate::Gone { source })
    }

    fn enqueue(&self, key: UpdateKey, update: PendingUpdate) -> Result<(), HubError> {
        let mut pending = self.pending.lock().map_err(|_| HubError::WriterGone)?;
        if self.closed.load(Ordering::Acquire) {
            return Err(HubError::WriterGone);
        }
        match key {
            UpdateKey::Row(key) => {
                let source = match &update {
                    PendingUpdate::Summary { source, .. } | PendingUpdate::Gone { source } => {
                        *source
                    }
                    _ => return Err(HubError::WriterGone),
                };
                // A rejected producer must not coalesce away the owner's
                // pending value before the writer can enforce ownership.
                pending.rows.insert((key, source), update);
            }
            key => {
                if !pending.controls.contains_key(&key) && pending.controls.len() >= 512 {
                    REFUSED_ORIGINS.fetch_add(1, Ordering::Relaxed);
                    return Err(HubError::OriginLimit);
                }
                if let UpdateKey::Origin(origin) = &key
                    && matches!(&update, PendingUpdate::Origin { record } if record.state == OriginState::Removed)
                {
                    pending.rows.retain(|(row, _), _| row.origin.as_ref() != origin.as_ref());
                    let slot = pending.controls.entry(key).or_default();
                    slot.clear();
                    slot.push_back(update);
                } else if let UpdateKey::Origin(_) = &key {
                    let slot = pending.controls.entry(key).or_default();
                    if slot.front().is_some_and(|update| matches!(update, PendingUpdate::Origin { record } if record.state == OriginState::Removed)) {
                        slot.truncate(1);
                        slot.push_back(update);
                    } else {
                        slot.clear();
                        slot.push_back(update);
                    }
                } else {
                    let slot = pending.controls.entry(key).or_default();
                    slot.clear();
                    slot.push_back(update);
                }
            }
        }
        self.notify.notify_one();
        Ok(())
    }

    fn close(&self) {
        let _pending = self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.closed.store(true, Ordering::Release);
        self.notify.notify_one();
    }

    #[cfg(test)]
    fn take_batch(&self) -> Vec<(UpdateKey, PendingUpdate)> {
        self.take_batch_limit(256)
    }

    fn take_batch_limit(&self, limit: usize) -> Vec<(UpdateKey, PendingUpdate)> {
        let Ok(mut pending) = self.pending.lock() else { return Vec::new() };
        let mut batch = Vec::new();
        while batch.len() < limit {
            let Some((key, mut updates)) = pending.controls.pop_first() else { break };
            let Some(update) = updates.pop_front() else { continue };
            if !updates.is_empty() {
                pending.controls.insert(key.clone(), updates);
            }
            batch.push((key, update));
        }
        let keys: Vec<_> = pending.rows.keys().take(limit - batch.len()).cloned().collect();
        batch.extend(keys.into_iter().filter_map(|key| {
            pending.rows.remove(&key).map(|value| (UpdateKey::Row(key.0), value))
        }));
        batch
    }
}

struct SubscriberState {
    ended: bool,
    cursor: u64,
    window_pending: bool,
}

struct Subscriber {
    state: Mutex<SubscriberState>,
    notify: Notify,
}

impl Subscriber {
    fn new(cursor: u64) -> Self {
        Self {
            state: Mutex::new(SubscriberState { ended: false, cursor, window_pending: false }),
            notify: Notify::new(),
        }
    }
}

pub struct ListReceiver {
    subscriber: Arc<Subscriber>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    history: Arc<Mutex<History>>,
    folders: bool,
    folder_state: Arc<Mutex<folders::FolderState>>,
    published: Arc<ArcSwap<SummaryIndex>>,
}

pub(crate) enum RawRead {
    Span(history::RawSpan),
    Lagged,
}

impl Drop for ListReceiver {
    fn drop(&mut self) {
        if let Ok(mut subscribers) = self.subscribers.lock() {
            subscribers.retain(|subscriber| !Arc::ptr_eq(subscriber, &self.subscriber));
        }
    }
}

impl ListReceiver {
    pub fn advance_to(&self, cursor: u64) {
        if let Ok(mut state) = self.subscriber.state.lock() {
            state.cursor = state.cursor.max(cursor);
        }
    }

    pub fn reposition(&self, cursor: u64) {
        if let Ok(mut state) = self.subscriber.state.lock() {
            state.cursor = cursor;
            state.ended = false;
        }
    }

    pub fn try_next(&self) -> Option<ListItem> {
        if self.folders {
            return match self.try_next_raw(None, crate::wire::MAX_PAGE_BYTES)? {
                RawRead::Span(span) => folders::decode_item(span.bytes, span.last_seq),
                RawRead::Lagged => {
                    Some(ListItem::Lagged { cursor: self.subscriber.state.lock().ok()?.cursor })
                }
            };
        }
        let cursor = {
            let state = self.subscriber.state.lock().ok()?;
            if state.ended {
                return None;
            }
            state.cursor
        };
        let bytes = {
            let history = self.history.lock().ok()?;
            let first = history.first_seq();
            let last = history.last_seq().unwrap_or_else(|| self.published.load().seq());
            if cursor >= last {
                return None;
            }
            if first.is_some_and(|seq| cursor.saturating_add(1) < seq) {
                if let Ok(mut state) = self.subscriber.state.lock() {
                    state.ended = true;
                }
                return Some(ListItem::Lagged { cursor });
            }
            match history.after(cursor, cursor.saturating_add(1)) {
                Some(bytes) => bytes,
                None => {
                    if let Ok(mut state) = self.subscriber.state.lock() {
                        state.ended = true;
                    }
                    return Some(ListItem::Lagged { cursor });
                }
            }
        };
        let decoded = history::decode(bytes).ok().and_then(|items| items.into_iter().next());
        let item = match decoded {
            Some(item) => item,
            None => {
                if let Ok(mut state) = self.subscriber.state.lock() {
                    state.ended = true;
                }
                return Some(ListItem::Lagged { cursor });
            }
        };
        let seq = match &item {
            ListItem::Summary(event) => event.seq,
            ListItem::Gone { seq, .. } => *seq,
            ListItem::Origin { seq, .. } | ListItem::Folders { seq, .. } => *seq,
            ListItem::Lagged { cursor } => *cursor,
        };
        if let Ok(mut state) = self.subscriber.state.lock() {
            state.cursor = state.cursor.max(seq);
        }
        Some(item)
    }

    /// Reads a bounded span of the ring without decoding its operations.
    /// `through` limits a replay to the target captured when it opened; `None`
    /// follows the live tail. A malformed or expired span is reported as a
    /// lag so the connection can open one fresh window.
    pub(crate) fn try_next_raw(&self, through: Option<u64>, max_bytes: usize) -> Option<RawRead> {
        if self.folders {
            return self.next_folders(max_bytes);
        }
        let cursor = {
            let mut state = self.subscriber.state.lock().ok()?;
            if state.ended {
                return None;
            }
            if state.window_pending {
                state.window_pending = false;
                return Some(RawRead::Lagged);
            }
            state.cursor
        };
        let span = {
            let history = self.history.lock().ok()?;
            let last = history.last_seq().unwrap_or_else(|| self.published.load().seq());
            // A live pump consumes exactly one operation. A replay captures
            // its target once and may consume several bounded spans.
            let target = through.unwrap_or(cursor.saturating_add(1)).min(last);
            if cursor >= target {
                return None;
            }
            if history.first_seq().is_some_and(|first| cursor.saturating_add(1) < first) {
                None
            } else {
                history.after_frame(cursor, target, max_bytes)
            }
        };
        let Some(span) = span.filter(history::RawSpan::is_valid) else {
            if let Ok(mut state) = self.subscriber.state.lock() {
                state.ended = true;
            }
            return Some(RawRead::Lagged);
        };
        if let Ok(mut state) = self.subscriber.state.lock() {
            state.cursor = state.cursor.max(span.last_seq);
        }
        Some(RawRead::Span(span))
    }

    pub(crate) async fn recv_raw(&self, through: Option<u64>, max_bytes: usize) -> Option<RawRead> {
        loop {
            let changed = self.subscriber.notify.notified();
            if let Some(item) = self.try_next_raw(through, max_bytes) {
                return Some(item);
            }
            if self.subscriber.state.lock().ok()?.ended {
                return None;
            }
            changed.await;
        }
    }

    pub async fn recv(&self) -> Option<ListItem> {
        loop {
            let changed = self.subscriber.notify.notified();
            if let Some(item) = self.try_next() {
                return Some(item);
            }
            if self.subscriber.state.lock().ok()?.ended {
                return None;
            }
            changed.await;
        }
    }
}

pub struct ListSubscription {
    pub window: Frame,
    pub cursor: u64,
    pub receiver: ListReceiver,
}

/// The published index and its one-writer input queue.
pub struct Hub {
    hydrated: tokio::sync::watch::Receiver<disk::HydrationState>,
    compaction_counters: Arc<compaction::Counters>,
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: Arc<UpdateQueue>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    history: Arc<Mutex<History>>,
    folder_state: Arc<Mutex<folders::FolderState>>,
    page_provider: Arc<Mutex<Option<Arc<dyn PageProvider>>>>,
    sources: Arc<ArcSwap<HashMap<String, Source>>>,
    rebuild_requested: Arc<AtomicBool>,
    rebuild_count: Arc<AtomicU64>,
}

/// Supplies rows that are outside the hot summary index for a bounded keyed page.
pub trait PageProvider: Send + Sync {
    fn row(&self, key: &RowKey) -> std::io::Result<Option<Arc<Summary>>>;
}

/// Explicit name for the published summary hub used by later actors.
pub type SummaryHub = Hub;

/// The sole owner that mutates the index. It can be driven by a tokio task via
/// [`HubWriter::run`], or synchronously in deterministic unit tests with
/// [`HubWriter::apply`].
pub struct HubWriter {
    hydrated: tokio::sync::watch::Sender<disk::HydrationState>,
    #[cfg(test)]
    turn_measure: disk::TurnMeasure,
    compaction: Option<compaction::Job>,
    retirement: Option<tokio::task::JoinHandle<()>>,
    maintenance: Option<compaction::Maintenance>,
    next_compaction: Option<std::time::Instant>,
    compaction_backoff: u64,
    storage_retry: Option<std::time::Instant>,
    compaction_counters: Arc<compaction::Counters>,
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: Arc<UpdateQueue>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    history: Arc<Mutex<History>>,
    folder_state: Arc<Mutex<folders::FolderState>>,
    log: Option<IndexLog>,
    log_dirty: bool,
    log_errors: Arc<AtomicU64>,
    retry_log: HashMap<RowKey, (Source, acpmux_book::index::IndexRecord)>,
    hydration: Option<disk::Hydration>,
    sources: Arc<ArcSwap<HashMap<String, Source>>>,
    origins: origins::WriterOrigins,
    directory: Option<PathBuf>,
    rebuild_requested: Arc<AtomicBool>,
    rebuild_count: Arc<AtomicU64>,
}

#[derive(Debug, Error)]
pub enum HubError {
    #[error("the summary hub writer is gone")]
    WriterGone,
    #[error("the summary snapshot could not be hydrated")]
    HydrationFailed,
    #[error("the list stream must be named `list`, got {0:?}")]
    WrongStream(String),
    #[error("window must be between 1 and {MAX_WINDOW_ROWS} rows")]
    InvalidWindow,
    #[error("invalid list page anchor or byte budget")]
    InvalidPage,
    #[error("invalid_params: {0}")]
    InvalidParams(String),
    #[error("cursor_gone")]
    CursorGone,
    #[error("encoding list frame failed: {0}")]
    Frame(#[from] FrameError),
    #[error("index log failed: {0}")]
    Log(#[source] std::io::Error),
    #[error("published summary {0:?} is missing after apply")]
    MissingSummary(String),
    #[error("source {incoming:?} does not own origin {origin:?} (owner {owner:?})")]
    SourceRefused { origin: String, incoming: Source, owner: Source },
    #[error("origin limit exceeded")]
    OriginLimit,
    #[error("origin held row limit exceeded")]
    HeldRowLimit,
}

impl HubError {
    fn page_error(error: std::io::Error) -> Self {
        if error.kind() == std::io::ErrorKind::InvalidInput {
            Self::InvalidParams(error.to_string())
        } else {
            error.into()
        }
    }
}

impl From<std::io::Error> for HubError {
    fn from(error: std::io::Error) -> Self {
        if error.get_ref().is_some_and(|inner| inner.is::<acpmux_book::index::CursorGone>()) {
            Self::CursorGone
        } else {
            Self::Log(error)
        }
    }
}

impl Hub {
    /// One disk start order. Call from a blocking worker; the first window
    /// needs only the fixed head, the bounded log tail, and one snapshot page.
    pub fn open(
        directory: &std::path::Path,
        boot: u64,
        random: impl FnOnce() -> u32,
    ) -> Result<(Self, HubWriter), HubError> {
        std::fs::create_dir_all(directory)?;
        let snapshot_path = directory.join("index.snap");
        let mut rebuild = false;
        let disk = match DiskSnapshot::open(&snapshot_path) {
            Ok(Some(disk)) => match disk.validate_checkpoints() {
                Ok(()) => Some(disk),
                Err(error) if acpmux_book::index::is_fatal_snapshot_read(&error) => {
                    rebuild = true;
                    None
                }
                Err(error) => return Err(error.into()),
            },
            Ok(None) => None,
            Err(error) if acpmux_book::index::is_fatal_snapshot_read(&error) => {
                rebuild = true;
                None
            }
            Err(error) => return Err(error.into()),
        };
        let log = if rebuild {
            None
        } else {
            match IndexLog::open_with_snapshot(directory.join("index.log"), disk.as_deref()) {
                Ok(log) => Some(log),
                Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                    rebuild = true;
                    None
                }
                Err(error) => return Err(error.into()),
            }
        };
        if rebuild {
            quarantine_index(directory)?;
            let edition = IndexEdition::open_rebuild(directory, boot, random)?;
            let log = IndexLog::open_with_snapshot(directory.join("index.log"), None)?;
            let index = SummaryIndex::empty_with_edition(edition.edition);
            return Ok(Self::with_log_state(index, Some(log), Some(directory), 1));
        }
        let log = log.expect("non-rebuild open has a log");
        let edition = IndexEdition::open(
            directory,
            boot,
            disk.as_ref().is_some_and(|disk| !disk.is_empty()) || log.next_seq() != 0,
            random,
        )?;
        let covered = disk.as_ref().map_or(0, |disk| disk.covered_generation());
        let index = match replay_generation_logs(
            directory,
            covered,
            SummaryIndex::from_disk(disk, edition.edition),
        ) {
            Ok(index) => index,
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                drop(log);
                quarantine_index(directory)?;
                let edition = IndexEdition::open_rebuild(directory, boot, || 2)?;
                let log = IndexLog::open_with_snapshot(directory.join("index.log"), None)?;
                let index = SummaryIndex::empty_with_edition(edition.edition);
                return Ok(Self::with_log_state(index, Some(log), Some(directory), 1));
            }
            Err(error) => return Err(error.into()),
        };
        Ok(Self::with_log_state(index, Some(log), Some(directory), 0))
    }

    /// Creates a hub and its one writer. No task is spawned implicitly, so the
    /// caller controls the runtime and shutdown boundary.
    pub fn new(index: SummaryIndex) -> (Self, HubWriter) {
        Self::with_log(index, None)
    }

    pub fn with_log(index: SummaryIndex, log: Option<IndexLog>) -> (Self, HubWriter) {
        let directory =
            log.as_ref().and_then(|log| log.active_path().parent().map(Path::to_path_buf));
        Self::with_log_state(index, log, directory.as_deref(), 0)
    }

    fn with_log_state(
        index: SummaryIndex,
        log: Option<IndexLog>,
        directory: Option<&Path>,
        rebuilds: u64,
    ) -> (Self, HubWriter) {
        let state = if index.disk().is_none() {
            disk::HydrationState::Ready
        } else {
            disk::HydrationState::Loading
        };
        let (hydrated_tx, hydrated_rx) = tokio::sync::watch::channel(state);
        let sources = Arc::new(ArcSwap::from_pointee(HashMap::new()));
        let rebuild_requested = Arc::new(AtomicBool::new(false));
        let rebuild_count = Arc::new(AtomicU64::new(rebuilds));
        let has_disk = index.disk().is_some();
        let published = Arc::new(ArcSwap::from_pointee(index));
        let updates = Arc::new(UpdateQueue::new());
        let subscribers = Arc::new(Mutex::new(Vec::with_capacity(EVENT_CAPACITY)));
        let history = Arc::new(Mutex::new(History::new()));
        let folder_state = Arc::new(Mutex::new(folders::FolderState::default()));
        let log_errors = Arc::new(AtomicU64::new(0));
        let compaction_counters = Arc::new(compaction::Counters::default());
        compaction_counters
            .oldest_seq
            .store(log.as_ref().map_or(1, IndexLog::oldest_seq), Ordering::Release);
        let hub = Self {
            hydrated: hydrated_rx,
            compaction_counters: compaction_counters.clone(),
            published: published.clone(),
            updates: updates.clone(),
            subscribers: subscribers.clone(),
            history: history.clone(),
            folder_state: folder_state.clone(),
            page_provider: Arc::new(Mutex::new(None)),
            sources: sources.clone(),
            rebuild_requested: rebuild_requested.clone(),
            rebuild_count: rebuild_count.clone(),
        };
        let mut writer = HubWriter {
            hydrated: hydrated_tx,
            #[cfg(test)]
            turn_measure: disk::TurnMeasure::default(),
            compaction: None,
            retirement: None,
            maintenance: None,
            // A rotated generation without its installed snapshot is work
            // recovered at open. Resume it even if no new summary arrives.
            next_compaction: log
                .as_ref()
                .filter(|log| log.retained_bytes() > log.offset())
                .map(|_| std::time::Instant::now()),
            storage_retry: None,
            compaction_backoff: 0,
            compaction_counters,
            published,
            updates,
            subscribers,
            history,
            folder_state,
            log,
            log_dirty: false,
            log_errors,
            retry_log: HashMap::new(),
            hydration: None,
            sources,
            origins: origins::WriterOrigins::default(),
            directory: directory.map(Path::to_path_buf),
            rebuild_requested,
            rebuild_count,
        };
        if has_disk {
            writer.start_hydration();
        } else {
            writer.hydrated.send_replace(disk::HydrationState::Ready);
        }
        (hub, writer)
    }

    /// The remote tee keeps startup changes as marks until all live snapshot
    /// rows are hot. No second queue of summaries is needed for startup.
    pub async fn wait_hydrated(&self) -> Result<(), HubError> {
        let mut hydrated = self.hydrated.clone();
        let state = *hydrated
            .wait_for(|state| *state != disk::HydrationState::Loading)
            .await
            .map_err(|_| HubError::WriterGone)?;
        match state {
            disk::HydrationState::Ready => Ok(()),
            disk::HydrationState::Failed => Err(HubError::HydrationFailed),
            disk::HydrationState::Loading => Err(HubError::WriterGone),
        }
    }

    /// Number of index rebuilds observed by this hub instance. Sources can
    /// retain this value and walk again when it changes.
    pub fn rebuild_count(&self) -> u64 {
        self.rebuild_count.load(Ordering::Acquire)
    }

    /// Ends a source's rebuild walk. An incomplete walk leaves existing list
    /// subscribers untouched; only a whole local walk fences each sid to one
    /// fresh window through the connection's existing lagged-resume path.
    pub fn source_walk_finished(&self, source: Source, complete: bool) {
        if source != Source::Local || !complete {
            return;
        }
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            if let Ok(mut state) = subscriber.state.lock() {
                if !state.window_pending {
                    state.window_pending = true;
                    subscriber.notify.notify_one();
                }
            }
        }
    }

    fn request_rebuild(&self) {
        self.rebuild_requested.store(true, Ordering::Release);
        // A page reader can be the only activity after the writer has gone
        // idle. Wake the one writer so it owns the quarantine and compaction
        // turn instead of waiting for a later summary submission.
        self.updates.notify.notify_one();
    }

    /// A non-blocking enqueue: actor work never waits on list size. The
    /// bounded queue is the writer's backpressure boundary.
    pub fn submit(&self, summary: Summary) -> Result<(), HubError> {
        let source = Source::default_for(&summary.origin);
        self.submit_from(source, summary)
    }

    pub fn submit_from(&self, source: Source, summary: Summary) -> Result<(), HubError> {
        self.updates.submit(source, summary.prepare()?)
    }

    /// Enqueues a removal in the same keyed slot as summary updates. A later
    /// summary for this chat replaces the removal before the writer takes its
    /// batch, so a burst cannot grow with the number of events.
    pub fn remove(&self, origin: &str, chat_id: &str) -> Result<(), HubError> {
        self.remove_from(Source::default_for(origin), origin, chat_id)
    }

    pub fn remove_from(&self, source: Source, origin: &str, chat_id: &str) -> Result<(), HubError> {
        let key = RowKey::new(origin, chat_id);
        key.validate()?;
        self.updates.submit_remove(source, key)
    }

    pub fn origin(&self, id: &str, state: OriginState, since: u64) -> Result<(), HubError> {
        if id == "local" {
            return Ok(());
        }
        origins::validate_id(id)?;
        let record = OriginRecord { seq: 0, id: id.to_owned(), state, since, extra: None };
        self.updates.enqueue(UpdateKey::Origin(id.into()), PendingUpdate::Origin { record })
    }

    pub fn takeover(&self, origin: &str, source: Source) -> Result<(), HubError> {
        origins::validate_takeover(origin, source)?;
        self.updates.enqueue(
            UpdateKey::Source(origin.into()),
            PendingUpdate::Takeover { origin: origin.to_owned(), source },
        )
    }

    /// One published read lets the v1 mark skip origins owned by the mirror.
    pub fn source(&self, origin: &str) -> Option<Source> {
        if origin == "local" {
            Some(Source::Local)
        } else {
            self.sources.load().get(origin).copied()
        }
    }

    pub fn snapshot(&self) -> Arc<SummaryIndex> {
        self.published.load_full()
    }

    #[cfg(test)]
    pub(crate) fn reset_history_encoded_ops(&self) {
        if let Ok(history) = self.history.lock() {
            history.reset_encoded_ops();
        }
    }

    #[cfg(test)]
    pub(crate) fn history_encoded_ops(&self) -> usize {
        self.history.lock().map_or(0, |history| history.encoded_ops())
    }

    #[cfg(test)]
    pub(crate) fn reset_history_raw_copies(&self) {
        if let Ok(history) = self.history.lock() {
            history.reset_raw_copies();
        }
    }

    #[cfg(test)]
    pub(crate) fn history_raw_copies(&self) -> usize {
        self.history.lock().map_or(0, |history| history.raw_copies())
    }

    pub fn set_page_provider(&self, provider: Arc<dyn PageProvider>) {
        if let Ok(mut slot) = self.page_provider.lock() {
            *slot = Some(provider);
        }
    }

    pub fn resume_target(&self, cursor: u64) -> Result<Option<u64>, HubError> {
        let history = self.history.lock().map_err(|_| HubError::WriterGone)?;
        let target = history.last_seq().unwrap_or_else(|| self.published.load().seq());
        if cursor > target
            || history.first_seq().is_some_and(|first| cursor.saturating_add(1) < first)
            || (history.first_seq().is_none() && cursor != target)
        {
            return Ok(None);
        }
        Ok(Some(target))
    }

    /// Wakes a writer task and prevents any later submit from waiting for it.
    pub fn close(&self) {
        self.updates.close();
    }

    pub fn subscriber_count(&self) -> usize {
        self.subscribers.lock().map(|subscribers| subscribers.len()).unwrap_or(0)
    }

    pub fn subscribe(&self, sub: &Sub) -> Result<ListSubscription, HubError> {
        if sub.stream.as_str() != "list" {
            return Err(HubError::WrongStream(sub.stream.as_str().to_owned()));
        }
        validate_window(sub)?;
        let cursor = sub.cursor.map_or(0, |cursor| cursor.0);
        let index = self.snapshot();
        let edition_matches =
            sub.edition.is_none_or(|edition| edition == 0 || edition == index.edition());
        let resume_cursor = if !folders::is_folders(sub.view)
            && edition_matches
            && sub.cursor.is_some()
            && self.resume_target(cursor)?.is_some()
        {
            cursor
        } else {
            index.seq()
        };
        let frame = self.window_frame_at_cursor(sub, &index, resume_cursor)?;
        let resume_cursor = if folders::is_folders(sub.view) {
            frame.decode_json::<crate::wire::FolderWindow>()?.cursor
        } else {
            resume_cursor
        };
        let subscriber = Arc::new(Subscriber::new(resume_cursor));
        self.subscribers.lock().map_err(|_| HubError::WriterGone)?.push(subscriber.clone());
        Ok(ListSubscription {
            window: frame,
            cursor: if folders::is_folders(sub.view) { resume_cursor } else { index.seq() },
            receiver: ListReceiver {
                subscriber,
                subscribers: self.subscribers.clone(),
                history: self.history.clone(),
                folder_state: self.folder_state.clone(),
                folders: folders::is_folders(sub.view),
                published: self.published.clone(),
            },
        })
    }

    /// Registers a subscriber at a retained cursor without constructing a
    /// window. Resume callers use this path when the first response is a raw
    /// ring span; a window is built only on a fresh or lagged resume.
    pub fn subscribe_replay(&self, sub: &Sub, cursor: u64) -> Result<ListReceiver, HubError> {
        if sub.stream.as_str() != "list" {
            return Err(HubError::WrongStream(sub.stream.as_str().to_owned()));
        }
        validate_window(sub)?;
        if folders::is_folders(sub.view) {
            return Err(HubError::InvalidParams("folders always starts with a window".into()));
        }
        let subscriber = Arc::new(Subscriber::new(cursor));
        self.subscribers.lock().map_err(|_| HubError::WriterGone)?.push(subscriber.clone());
        Ok(ListReceiver {
            subscriber,
            subscribers: self.subscribers.clone(),
            history: self.history.clone(),
            folder_state: self.folder_state.clone(),
            folders: folders::is_folders(sub.view),
            published: self.published.clone(),
        })
    }

    /// Builds one bounded first frame from the current published index. It does
    /// not hydrate chats or construct a whole-list reply.
    pub fn list_window(&self, sub: &Sub) -> Result<Frame, HubError> {
        if sub.stream.as_str() != "list" {
            return Err(HubError::WrongStream(sub.stream.as_str().to_owned()));
        }
        validate_window(sub)?;
        let index = self.snapshot();
        self.window_frame_at_cursor(sub, &index, index.seq())
    }

    fn window_frame_at_cursor(
        &self,
        sub: &Sub,
        index: &SummaryIndex,
        cursor: u64,
    ) -> Result<Frame, HubError> {
        let requested = validate_window(sub)?;
        if folders::is_folders(sub.view) {
            return self.folder_window(sub);
        }
        let (key, side) = match sub.anchor.as_ref() {
            Some(crate::wire::Anchor::List { key, side }) => (
                Some(book_key(key)),
                match side {
                    crate::wire::AnchorSide::Before => ReadSide::Before,
                    crate::wire::AnchorSide::After => ReadSide::After,
                    crate::wire::AnchorSide::Around => ReadSide::Around,
                },
            ),
            _ => (None, ReadSide::After),
        };
        let page = if matches!(sub.view, Some(crate::wire::ListView::Live)) {
            index
                .read_live_page(
                    key.as_ref(),
                    side,
                    true,
                    requested,
                    crate::wire::MAX_PAGE_BYTES.saturating_sub(8192 + sub.sid.len()),
                    sub.filter.as_ref(),
                )
                .map_err(|error| self.page_error(error))?
        } else {
            index
                .read_page(
                    key.as_ref(),
                    side,
                    true,
                    requested,
                    crate::wire::MAX_PAGE_BYTES.saturating_sub(8192 + sub.sid.len()),
                    sub.filter.as_ref(),
                )
                .map_err(|error| self.page_error(error))?
        };
        let window = Window {
            sid: sub.sid.clone(),
            cursor,
            rows: page.rows.iter().map(Arc::as_ref).collect::<Vec<_>>(),
            has_before: page.has_before,
            has_after: page.has_after,
            edition: index.edition(),
            origins: index
                .origins()
                .map(|origin| Origin {
                    id: origin.id.clone(),
                    state: origin.state,
                    since: origin.since,
                    extra: origin
                        .extra
                        .as_ref()
                        .and_then(|extra| serde_json::from_str(extra.get()).ok()),
                })
                .collect(),
            before_key: page.before_key.map(wire_key),
            after_key: page.after_key.map(wire_key),
        };
        let frame = Frame::json(FrameKind::Window, &window)?;
        if frame.encoded_len() > crate::wire::MAX_PAGE_BYTES {
            return Err(HubError::InvalidWindow);
        }
        Ok(frame)
    }

    /// The connection supplies the view held by this sid. Row types cannot
    /// change during a subscription; a caller opens another sid for chat rows.
    pub fn page_for_view(
        &self,
        request: &crate::wire::Page,
        held_view: Option<crate::wire::ListView>,
    ) -> Result<Frame, HubError> {
        if folders::is_folders(held_view) != folders::is_folders(request.view) {
            return Err(HubError::InvalidPage);
        }
        self.page(request)
    }

    pub fn page(&self, request: &crate::wire::Page) -> Result<Frame, HubError> {
        if request.stream.as_str() != "list" {
            return Err(HubError::WrongStream(request.stream.as_str().to_owned()));
        }
        if matches!(request.view, Some(crate::wire::ListView::Live))
            && request.filter.as_ref().is_some_and(|filter| {
                filter.family.is_some()
                    || filter.forks.is_some()
                    || filter.folder.is_some()
                    || filter.cold
            })
        {
            return Err(HubError::InvalidParams("table filters require the all view".into()));
        }
        let max = request.max_bytes as usize;
        if max > crate::wire::MAX_PAGE_BYTES || max <= 8192 + request.sid.len() {
            return Err(HubError::InvalidPage);
        }
        if request.view == Some(crate::wire::ListView::Live)
            && request.filter.as_ref().is_some_and(|filter| {
                filter.family.is_some()
                    || filter.forks.is_some()
                    || filter.folder.is_some()
                    || filter.cold
            })
        {
            return Err(HubError::InvalidPage);
        }
        if folders::is_folders(request.view) {
            return self.folder_page(request);
        }
        if let Some(keys) = request.keys.as_ref() {
            if keys.is_empty()
                || keys.len() > 100
                || request.before.is_some()
                || request.after.is_some()
            {
                return Err(HubError::InvalidPage);
            }
            return self.keyed_page(request, keys);
        }
        let (key, side) = match request.side() {
            Some((side, crate::wire::Position::List(key))) => (
                Some(book_key(key)),
                match side {
                    crate::wire::PageSide::Before => ReadSide::Before,
                    crate::wire::PageSide::After => ReadSide::After,
                },
            ),
            // A bounded page without an anchor starts a mirror walk at the
            // head. Filters may narrow it, but they are not required.
            None if request.before.is_none() && request.after.is_none() => (None, ReadSide::After),
            _ => return Err(HubError::InvalidPage),
        };
        let index = self.snapshot();
        let page = if matches!(request.view, Some(crate::wire::ListView::Live)) {
            index
                .read_live_page(
                    key.as_ref(),
                    side,
                    false,
                    MAX_WINDOW_ROWS,
                    max - 8192 - request.sid.len(),
                    request.filter.as_ref(),
                )
                .map_err(|error| self.page_error(error))?
        } else {
            index
                .read_page(
                    key.as_ref(),
                    side,
                    false,
                    MAX_WINDOW_ROWS,
                    max - 8192 - request.sid.len(),
                    request.filter.as_ref(),
                )
                .map_err(|error| self.page_error(error))?
        };
        let reply = crate::wire::PageResult {
            sid: request.sid.clone(),
            rows: page.rows.iter().map(Arc::as_ref).collect::<Vec<_>>(),
            has_before: page.has_before,
            has_after: page.has_after,
            cold_unread: page.cold_unread,
            deeper: page.deeper.into_iter().map(wire_key).collect(),
            before_key: page.before_key.map(wire_key),
            after_key: page.after_key.map(wire_key),
            missing: Vec::new(),
            unknown: Vec::new(),
            rest: Vec::new(),
        };
        let frame = Frame::json(FrameKind::Page, &reply)?;
        if frame.encoded_len() > max {
            return Err(HubError::InvalidPage);
        }
        Ok(frame)
    }

    fn page_error(&self, error: std::io::Error) -> HubError {
        if acpmux_book::index::is_fatal_snapshot_read(&error) {
            self.request_rebuild();
        }
        HubError::page_error(error)
    }
}

fn book_key(key: &crate::wire::ListKey) -> SortKey {
    SortKey {
        last_activity: key.last_activity,
        row: RowKey::new(key.origin.as_str(), key.chat_id.as_str()),
    }
}

fn wire_key(key: SortKey) -> crate::wire::ListKey {
    crate::wire::ListKey {
        last_activity: key.last_activity,
        chat_id: key.row.chat_id.to_string(),
        origin: key.row.origin.to_string(),
    }
}

fn validate_window(sub: &Sub) -> Result<usize, HubError> {
    if folders::is_folders(sub.view)
        && (sub.filter.is_some() || !matches!(sub.anchor, None | Some(crate::wire::Anchor::End)))
    {
        return Err(HubError::InvalidWindow);
    }
    if sub.filter.as_ref().is_some_and(|filter| {
        filter.family.is_some() || filter.forks.is_some() || filter.folder.is_some() || filter.cold
    }) {
        return Err(HubError::InvalidParams("table filters are page-only".into()));
    }
    let requested = usize::from(sub.window.unwrap_or(DEFAULT_WINDOW_ROWS as u16));
    if requested == 0 || requested > MAX_WINDOW_ROWS {
        return Err(HubError::InvalidWindow);
    }
    Ok(requested)
}

impl HubWriter {
    /// Applies one summary and publishes the resulting immutable snapshot.
    pub fn apply(&mut self, summary: Summary) -> Result<SummaryEvent, HubError> {
        let source = Source::default_for(&summary.origin);
        self.apply_internal(source, summary)
    }

    pub fn apply_from(
        &mut self,
        source: Source,
        summary: Summary,
    ) -> Result<SummaryEvent, HubError> {
        self.apply_internal(source, summary)
    }

    fn apply_internal(
        &mut self,
        source: Source,
        summary: Summary,
    ) -> Result<SummaryEvent, HubError> {
        let summary = summary.prepare()?;
        let key = summary.key();
        if self.holds_origin(&summary.origin) {
            let event = SummaryEvent {
                seq: self.published.load().seq(),
                summary: Arc::new(summary.clone()),
            };
            self.hold_update(
                UpdateKey::Row(key),
                PendingUpdate::Summary { source, summary: Box::new(summary) },
            )?;
            return Ok(event);
        }
        let current = self.published.load_full();
        self.check_source(source, &summary.origin)?;
        if summary.origin != "local"
            && !self.origins.releasing
            && self.origins.ended.contains_key(summary.origin.as_str())
            && current
                .origin(&summary.origin)
                .is_some_and(|origin| origin.state == OriginState::Removed)
        {
            return Ok(SummaryEvent { seq: current.seq(), summary: Arc::new(summary) });
        }
        // Latest wins even if an earlier version never reached the log.
        self.retry_log.remove(&key);
        if summary.origin != "local" && !summary.is_live() && current.get_row(&key).is_none() {
            // The remote tee waits for hot hydration before draining its marks.
            // Every retained remote row is live and therefore hot (decision 139).
            return Ok(SummaryEvent { seq: current.seq(), summary: Arc::new(summary) });
        }
        let record = acpmux_book::index::IndexRecord {
            seq: current.seq().saturating_add(1),
            origin: summary.origin.clone(),
            chat_id: summary.chat_id.clone(),
            summary,
            gone: false,
        };
        let existing = match current.get_row(&key) {
            Some(row) => Some(row),
            None if !current.is_shadowed(&key)
                && !current.is_origin_leaving(key.origin.as_ref())
                && !current.is_snapshot_origin_hidden(key.origin.as_ref()) =>
            {
                if let Some(disk) = current.disk() {
                    #[cfg(test)]
                    {
                        self.turn_measure.apply_snapshot_pieces += 1;
                    }
                    match disk.read_piece(
                        Some(&SortKey::of(&record.summary)),
                        ReadSide::After,
                        true,
                        1,
                        crate::wire::MAX_PAGE_BYTES,
                    ) {
                        Ok(piece) => piece.rows.into_iter().find(|row| row.key() == key),
                        Err(_) => {
                            // Equality is an optimization. A damaged cold row
                            // must not prevent its replacement reaching the log.
                            self.log_errors.fetch_add(1, Ordering::Relaxed);
                            None
                        }
                    }
                } else {
                    None
                }
            }
            None => None,
        };
        if let Some(existing) = existing
            && existing.same_content(&record.summary)
        {
            // The returned row is unchanged; no event is published.
            return Ok(SummaryEvent { seq: current.seq(), summary: existing });
        }
        self.persist(source, &record, &key)?;
        let next = self.published.load_full().apply_summary(record.seq, record.summary.clone());
        let folder_ops = next.folder_changes(
            &current,
            current.get_row(&key).as_deref(),
            next.get_row(&key).as_deref(),
        );
        let summary = Arc::new(record.summary.clone());
        let event = SummaryEvent { seq: record.seq, summary };
        self.publish_folder_index(next, &folder_ops);
        self.record_history(ListItem::Summary(event.clone()));
        self.publish(event.clone());
        Ok(event)
    }

    fn publish(&self, event: SummaryEvent) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            let Ok(state) = subscriber.state.lock() else { continue };
            if event.seq > state.cursor && !state.ended {
                subscriber.notify.notify_one();
            }
        }
    }

    pub fn remove(&mut self, origin: &str, chat_id: &str) -> Result<bool, HubError> {
        self.remove_from(Source::default_for(origin), origin, chat_id)
    }

    pub fn remove_from(
        &mut self,
        source: Source,
        origin: &str,
        chat_id: &str,
    ) -> Result<bool, HubError> {
        let key = RowKey::new(origin, chat_id);
        key.validate()?;
        if self.holds_origin(origin) {
            self.hold_update(UpdateKey::Row(key), PendingUpdate::Gone { source })?;
            return Ok(false);
        }
        self.check_source(source, origin)?;
        if !self.origins.releasing
            && self.origins.ended.contains_key(origin)
            && self
                .published
                .load()
                .origin(origin)
                .is_some_and(|record| record.state == OriginState::Removed)
        {
            return Ok(false);
        }
        self.apply_remove(source, &key)
    }

    fn apply_remove(&mut self, source: Source, key: &RowKey) -> Result<bool, HubError> {
        key.validate()?;
        self.retry_log.remove(key);
        let current = self.published.load_full();
        if current.get_row(key).is_none()
            && (current.disk().is_none()
                || current.is_shadowed(key)
                || current.is_snapshot_origin_hidden(key.origin.as_ref()))
        {
            return Ok(false);
        }
        let seq = current.seq().saturating_add(1);
        self.persist(
            source,
            &acpmux_book::index::IndexRecord {
                seq,
                origin: key.origin.to_string(),
                chat_id: key.chat_id.to_string(),
                summary: Summary::new(key.chat_id.to_string()),
                gone: true,
            },
            key,
        )?;
        let Some(next) = current.remove_row(seq, key) else {
            return Ok(false);
        };
        let folder_ops = next.folder_changes(&current, current.get_row(key).as_deref(), None);
        self.publish_folder_index(next, &folder_ops);
        self.record_history(ListItem::Gone {
            seq,
            chat_id: key.chat_id.to_string(),
            origin: key.origin.to_string(),
        });
        self.publish_gone(seq, key);
        Ok(true)
    }

    fn publish_gone(&self, seq: u64, _key: &RowKey) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            let Ok(state) = subscriber.state.lock() else { continue };
            if seq > state.cursor && !state.ended {
                subscriber.notify.notify_one();
            }
        }
    }

    fn publish_origin(&self, seq: u64, _origin: Origin) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            let Ok(state) = subscriber.state.lock() else { continue };
            if seq > state.cursor && !state.ended {
                subscriber.notify.notify_one();
            }
        }
    }

    fn record_history(&self, item: ListItem) {
        if let Ok(mut history) = self.history.lock()
            && history.append(&item).is_err()
        {
            self.log_errors.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Disk writes, group syncs and hydration run off runtime workers.
    pub async fn run(mut self) -> Result<(), HubError> {
        loop {
            self.finish_compaction(false).await;
            let (pending, closed) = {
                let pending = self.updates.pending.lock().map_err(|_| HubError::WriterGone)?;
                (pending.is_empty(), self.updates.closed.load(Ordering::Acquire))
            };
            if pending && closed && !self.origin_work_pending() && self.hydration.is_none() {
                break;
            }
            if pending
                && self.hydration.is_none()
                && !self.maintenance_needs_turn()
                && !self.origin_work_pending()
            {
                // Compaction needs a healthy log. A past compaction deadline
                // must not bypass the storage failure's retry backoff.
                let retry = if self.retirement.is_some() {
                    self.storage_retry
                } else {
                    self.storage_retry.or(self.next_compaction)
                };
                tokio::select! {
                    () = self.updates.notify.notified() => {},
                    () = async {
                        if let Some(job) = self.compaction.as_mut() { job.wait_ready().await; }
                        else { std::future::pending::<()>().await; }
                    } => {},
                    () = async {
                        if let Some(retirement) = self.retirement.as_mut() {
                            let _ = retirement.await;
                            self.retirement = None;
                        } else { std::future::pending::<()>().await; }
                    } => {},
                    () = async {
                        if let Some(retry) = retry { tokio::time::sleep_until(retry.into()).await; }
                        else { std::future::pending::<()>().await; }
                    } => {},
                }
            }
            self = tokio::task::spawn_blocking(move || {
                self.process_batch();
                self
            })
            .await
            .map_err(|_| HubError::WriterGone)?;
        }
        self.finish_compaction(true).await;
        let result = loop {
            let (writer, result) = tokio::task::spawn_blocking(move || {
                self.install_compaction();
                self.maintain_compaction();
                let used = self.advance_origins(128);
                let result = self.sync_batch_limit(256usize.saturating_sub(used));
                (self, result)
            })
            .await
            .map_err(|_| HubError::WriterGone)?;
            self = writer;
            self.finish_compaction(true).await;
            if result.is_err()
                || (self.retry_log.is_empty()
                    && self.origins.retry.is_empty()
                    && self.maintenance.is_none()
                    && !self.origin_work_pending())
            {
                break result;
            }
        };
        // The last published maps may belong to this writer alone.
        tokio::task::spawn_blocking(move || drop(self)).await.map_err(|_| HubError::WriterGone)?;
        result
    }

    pub fn close(&self) {
        self.updates.close();
    }

    pub fn log_errors(&self) -> u64 {
        self.log_errors.load(Ordering::Relaxed)
    }
}

fn quarantine_index(directory: &Path) -> std::io::Result<()> {
    let bad = directory.join("index.bad");
    fs::create_dir_all(&bad)?;
    // Keep exactly one recoverable set. The directory is owned by this index
    // recovery path, so old entries are safe to remove before the next move.
    for entry in fs::read_dir(&bad)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            fs::remove_file(entry.path())?;
        }
    }
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name();
        if name == std::ffi::OsStr::new("index.edition") {
            continue;
        }
        let Some(name_str) = name.to_str() else { continue };
        if !name_str.starts_with("index.") {
            continue;
        }
        let target = bad.join(&name);
        if target.exists() {
            fs::remove_file(&target)?;
        }
        fs::rename(entry.path(), target)?;
    }
    fs::File::open(directory)?.sync_all()?;
    fs::File::open(&bad)?.sync_all()?;
    Ok(())
}

/// A wire delta frame helper shared by the list and chat lanes.
pub fn delta_frame(delta: &DeltaFrame<Summary>) -> Result<Frame, FrameError> {
    crate::wire::delta_frame(delta)
}

#[cfg(test)]
mod compaction_gate;
#[cfg(test)]
mod compaction_tests;
#[cfg(test)]
mod disk_gates;
#[cfg(test)]
mod folder_gates;
#[cfg(test)]
mod kin_tests;
#[cfg(test)]
mod origin_gates;
#[cfg(test)]
mod origin_tests;
#[cfg(test)]
mod rebuild_tests;
#[cfg(test)]
mod storage_tests;
#[cfg(test)]
mod writer_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Cursor, Stream};
    use acpmux_book::index::replay_log;
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::time::{Duration, Instant};
    use tempfile::tempdir;

    fn summary(id: &str, at: u64) -> Summary {
        let mut summary = Summary::new(id);
        summary.last_activity = at;
        summary
    }

    fn gate(name: &str, small: u128, god: u128, god_all: u128) {
        let line = format!(
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"ns\"}}"
        );
        eprintln!("{line}");
        if let Ok(path) = std::env::var("V2_GATE_OUT")
            && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }

    fn populated_index(prefix: &str, count: usize) -> SummaryIndex {
        (0..count).fold(SummaryIndex::new(), |index, n| {
            index.apply((n + 1) as u64, summary(&format!("{prefix}{n}"), n as u64))
        })
    }

    fn p95(samples: &[u128]) -> u128 {
        let mut sorted = samples.to_vec();
        sorted.sort_unstable();
        let rank = ((sorted.len() * 95).saturating_add(99) / 100).saturating_sub(1);
        sorted[rank]
    }

    fn best_p95(rounds: &[Vec<u128>]) -> u128 {
        rounds.iter().map(|round| p95(round)).min().unwrap_or(1)
    }

    async fn measure_first_windows(index: SummaryIndex, sid: &str) -> Vec<Vec<u128>> {
        let (hub, writer) = Hub::new(index);
        let task = tokio::spawn(writer.run());
        let mut rounds = Vec::with_capacity(5);
        for round in 0..5 {
            let mut samples = Vec::with_capacity(200);
            for sample in 0..200 {
                let start = Instant::now();
                let mut sub = Sub::new(format!("{sid}-{round}-{sample}"), Stream::from("list"));
                sub.window = Some(20);
                let subscription = hub.subscribe(&sub).unwrap();
                let _: Window<Summary> = subscription.window.decode_json().unwrap();
                samples.push(start.elapsed().as_nanos().max(1));
                drop(subscription);
            }
            rounds.push(samples);
        }
        hub.close();
        task.await.unwrap().unwrap();
        rounds
    }

    fn measure_summary_changes(index: &SummaryIndex, chat_id: &str) -> Vec<Vec<u128>> {
        let mut rounds = Vec::with_capacity(5);
        for round in 0..5 {
            let (hub, mut writer) = Hub::new(index.clone());
            let _subscription =
                hub.subscribe(&Sub::new(format!("change-{round}"), Stream::from("list"))).unwrap();
            let mut samples = Vec::with_capacity(200);
            for sample in 0..200 {
                let start = Instant::now();
                writer.apply(summary(chat_id, (round * 5 + sample + 1) as u64)).unwrap();
                samples.push(start.elapsed().as_nanos().max(1));
            }
            rounds.push(samples);
        }
        rounds
    }

    #[test]
    fn one_summary_change_publishes_without_walking_the_index() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("a", 1)).unwrap();
        writer.apply(summary("b", 2)).unwrap();
        let event = writer.apply(summary("a", 3)).unwrap();
        assert_eq!(event.seq, 3);
        assert_eq!(hub.snapshot().len(), 2);
        let frame = hub.list_window(&Sub::new("sidebar", Stream::from("list"))).unwrap();
        let window: Window<Summary> = frame.decode_json().unwrap();
        assert_eq!(window.rows.first().map(|row| row.chat_id.as_str()), Some("a"));
        assert!(window.rows.len() <= DEFAULT_WINDOW_ROWS);
    }

    #[test]
    fn list_window_is_bounded_and_rejects_other_streams() {
        let (hub, _) = Hub::new(SummaryIndex::new());
        assert!(matches!(
            hub.list_window(&Sub::new("chat", "chat:one")),
            Err(HubError::WrongStream(_))
        ));
        assert!(matches!(
            hub.list_window(&Sub::new("sidebar", "list").around(crate::wire::Anchor::End, 0)),
            Err(HubError::InvalidWindow)
        ));
    }

    #[test]
    fn subscribe_rejects_oversized_window_before_registration() {
        let (hub, _) = Hub::new(SummaryIndex::new());
        let sub = Sub::new("oversized", "list").around(crate::wire::Anchor::End, u16::MAX);
        assert!(matches!(hub.subscribe(&sub), Err(HubError::InvalidWindow)));
        assert_eq!(hub.subscriber_count(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    #[ignore = "timing gate; run in release with --ignored --nocapture"]
    async fn list_window_gate_measures_running_subscriptions_at_both_sizes() {
        let small_rounds = measure_first_windows(populated_index("s", 20), "small").await;
        let god_rounds = measure_first_windows(populated_index("g", 11_000), "god").await;
        let small_p95 = best_p95(&small_rounds);
        let god_p95 = best_p95(&god_rounds);
        let all_god_samples = god_rounds.iter().flatten().copied().collect::<Vec<_>>();
        let all_god_p95 = p95(&all_god_samples);
        assert!(
            god_p95 <= small_p95.saturating_mul(12) / 10,
            "first window p95 grew beyond 1.2x: small={small_p95}ns god={god_p95}ns"
        );
        assert!(
            all_god_p95 <= small_p95.saturating_mul(2),
            "first window all-sample p95 exceeded 2x small p95: small={small_p95}ns god={all_god_p95}ns"
        );
        gate("v2.pr05.first_list_window", small_p95, god_p95, all_god_p95);

        let small_index = populated_index("s", 20);
        let god_index = populated_index("g", 11_000);
        let small_changes = measure_summary_changes(&small_index, "s0");
        let god_changes = measure_summary_changes(&god_index, "g0");
        let small_change_p95 = best_p95(&small_changes);
        let god_change_p95 = best_p95(&god_changes);
        let all_god_change_samples = god_changes.iter().flatten().copied().collect::<Vec<_>>();
        let all_god_change_p95 = p95(&all_god_change_samples);
        assert!(
            god_change_p95 <= small_change_p95.saturating_mul(37) / 10,
            "summary change p95 grew beyond 3.7x: small={small_change_p95}ns god={god_change_p95}ns"
        );
        assert!(
            all_god_change_p95 <= small_change_p95.saturating_mul(62) / 10,
            "summary change all-sample p95 exceeded 6.2x small p95: small={small_change_p95}ns god={all_god_change_p95}ns"
        );
        assert!(
            god_change_p95 <= 10_000,
            "summary change god p95 exceeded 10us: {god_change_p95}ns"
        );
        gate("v2.pr05.summary_change", small_change_p95, god_change_p95, all_god_change_p95);
    }

    #[test]
    fn opening_11k_rows_from_disk_reaches_first_window_under_200ms() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        {
            let mut log = IndexLog::open(&log_path).unwrap();
            for n in 0..11_000 {
                log.append(summary(&format!("disk{n}"), n as u64)).unwrap();
            }
            log.sync().unwrap();
        }

        let start = Instant::now();
        let log = IndexLog::open(&log_path).unwrap();
        let index = replay_log(log.path(), SummaryIndex::new()).unwrap();
        assert_eq!(index.len(), 11_000);
        let (hub, _writer) = Hub::with_log(index, Some(log));
        let window = hub.list_window(&Sub::new("disk", "list")).unwrap();
        let _: Window<Summary> = window.decode_json().unwrap();
        let elapsed = start.elapsed();
        assert!(elapsed < Duration::from_millis(200), "disk startup took {elapsed:?}");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn subscribe_recv_and_run_deliver_summary_then_removal() {
        let (hub, writer) = Hub::new(SummaryIndex::new());
        let task = tokio::spawn(writer.run());
        let subscription = hub.subscribe(&Sub::new("live", "list")).unwrap();
        hub.submit(summary("live-chat", 1)).unwrap();
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Summary(event) => assert_eq!(event.summary.chat_id, "live-chat"),
            other => panic!("expected summary, got {other:?}"),
        }
        hub.remove("local", "live-chat").unwrap();
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Gone { chat_id, .. } => assert_eq!(chat_id, "live-chat"),
            other => panic!("expected removal, got {other:?}"),
        }
        hub.close();
        task.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn replay_does_not_replace_newer_live_item_for_same_chat() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("same", 1)).unwrap();
        let subscription = hub.subscribe(&Sub::new("resume", "list").from_cursor(0)).unwrap();
        writer.apply(summary("same", 2)).unwrap();
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Summary(event) => assert_eq!(event.seq, 1),
            other => panic!("expected replayed summary, got {other:?}"),
        }
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Summary(event) => assert_eq!(event.seq, 2),
            other => panic!("expected newer summary, got {other:?}"),
        }
        subscription.receiver.reposition(2);
        let state = subscription.receiver.subscriber.state.lock().unwrap();
        assert!(!state.ended);
        assert_eq!(state.cursor, 2);
    }

    #[test]
    fn cursor_ahead_of_index_gets_a_fresh_current_window() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("current", 1)).unwrap();
        let subscription =
            hub.subscribe(&Sub::new("ahead", "list").from_cursor(Cursor(10))).unwrap();
        let window: Window<Summary> = subscription.window.decode_json().unwrap();
        assert_eq!(window.cursor, 1);
        assert!(!subscription.receiver.subscriber.state.lock().unwrap().ended);
    }

    #[test]
    fn dropping_a_list_receiver_unregisters_the_subscriber() {
        let (hub, _) = Hub::new(SummaryIndex::new());
        let subscription = hub.subscribe(&Sub::new("drop", "list")).unwrap();
        assert_eq!(hub.subscriber_count(), 1);
        drop(subscription);
        assert_eq!(hub.subscriber_count(), 0);
    }

    #[test]
    fn submit_coalesces_latest_summary_per_chat_without_an_item_cap() {
        let (hub, _writer) = Hub::new(SummaryIndex::new());
        for at in 0..11_000 {
            hub.submit(summary("same", at)).unwrap();
        }
        let batch = hub.updates.take_batch();
        assert_eq!(batch.len(), 1);
        match &batch[0].1 {
            PendingUpdate::Summary { summary, .. } => assert_eq!(summary.last_activity, 10_999),
            PendingUpdate::Gone { .. } => panic!("summary slot was replaced by a removal"),
            PendingUpdate::Origin { .. } | PendingUpdate::Takeover { .. } => {
                panic!("origin update occupied summary slot")
            }
        }
    }

    #[test]
    fn removal_publishes_a_gone_change_and_removes_the_row() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("gone", 1)).unwrap();
        assert!(writer.remove("local", "gone").unwrap());
        assert!(hub.snapshot().get("gone").is_none());
        assert!(!writer.remove("local", "gone").unwrap());
    }

    #[test]
    fn source_ownership_refuses_cross_source_updates_until_takeover() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        let mut row = summary("remote", 1);
        row.origin = "peer".into();
        writer.apply_from(Source::Mirror, row.clone()).unwrap();
        assert!(matches!(
            writer.apply_from(Source::V1, row.clone()),
            Err(HubError::SourceRefused { .. })
        ));
        writer.takeover("peer", Source::V1).unwrap();
        writer.apply_from(Source::V1, row).unwrap();
        assert!(hub.snapshot().get_row(&RowKey::new("peer", "remote")).is_some());
        assert!(refused_source_submits() > 0);
    }

    #[test]
    fn remote_close_emits_summary_but_is_absent_from_index_and_replay() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("index.log");
        let log = IndexLog::open(&path).unwrap();
        let (hub, mut writer) = Hub::with_log(SummaryIndex::new(), Some(log));
        let mut row = summary("remote", 1);
        row.origin = "peer".into();
        writer.apply_from(Source::V1, row).unwrap();
        let mut closed = summary("remote", 2);
        closed.origin = "peer".into();
        closed.state = "closed".into();
        let event = writer.apply_from(Source::V1, closed).unwrap();
        assert_eq!(event.summary.state, "closed");
        assert!(hub.snapshot().get_row(&RowKey::new("peer", "remote")).is_none());
        let restored = replay_log(&path, SummaryIndex::new()).unwrap();
        assert!(restored.get_row(&RowKey::new("peer", "remote")).is_none());
    }

    #[test]
    fn origin_state_is_one_record_and_removed_origin_hides_rows() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        assert!(writer.origin("peer", OriginState::Down, 10).unwrap());
        assert!(!writer.origin("peer", OriginState::Down, 10).unwrap());
        assert!(writer.origin("peer", OriginState::Stale, 20).unwrap());
        let mut row = summary("remote", 1);
        row.origin = "peer".into();
        writer.apply_from(Source::V1, row).unwrap();
        writer.origin("peer", OriginState::Removed, 30).unwrap();
        assert!(hub.snapshot().iter().next().is_none());
        let window: Window<Summary> =
            hub.list_window(&Sub::new("origin", "list")).unwrap().decode_json().unwrap();
        assert!(window.rows.is_empty());
        assert_eq!(window.origins.len(), 1);
        assert_eq!(window.origins[0].state, OriginState::Removed);
    }
}
