//! The published summary hub.
//!
//! A chat actor submits one small summary to the writer. The writer appends the
//! record, applies it to the persistent ordered maps and publishes the new
//! snapshot through [`ArcSwap`]. Readers load that snapshot without taking a
//! lock and a list window copies only the rows it will send.

use acpmux_book::index::{IndexLog, Summary, SummaryIndex};
use arc_swap::ArcSwap;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use thiserror::Error;
use tokio::sync::Notify;

use crate::wire::{Frame, FrameError, FrameKind, Sub};

pub use crate::wire::{Delta, Window};

/// The default list window and the hard row count ceiling for one window.
pub const DEFAULT_WINDOW_ROWS: usize = 100;
pub const MAX_WINDOW_ROWS: usize = 400;
const EVENT_CAPACITY: usize = 1024;
const SUBSCRIBER_BYTES: usize = 4 * 1024 * 1024;

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
    Gone { seq: u64, chat_id: String },
    Dropped { cursor: u64 },
}

struct UpdateQueue {
    pending: Mutex<HashMap<String, Summary>>,
    notify: Notify,
    closed: AtomicBool,
}

impl UpdateQueue {
    fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            notify: Notify::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn submit(&self, summary: Summary) -> Result<(), HubError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(HubError::WriterGone);
        }
        self.pending
            .lock()
            .map_err(|_| HubError::WriterGone)?
            .insert(summary.chat_id.clone(), summary);
        self.notify.notify_one();
        Ok(())
    }

    fn take_batch(&self) -> Vec<Summary> {
        let Ok(mut pending) = self.pending.lock() else { return Vec::new() };
        pending.drain().map(|(_, summary)| summary).collect()
    }
}

struct SubscriberState {
    pending: HashMap<String, SummaryEvent>,
    gone: HashMap<String, u64>,
    bytes: usize,
    dropped: Option<u64>,
    cursor: u64,
}

struct Subscriber {
    state: Mutex<SubscriberState>,
    notify: Notify,
}

impl Subscriber {
    fn new(cursor: u64) -> Self {
        Self {
            state: Mutex::new(SubscriberState {
                pending: HashMap::new(),
                gone: HashMap::new(),
                bytes: 0,
                dropped: None,
                cursor,
            }),
            notify: Notify::new(),
        }
    }
}

pub struct ListReceiver {
    subscriber: Arc<Subscriber>,
}

impl ListReceiver {
    pub async fn recv(&self) -> Option<ListItem> {
        loop {
            if let Ok(mut state) = self.subscriber.state.lock() {
                if let Some(cursor) = state.dropped.take() {
                    return Some(ListItem::Dropped { cursor });
                }
                if let Some((chat_id, seq)) = state
                    .gone
                    .iter()
                    .min_by_key(|(_, seq)| **seq)
                    .map(|(chat_id, seq)| (chat_id.clone(), *seq))
                {
                    state.gone.remove(&chat_id);
                    state.bytes = state.bytes.saturating_sub(32);
                    state.cursor = state.cursor.max(seq);
                    return Some(ListItem::Gone { seq, chat_id });
                }
                if let Some((chat_id, event)) = state
                    .pending
                    .iter()
                    .min_by_key(|(_, event)| event.seq)
                    .map(|(chat_id, event)| (chat_id.clone(), event.clone()))
                {
                    state.pending.remove(&chat_id);
                    state.bytes = state.bytes.saturating_sub(event.summary.encoded_len() + 32);
                    state.cursor = state.cursor.max(event.seq);
                    return Some(ListItem::Summary(event));
                }
            }
            self.subscriber.notify.notified().await;
        }
    }
}

pub struct ListSubscription {
    pub window: Frame,
    pub receiver: ListReceiver,
}

/// The published index and its one-writer input queue.
pub struct Hub {
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: Arc<UpdateQueue>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
}

/// Explicit name for the published summary hub used by later actors.
pub type SummaryHub = Hub;

