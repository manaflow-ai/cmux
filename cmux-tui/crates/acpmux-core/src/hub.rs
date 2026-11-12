//! The published summary hub.
//!
//! A chat actor submits one small summary to the writer. The writer appends the
//! record, applies it to the persistent ordered maps and publishes the new
//! snapshot through [`ArcSwap`]. Readers load that snapshot without taking a
//! lock and a list window copies only the rows it will send.

use acpmux_book::index::{IndexLog, Summary, SummaryIndex};
use arc_swap::ArcSwap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, mpsc};

use crate::wire::{Frame, FrameError, FrameKind, Sub};

/// The default list window and the hard row count ceiling for one window.
pub const DEFAULT_WINDOW_ROWS: usize = 100;
pub const MAX_WINDOW_ROWS: usize = 400;
const EVENT_CAPACITY: usize = 1024;

/// A summary change in index sequence order. The summary is shared with the
/// published snapshot, so sending it to subscribers is O(1) in chat count.
#[derive(Clone, Debug)]
pub struct SummaryEvent {
    pub seq: u64,
    pub summary: Arc<Summary>,
}

/// The first list frame. It is intentionally a window, never a whole-list
/// response; callers page as the viewport approaches an edge.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub cursor: u64,
    pub rows: Vec<Summary>,
    pub has_before: bool,
    pub has_after: bool,
}

/// A bounded list delta. A later wire lane can add counts without changing the
/// subscription or frame shape.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase", tag = "op")]
pub enum Delta {
    Summary { seq: u64, summary: Summary },
    Gone { seq: u64, chat_id: String },
}

/// The published index and its one-writer input queue.
pub struct Hub {
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: mpsc::Sender<Summary>,
    events: broadcast::Sender<SummaryEvent>,
}

/// Explicit name for the published summary hub used by later actors.
pub type SummaryHub = Hub;

/// The sole owner that mutates the index. It can be driven by a tokio task via
/// [`HubWriter::run`], or synchronously in deterministic unit tests with
/// [`HubWriter::apply`].
pub struct HubWriter {
    published: Arc<ArcSwap<SummaryIndex>>,
    updates: mpsc::Receiver<Summary>,
    events: broadcast::Sender<SummaryEvent>,
    log: Option<IndexLog>,
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
}

impl Hub {
    /// Creates a hub and its one writer. No task is spawned implicitly, so the
    /// caller controls the runtime and shutdown boundary.
    pub fn new(index: SummaryIndex) -> (Self, HubWriter) {
        Self::with_log(index, None)
    }

    pub fn with_log(index: SummaryIndex, log: Option<IndexLog>) -> (Self, HubWriter) {
        let published = Arc::new(ArcSwap::from_pointee(index));
        let (updates, receiver) = mpsc::channel(EVENT_CAPACITY);
        let (events, _) = broadcast::channel(EVENT_CAPACITY);
        let hub = Self { published: published.clone(), updates, events: events.clone() };
        let writer = HubWriter { published, updates: receiver, events, log };
        (hub, writer)
    }

    /// A non-blocking enqueue: actor work never waits on list size. The
    /// bounded queue is the writer's backpressure boundary.
    pub fn submit(&self, summary: Summary) -> Result<(), HubError> {
        self.updates.try_send(summary).map_err(|_| HubError::WriterGone)
    }

    pub fn snapshot(&self) -> Arc<SummaryIndex> {
        self.published.load_full()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SummaryEvent> {
        self.events.subscribe()
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
        // A cursor resumes deltas; it does not turn the first window into a
        // history replay. The window remains a bounded viewport from the
        // current published snapshot. The later list actor uses the cursor to
        // select its delta stream.
        let start = 0;
        let rows = index.page(start, requested);
        let has_before = start > 0;
        let has_after = start.saturating_add(rows.len()) < index.len();
        // The cursor is the index sequence, not a row id. The current snapshot
        // is exact at `index.seq()` even when the window is short.
        let cursor = index.seq();
        let window = Window {
            cursor,
            rows: rows.into_iter().map(|summary| summary.as_ref().clone()).collect(),
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
                acpmux_book::index::IndexRecord { seq, chat_id: summary.chat_id.clone(), summary }
            }
        };
        if let Some(log) = self.log.as_mut() {
            log.flush()?;
        }
        let next = self.published.load_full().apply(record.seq, record.summary);
        let event = SummaryEvent {
            seq: record.seq,
            summary: next.get(&record.chat_id).expect("the applied summary is indexed"),
        };
        self.published.store(Arc::new(next));
        let _ = self.events.send(event.clone());
        Ok(event)
    }

    /// Runs the single writer until all senders are dropped.
    pub async fn run(mut self) -> Result<(), HubError> {
        while let Some(summary) = self.updates.recv().await {
            self.apply(summary)?;
        }
        Ok(())
    }
}

/// A wire delta frame helper shared by the list and chat lanes.
pub fn delta_frame(delta: &Delta) -> Result<Frame, FrameError> {
    Frame::json(FrameKind::Delta, delta)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Stream;

    fn summary(id: &str, at: u64) -> Summary {
        let mut summary = Summary::new(id);
        summary.last_activity = at;
        summary
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
        let window: Window = frame.decode_json().unwrap();
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
}
