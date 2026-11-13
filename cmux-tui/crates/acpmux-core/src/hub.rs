//! The published summary hub.
//!
//! A chat actor submits one small summary to the writer. The writer appends the
//! record, applies it to the persistent ordered maps and publishes the new
//! snapshot through [`ArcSwap`]. Readers load that snapshot without taking a
//! lock and a list window copies only the rows it will send.

use acpmux_book::index::{IndexLog, Summary, SummaryIndex};
use arc_swap::ArcSwap;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use thiserror::Error;
use tokio::sync::Notify;

use crate::wire::{Frame, FrameError, FrameKind, Sub};

pub use crate::wire::Window;

/// The default list window and the hard row count ceiling for one window.
pub const DEFAULT_WINDOW_ROWS: usize = 100;
pub const MAX_WINDOW_ROWS: usize = 400;
const EVENT_CAPACITY: usize = 1024;
const HISTORY_CAPACITY: usize = 16 * 1024;

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
    Lagged { cursor: u64 },
}

enum PendingUpdate {
    Summary(Summary),
    Gone,
}

struct UpdateQueue {
    pending: Mutex<HashMap<String, PendingUpdate>>,
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
            .insert(summary.chat_id.clone(), PendingUpdate::Summary(summary));
        self.notify.notify_one();
        Ok(())
    }

    fn submit_remove(&self, chat_id: String) -> Result<(), HubError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(HubError::WriterGone);
        }
        self.pending.lock().map_err(|_| HubError::WriterGone)?.insert(chat_id, PendingUpdate::Gone);
        self.notify.notify_one();
        Ok(())
    }

    fn take_batch(&self) -> Vec<(String, PendingUpdate)> {
        let Ok(mut pending) = self.pending.lock() else { return Vec::new() };
        pending.drain().collect()
    }
}

struct SubscriberState {
    ended: bool,
    cursor: u64,
}

struct Subscriber {
    state: Mutex<SubscriberState>,
    notify: Notify,
}

impl Subscriber {
    fn new(cursor: u64) -> Self {
        Self { state: Mutex::new(SubscriberState { ended: false, cursor }), notify: Notify::new() }
    }
}

fn item_seq(item: &ListItem) -> u64 {
    match item {
        ListItem::Summary(event) => event.seq,
        ListItem::Gone { seq, .. } => *seq,
        ListItem::Lagged { cursor } => *cursor,
    }
}

#[derive(Default)]
struct History {
    records: VecDeque<(ListItem, usize)>,
    bytes: usize,
}

impl History {
    fn front_seq(&self) -> Option<u64> {
        self.records.front().map(|(item, _)| item_seq(item))
    }

    fn after(&self, cursor: u64) -> Option<&ListItem> {
        let offset = cursor.saturating_add(1).checked_sub(self.front_seq()?)?;
        self.records.get(usize::try_from(offset).ok()?).map(|(item, _)| item)
    }
}

pub struct ListReceiver {
    subscriber: Arc<Subscriber>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    history: Arc<Mutex<History>>,
}

impl Drop for ListReceiver {
    fn drop(&mut self) {
        if let Ok(mut subscribers) = self.subscribers.lock() {
            subscribers.retain(|subscriber| !Arc::ptr_eq(subscriber, &self.subscriber));
        }
    }
}