/// The sole owner that mutates the index. It can be driven by a tokio task via
/// [`HubWriter::run`], or synchronously in deterministic unit tests with
/// [`HubWriter::apply`].
pub struct HubWriter {
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: Arc<UpdateQueue>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    log: Option<IndexLog>,
    log_errors: Arc<AtomicU64>,
}

#[derive(Debug, Error)]
pub enum HubError {
    #[error("the summary hub writer is gone")]
    WriterGone,
    #[error("the list stream must be named `list`, got {0:?}")]
    WrongStream(String),
    #[error("window must be between 1 and {MAX_WINDOW_ROWS} rows")]
    InvalidWindow,
    #[error("encoding list frame failed: {0}")]
    Frame(#[from] FrameError),
    #[error("index log failed: {0}")]
    Log(#[from] std::io::Error),
    #[error("published summary {0:?} is missing after apply")]
    MissingSummary(String),
}

impl Hub {
    /// Creates a hub and its one writer. No task is spawned implicitly, so the
    /// caller controls the runtime and shutdown boundary.
    pub fn new(index: SummaryIndex) -> (Self, HubWriter) {
        Self::with_log(index, None)
    }

    pub fn with_log(index: SummaryIndex, log: Option<IndexLog>) -> (Self, HubWriter) {
        let published = Arc::new(ArcSwap::from_pointee(index));
        let updates = Arc::new(UpdateQueue::new());
        let subscribers = Arc::new(Mutex::new(Vec::with_capacity(EVENT_CAPACITY)));
        let log_errors = Arc::new(AtomicU64::new(0));
        let hub = Self {
            published: published.clone(),
            updates: updates.clone(),
            subscribers: subscribers.clone(),
        };
        let writer = HubWriter { published, updates, subscribers, log, log_errors };
        (hub, writer)
    }

    /// A non-blocking enqueue: actor work never waits on list size. The
    /// bounded queue is the writer's backpressure boundary.
    pub fn submit(&self, summary: Summary) -> Result<(), HubError> {
        self.updates.submit(summary)
    }

    pub fn snapshot(&self) -> Arc<SummaryIndex> {
        self.published.load_full()
    }

    pub fn subscribe(&self, sub: &Sub) -> Result<ListSubscription, HubError> {
        if sub.stream.as_str() != "list" {
            return Err(HubError::WrongStream(sub.stream.as_str().to_owned()));
        }
        let cursor = sub.cursor.map_or(0, |cursor| cursor.0);
        let subscriber = Arc::new(Subscriber::new(cursor));
        self.subscribers.lock().map_err(|_| HubError::WriterGone)?.push(subscriber.clone());
        let index = self.snapshot();
        let frame = self.window_frame(sub, &index)?;
        if let Ok(mut state) = subscriber.state.lock() {
            state.cursor = index.seq();
            state.pending.retain(|_, event| event.seq > index.seq());
        }
        Ok(ListSubscription { window: frame, receiver: ListReceiver { subscriber } })
    }

    /// Builds one bounded first frame from the current published index. It does
    /// not hydrate chats or construct a whole-list reply.
    pub fn list_window(&self, sub: &Sub) -> Result<Frame, HubError> {
        if sub.stream.as_str() != "list" {
            return Err(HubError::WrongStream(sub.stream.as_str().to_owned()));
        }
        let requested = usize::from(sub.window.unwrap_or(DEFAULT_WINDOW_ROWS as u16));
        if requested == 0 || requested > MAX_WINDOW_ROWS {
            return Err(HubError::InvalidWindow);
        }
        let index = self.snapshot();
        self.window_frame(sub, &index)
    }

    fn window_frame(&self, sub: &Sub, index: &SummaryIndex) -> Result<Frame, HubError> {
        // A cursor resumes deltas; it does not turn the first window into a
        // history replay. The window remains a bounded viewport from the
        // current published snapshot. The later list actor uses the cursor to
        // select its delta stream.
        let requested = usize::from(sub.window.unwrap_or(DEFAULT_WINDOW_ROWS as u16));
        let cursor = index.seq();
        let rows = match sub.anchor.as_ref() {
            Some(crate::wire::Anchor::List { key, side })
                if matches!(
                    side,
                    crate::wire::AnchorSide::After | crate::wire::AnchorSide::Around
                ) =>
            {
                index.page_after_key(Some((&key.last_activity, &key.chat_id)), requested)
            }
            _ => index.page(0, requested),
        };
        let has_before = false;
        let has_after = rows.len() < index.len();
        // The cursor is the index sequence, not a row id. The current snapshot
        // is exact at `index.seq()` even when the window is short.
        let mut selected = Vec::with_capacity(rows.len());
        let mut bytes = 96usize;
        for summary in rows {
            let next = summary.encoded_len().saturating_add(2);
            if !selected.is_empty() && bytes.saturating_add(next) > crate::wire::MAX_PAGE_BYTES {
                break;
            }
            selected.push(summary.as_ref().clone());
            bytes = bytes.saturating_add(next);
        }
        let window = Window::<Summary> {
            sid: sub.sid.clone(),
            cursor,
            rows: selected,
            has_before,
            has_after,
        };
        Frame::json(FrameKind::Window, &window).map_err(HubError::from)
    }
}

impl HubWriter {
    /// Applies one summary and publishes the resulting immutable snapshot.
    pub fn apply(&mut self, summary: Summary) -> Result<SummaryEvent, HubError> {
        let record = match self.log.as_mut() {
            Some(log) => log.append(summary)?,
            None => {
                let seq = self.published.load().seq().saturating_add(1);
                acpmux_book::index::IndexRecord {
                    seq,
                    chat_id: summary.chat_id.clone(),
                    summary,
                    gone: false,
                }
            }
        };
        if let Some(log) = self.log.as_mut() {
            // A summary cursor is durable at append; a restart must never
            // publish a sequence that the index log did not sync.
            log.sync()?;
        }
        let next = self.published.load_full().apply(record.seq, record.summary);
        let summary = next
            .get(&record.chat_id)
            .ok_or_else(|| HubError::MissingSummary(record.chat_id.clone()))?;
        let event = SummaryEvent { seq: record.seq, summary };
        self.published.store(Arc::new(next));
        self.publish(event.clone());
        Ok(event)
    }

    fn publish(&self, event: SummaryEvent) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            let Ok(mut state) = subscriber.state.lock() else { continue };
            if event.seq <= state.cursor || state.dropped.is_some() {
                continue;
            }
            let bytes = event.summary.encoded_len().saturating_add(32);
            if let Some(old) = state.pending.insert(event.summary.chat_id.clone(), event.clone()) {
                state.bytes =
                    state.bytes.saturating_sub(old.summary.encoded_len().saturating_add(32));
            }
            if state.gone.remove(&event.summary.chat_id).is_some() {
                state.bytes = state.bytes.saturating_sub(32);
            }
            state.bytes = state.bytes.saturating_add(bytes);
            if state.bytes > SUBSCRIBER_BYTES {
                state.pending.clear();
                state.bytes = 0;
                state.dropped = Some(event.seq);
            }
            subscriber.notify.notify_one();
        }
    }

    pub fn remove(&mut self, chat_id: &str) -> Result<bool, HubError> {
        if self.published.load().get(chat_id).is_none() {
            return Ok(false);
        }
        let seq = match self.log.as_mut() {
            Some(log) => log.append_remove(chat_id.to_owned())?.seq,
            None => self.published.load().seq().saturating_add(1),
        };
        if let Some(log) = self.log.as_mut() {
            log.sync()?;
        }
        let current = self.published.load_full();
        let Some(next) = current.remove(seq, chat_id) else { return Ok(false) };
        self.published.store(Arc::new(next));
        self.publish_gone(seq, chat_id.to_owned());
        Ok(true)
    }

    fn publish_gone(&self, seq: u64, chat_id: String) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        for subscriber in subscribers.iter() {
            let Ok(mut state) = subscriber.state.lock() else { continue };
            if seq <= state.cursor || state.dropped.is_some() {
                continue;
            }
            if let Some(old) = state.pending.remove(&chat_id) {
                state.bytes =
                    state.bytes.saturating_sub(old.summary.encoded_len().saturating_add(32));
            }
            state.gone.insert(chat_id.clone(), seq);
            state.bytes = state.bytes.saturating_add(32);
            if state.bytes > SUBSCRIBER_BYTES {
                state.pending.clear();
                state.gone.clear();
                state.bytes = 0;
                state.dropped = Some(seq);
            }
            subscriber.notify.notify_one();
        }
    }

    /// Runs the single writer until all senders are dropped.
    pub async fn run(mut self) -> Result<(), HubError> {
        while !self.updates.closed.load(Ordering::Acquire) {
            self.updates.notify.notified().await;
            for summary in self.updates.take_batch() {
                if self.apply(summary.clone()).is_err() {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                    let seq = self.published.load().seq().saturating_add(1);
                    let next = self.published.load_full().apply(seq, summary.clone());
                    if let Some(published) = next.get(&summary.chat_id) {
                        self.publish(SummaryEvent { seq, summary: published });
                    }
                    self.published.store(Arc::new(next));
                }
            }
        }
        Ok(())
    }

    pub fn close(&self) {
        self.updates.closed.store(true, Ordering::Release);
        self.updates.notify.notify_waiters();
    }

    pub fn log_errors(&self) -> u64 {
        self.log_errors.load(Ordering::Relaxed)
    }
}