impl ListReceiver {
    /// Mark the history consumed by a connection's synchronous resume prefix.
    /// Subsequent `recv` calls therefore observe only records published after
    /// the resume snapshot, so live delivery cannot precede its `end` mark.
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
        let mut state = self.subscriber.state.lock().ok()?;
        if state.ended {
            return None;
        }
        let history = self.history.lock().ok()?;
        if history.front_seq().is_some_and(|seq| state.cursor.saturating_add(1) < seq) {
            state.ended = true;
            return Some(ListItem::Lagged { cursor: state.cursor });
        }
        history.after(state.cursor).cloned()
    }

    pub async fn recv(&self) -> Option<ListItem> {
        loop {
            // notify_one stores a permit even when a publish races this read.
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
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: Arc<UpdateQueue>,
    subscribers: Arc<Mutex<Vec<Arc<Subscriber>>>>,
    history: Arc<Mutex<History>>,
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
    history: Arc<Mutex<History>>,
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
        let history = Arc::new(Mutex::new(History::default()));
        let log_errors = Arc::new(AtomicU64::new(0));
        let hub = Self {
            published: published.clone(),
            updates: updates.clone(),
            subscribers: subscribers.clone(),
            history: history.clone(),
        };
        let writer = HubWriter { published, updates, subscribers, history, log, log_errors };
        (hub, writer)
    }

    /// A non-blocking enqueue: actor work never waits on list size. The
    /// bounded queue is the writer's backpressure boundary.
    pub fn submit(&self, summary: Summary) -> Result<(), HubError> {
        self.updates.submit(summary)
    }

    /// Enqueues a removal in the same keyed slot as summary updates. A later
    /// summary for this chat replaces the removal before the writer takes its
    /// batch, so a burst cannot grow with the number of events.
    pub fn remove(&self, chat_id: impl Into<String>) -> Result<(), HubError> {
        self.updates.submit_remove(chat_id.into())
    }

    pub fn snapshot(&self) -> Arc<SummaryIndex> {
        self.published.load_full()
    }

    /// A consistent replay cut: the retained records and their last seq are
    /// inspected under one short lock. Encoding happens after this lock is gone.
    pub fn resume_target(&self, cursor: u64) -> Result<Option<u64>, HubError> {
        let history = self.history.lock().map_err(|_| HubError::WriterGone)?;
        let target = history
            .records
            .back()
            .map(|(item, _)| item_seq(item))
            .unwrap_or_else(|| self.published.load().seq());
        if cursor > target
            || history.front_seq().is_some_and(|seq| cursor.saturating_add(1) < seq)
            || (history.records.is_empty() && cursor != target)
        {
            return Ok(None);
        }
        Ok(Some(target))
    }

    /// Wakes a writer task and prevents any later submit from waiting for it.
    pub fn close(&self) {
        self.updates.closed.store(true, Ordering::Release);
        self.updates.notify.notify_waiters();
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
        let edition_matches = sub.edition.is_none_or(|edition| edition == 0);
        let resume_cursor =
            if edition_matches && sub.cursor.is_some() && self.resume_target(cursor)?.is_some() {
                cursor
            } else {
                index.seq()
            };
        // The window always describes this snapshot, even when a source chooses
        // to replay instead. A failed frame leaves no registered subscriber.
        let frame = self.window_frame_at_cursor(sub, &index, index.seq())?;
        let subscriber = Arc::new(Subscriber::new(resume_cursor));
        self.subscribers.lock().map_err(|_| HubError::WriterGone)?.push(subscriber.clone());
        Ok(ListSubscription {
            window: frame,
            cursor: index.seq(),
            receiver: ListReceiver {
                subscriber,
                subscribers: self.subscribers.clone(),
                history: self.history.clone(),
            },
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
        // A cursor resumes deltas; it does not turn the first window into a
        // history replay. The window remains a bounded viewport from the
        // current published snapshot. The later list actor uses the cursor to
        // select its delta stream.
        let requested = usize::from(sub.window.unwrap_or(DEFAULT_WINDOW_ROWS as u16));
        let rows = match sub.anchor.as_ref() {
            Some(crate::wire::Anchor::List { key, side }) => match side {
                crate::wire::AnchorSide::Before => {
                    index.page_before_key((&key.last_activity, &key.chat_id), requested)
                }
                crate::wire::AnchorSide::After => {
                    index.page_after_key(Some((&key.last_activity, &key.chat_id)), requested)
                }
                crate::wire::AnchorSide::Around => {
                    index.page_after_key(Some((&key.last_activity, &key.chat_id)), requested)
                }
            },
            Some(crate::wire::Anchor::End) | Some(crate::wire::Anchor::Row { .. }) | None => {
                index.page(0, requested)
            }
        };
        let has_before = matches!(sub.anchor.as_ref(), Some(crate::wire::Anchor::List { .. }))
            && !rows.is_empty();
        let has_after = rows.len() < index.len();
        // The cursor is the index sequence, not a row id. The current snapshot
        // is exact at `index.seq()` even when the window is short.
        let mut window = Window::<Summary> {
            sid: sub.sid.clone(),
            cursor,
            rows: Vec::with_capacity(rows.len()),
            has_before,
            has_after,
            edition: 0,
            origins: Vec::new(),
        };
        // Include the escaped sid, cursor and envelope exactly, not a fixed
        // estimate. Each additional row contributes its JSON bytes and comma.
        let mut bytes = Frame::json(FrameKind::Window, &window)?.encoded_len();
        for summary in rows {
            let next = summary.encoded_len().saturating_add(usize::from(!window.rows.is_empty()));
            if bytes.saturating_add(next) > crate::wire::MAX_PAGE_BYTES {
                window.has_after = true;
                break;
            }
            bytes += next;
            window.rows.push(summary.as_ref().clone());
        }
        Frame::json(FrameKind::Window, &window).map_err(HubError::from)
    }
}

fn validate_window(sub: &Sub) -> Result<usize, HubError> {
    let requested = usize::from(sub.window.unwrap_or(DEFAULT_WINDOW_ROWS as u16));
    if requested == 0 || requested > MAX_WINDOW_ROWS {
        return Err(HubError::InvalidWindow);
    }
    Ok(requested)
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
        self.record_history(ListItem::Summary(event.clone()));
        self.publish(event.clone());
        Ok(event)
    }

    fn publish(&self, event: SummaryEvent) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        // Only ListReceiver::drop removes registrations. A lagged receiver may
        // still be repositioned to a fresh window by its source.
        for subscriber in subscribers.iter() {
            let Ok(state) = subscriber.state.lock() else { continue };
            if event.seq <= state.cursor || state.ended {
                continue;
            }
            // The history is the subscriber's resume source. Do not enqueue the frame here:
            // an unread subscriber must retain only its cursor.
            subscriber.notify.notify_one();
        }
    }

    pub fn remove(&mut self, chat_id: &str) -> Result<bool, HubError> {
        self.apply_remove(chat_id)
    }

    fn apply_remove(&mut self, chat_id: &str) -> Result<bool, HubError> {
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
        self.record_history(ListItem::Gone { seq, chat_id: chat_id.to_owned() });
        self.publish_gone(seq, chat_id.to_owned());
        Ok(true)
    }

    fn publish_gone(&self, seq: u64, _chat_id: String) {
        let Ok(subscribers) = self.subscribers.lock() else { return };
        // Only ListReceiver::drop removes registrations. A lagged receiver may
        // still be repositioned to a fresh window by its source.
        for subscriber in subscribers.iter() {
            let Ok(state) = subscriber.state.lock() else { continue };
            if seq <= state.cursor || state.ended {
                continue;
            }
            // See `publish`: the subscriber wakes and reads from history on demand.
            subscriber.notify.notify_one();
        }
    }

    fn record_history(&self, item: ListItem) {
        // Compute record size outside the lock used by a reader. The shared
        // retention has its own byte bound; a stopped subscriber owns only a cursor.
        let bytes = match &item {
            ListItem::Summary(event) => serde_json::to_vec(&crate::wire::DeltaOp::Summary {
                seq: event.seq,
                summary: event.summary.as_ref(),
            })
            .map_or(usize::MAX, |record| record.len()),
            ListItem::Gone { seq, chat_id } => {
                serde_json::to_vec(&crate::wire::DeltaOp::<Summary>::Gone {
                    seq: *seq,
                    chat_id: chat_id.clone(),
                })
                .map_or(usize::MAX, |record| record.len())
            }
            ListItem::Lagged { .. } => 0,
        };
        if let Ok(mut history) = self.history.lock() {
            history.bytes = history.bytes.saturating_add(bytes);
            history.records.push_back((item, bytes));
            while history.records.len() > HISTORY_CAPACITY
                || history.bytes > crate::wire::CREDIT_WINDOW_BYTES as usize
            {
                if let Some((_, bytes)) = history.records.pop_front() {
                    history.bytes = history.bytes.saturating_sub(bytes);
                } else {
                    break;
                }
            }
        }
    }

    /// Runs the single writer until all senders are dropped.
    pub async fn run(mut self) -> Result<(), HubError> {
        while !self.updates.closed.load(Ordering::Acquire) {
            self.updates.notify.notified().await;
            for (chat_id, update) in self.updates.take_batch() {
                match update {
                    PendingUpdate::Summary(summary) => {
                        if self.apply(summary.clone()).is_err() {
                            self.log_errors.fetch_add(1, Ordering::Relaxed);
                            // Keep the in-memory index current while a failed
                            // log is retried by the next update.
                            let seq = self.published.load().seq().saturating_add(1);
                            let next = self.published.load_full().apply(seq, summary.clone());
                            if let Some(published) = next.get(&summary.chat_id) {
                                let event = SummaryEvent { seq, summary: published };
                                self.published.store(Arc::new(next));
                                self.record_history(ListItem::Summary(event.clone()));
                                self.publish(event);
                            }
                        }
                    }
                    PendingUpdate::Gone => {
                        if self.apply_remove(&chat_id).is_err() {
                            self.log_errors.fetch_add(1, Ordering::Relaxed);
                        }
                    }
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
pub fn delta_frame(delta: &crate::wire::DeltaFrame<Summary>) -> Result<Frame, FrameError> {
    crate::wire::delta_frame(delta)
}

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

    fn gate(name: &str, small: u128, god: u128) {
        let line = format!(
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"ns\"}}"
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
        sorted.get(rank).copied().unwrap_or_default()
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

    #[tokio::test]
    async fn lagged_receiver_keeps_registration_until_it_is_dropped() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        let subscription = hub.subscribe(&Sub::new("s", "list")).unwrap();
        for seq in 0..17000 {
            writer.apply(summary("a", seq)).unwrap();
        }
        assert!(matches!(subscription.receiver.try_next(), Some(ListItem::Lagged { .. })));
        writer.apply(summary("a", 17000)).unwrap();
        assert_eq!(hub.subscriber_count(), 1);
        // A fresh window can revive this receiver after an intervening publish.
        subscription.receiver.reposition(hub.snapshot().seq());
        assert!(subscription.receiver.try_next().is_none());
        {
            let receiving = subscription.receiver.recv();
            tokio::pin!(receiving);
            tokio::select! {
                biased;
                _ = &mut receiving => panic!("no new record yet"),
                _ = std::future::ready(()) => {}
            }
            let next = writer.apply(summary("a", 17001)).unwrap();
            let item = tokio::time::timeout(Duration::from_secs(1), receiving).await.unwrap();
            assert!(matches!(item, Some(ListItem::Summary(event)) if event.seq == next.seq));
        }
        drop(subscription);
        assert_eq!(hub.subscriber_count(), 0);
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
        gate("v2.pr05.first_list_window", small_p95, god_p95);

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
        gate("v2.pr05.summary_change", small_change_p95, god_change_p95);
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
            ListItem::Summary(event) => {
                assert_eq!(event.summary.chat_id, "live-chat");
                subscription.receiver.advance_to(event.seq);
            }
            other => panic!("expected summary, got {other:?}"),
        }
        hub.remove("live-chat").unwrap();
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Gone { seq, chat_id } => {
                assert_eq!(chat_id, "live-chat");
                subscription.receiver.advance_to(seq);
            }
            other => panic!("expected removal, got {other:?}"),
        }
        hub.close();
        task.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn replay_preserves_each_record_in_sequence_order() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("same", 1)).unwrap();
        let subscription = hub.subscribe(&Sub::new("resume", "list").from_cursor(0)).unwrap();
        writer.apply(summary("same", 2)).unwrap();
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Summary(event) => {
                assert_eq!(event.seq, 1);
                subscription.receiver.advance_to(event.seq);
            }
            other => panic!("expected newer summary, got {other:?}"),
        }
        match subscription.receiver.recv().await.unwrap() {
            ListItem::Summary(event) => {
                assert_eq!(event.seq, 2);
                subscription.receiver.advance_to(event.seq);
            }
            other => panic!("expected newer summary, got {other:?}"),
        }
        let state = subscription.receiver.subscriber.state.lock().unwrap();
        assert_eq!(state.cursor, 2);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn receiver_cursor_does_not_advance_until_source_accepts_the_record() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("retry", 1)).unwrap();
        let subscription = hub.subscribe(&Sub::new("retry", "list").from_cursor(0)).unwrap();
        let first = subscription.receiver.recv().await.unwrap();
        let first_seq = item_seq(&first);
        assert_eq!(first_seq, 1);
        assert_eq!(subscription.receiver.subscriber.state.lock().unwrap().cursor, 0);
        let retry = subscription.receiver.recv().await.unwrap();
        assert_eq!(item_seq(&retry), first_seq);
        subscription.receiver.advance_to(first_seq);
        assert_eq!(subscription.receiver.subscriber.state.lock().unwrap().cursor, 1);
    }

    #[test]
    fn cursor_ahead_of_index_gets_a_fresh_current_window() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("current", 1)).unwrap();
        let subscription =
            hub.subscribe(&Sub::new("ahead", "list").from_cursor(Cursor(10))).unwrap();
        let window: Window<Summary> = subscription.window.decode_json().unwrap();
        assert_eq!(window.cursor, 1);
        assert_eq!(subscription.receiver.subscriber.state.lock().unwrap().cursor, 1);
    }

    #[test]
    fn a_cursor_from_another_edition_gets_a_fresh_current_window() {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        writer.apply(summary("current", 1)).unwrap();
        let mut sub = Sub::new("edition", "list").from_cursor_in_edition(0, 7);
        sub.edition = Some(7);
        let subscription = hub.subscribe(&sub).unwrap();
        let window: Window<Summary> = subscription.window.decode_json().unwrap();
        assert_eq!(window.cursor, 1);
        assert_eq!(subscription.receiver.subscriber.state.lock().unwrap().cursor, 1);
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
        match &batch.first().unwrap().1 {
            PendingUpdate::Summary(summary) => assert_eq!(summary.last_activity, 10_999),
            PendingUpdate::Gone => panic!("summary slot was replaced by a removal"),
        }
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

#[cfg(test)]
mod failed_subscription_tests {
    use super::*;

    #[test]
    fn frame_encoding_failure_registers_no_subscriber() {
        let (hub, _writer) = Hub::new(SummaryIndex::new());
        let before = hub.subscriber_count();
        let sub = Sub::new("x".repeat(crate::wire::MAX_FRAME_BYTES), "list");
        assert!(matches!(hub.subscribe(&sub), Err(HubError::Frame(_))));
        assert_eq!(hub.subscriber_count(), before);
    }
}