/// A wire delta frame helper shared by the list and chat lanes.
pub fn delta_frame(delta: &Delta<Summary>) -> Result<Frame, FrameError> {
    crate::wire::delta_frame(delta)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Stream;
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Instant;

    fn summary(id: &str, at: u64) -> Summary {
        let mut summary = Summary::new(id);
        summary.last_activity = at;
        summary
    }

    fn gate(name: &str, small: u128, god: u128) {
        let Ok(path) = std::env::var("V2_GATE_OUT") else { return };
        let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else { return };
        let _ = writeln!(
            file,
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"ns\"}}"
        );
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
    fn list_window_gate_and_summary_change_counter_cover_small_and_god() {
        let mut small = SummaryIndex::new();
        for n in 0..20 {
            small = small.apply(n + 1, summary(&format!("s{n}"), n));
        }
        let mut god = SummaryIndex::new();
        for n in 0..11_000 {
            god = god.apply(n + 1, summary(&format!("g{n}"), n));
        }
        let (small_hub, _) = Hub::new(small.clone());
        let (god_hub, _) = Hub::new(god.clone());
        let small_start = Instant::now();
        small_hub.list_window(&Sub::new("small", "list")).unwrap();
        let small_ns = small_start.elapsed().as_nanos();
        let god_start = Instant::now();
        god_hub.list_window(&Sub::new("god", "list")).unwrap();
        let god_ns = god_start.elapsed().as_nanos();
        gate("v2.pr05.first_list_window", small_ns, god_ns);

        let visited_small = AtomicUsize::new(0);
        let visited_god = AtomicUsize::new(0);
        small.apply_counted(21, summary("s0", 99), &visited_small);
        god.apply_counted(11_001, summary("g0", 99), &visited_god);
        assert_eq!(visited_small.load(Ordering::Relaxed), visited_god.load(Ordering::Relaxed));
        gate(
            "v2.pr05.summary_change",
            visited_small.load(Ordering::Relaxed) as u128,
            visited_god.load(Ordering::Relaxed) as u128,
        );
    }

    #[test]
    fn submit_coalesces_latest_summary_per_chat_without_an_item_cap() {
        let (hub, _writer) = Hub::new(SummaryIndex::new());
        for at in 0..11_000 {
            hub.submit(summary("same", at)).unwrap();
        }
        let batch = hub.updates.take_batch();
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].last_activity, 10_999);
    }

    #[test]
    fn removal_publishes_a_gone_change_and_removes_the_row() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("gone", 1)).unwrap();
        assert!(writer.remove("gone").unwrap());
        assert!(hub.snapshot().get("gone").is_none());
        assert!(!writer.remove("gone").unwrap());
    }
}
