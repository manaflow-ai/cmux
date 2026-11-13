//! The list source owns delivery and resumes. No replay prefix is retained.
use super::{ConnError, ConnectionMetrics, Offer, OfferSink, Source};
use crate::hub::{Hub, ListItem, ListReceiver};
use crate::wire::{Cursor, DeltaFrame, DeltaOp, Frame, FrameKind, ReplayMark, Sub};
use acpmux_book::index::Summary;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::watch;

#[derive(Default)]
struct Held {
    bytes: AtomicUsize,
    paused: AtomicBool,
}
impl Held {
    fn offer(&self, sink: &dyn OfferSink, sid: &str, frame: Frame, cursor: Cursor) -> Offer {
        self.bytes.store(frame.encoded_len(), Ordering::Release);
        let outcome = sink.offer(sid, frame, cursor);
        self.bytes.store(0, Ordering::Release);
        self.paused.store(matches!(outcome, Offer::NotFed), Ordering::Release);
        outcome
    }
}
struct Task {
    held: Arc<Held>,
    resume: watch::Sender<Cursor>,
    join: tokio::task::JoinHandle<()>,
}
impl Drop for Task {
    fn drop(&mut self) {
        self.join.abort();
    }
}

pub struct HubSource {
    hub: Arc<Hub>,
    scope: cmux_scope::Scope,
    tasks: Mutex<HashMap<String, Task>>,
    metrics: Mutex<Option<Arc<ConnectionMetrics>>>,
}
impl HubSource {
    pub fn new(hub: Arc<Hub>) -> Self {
        Self {
            hub,
            scope: cmux_scope::Scope::new("v2 list connection"),
            tasks: Mutex::new(HashMap::new()),
            metrics: Mutex::new(None),
        }
    }
    pub fn connection_metrics(&self) -> Option<Arc<ConnectionMetrics>> {
        self.metrics.lock().ok()?.clone()
    }
    pub fn not_fed_bytes(&self) -> usize {
        self.tasks.lock().map_or(0, |tasks| {
            tasks
                .values()
                .filter(|task| task.held.paused.load(Ordering::Acquire))
                .map(|task| task.held.bytes.load(Ordering::Acquire))
                .sum()
        })
    }
    pub fn task_count(&self) -> usize {
        self.tasks.lock().map_or(0, |tasks| tasks.len())
    }
}

impl Source for HubSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        let delivery = open(&self.hub, sub)?;
        if let Ok(mut metrics) = self.metrics.lock() {
            *metrics = Some(sink.metrics());
        }
        let (resume, rx) = watch::channel(delivery.cursor);
        // The window (or first replay frame) is queued before a task can offer live data.
        if !matches!(sink.offer(&sub.sid, delivery.first, delivery.cursor), Offer::Taken) {
            return Ok(());
        }
        delivery.receiver.reposition(delivery.cursor.0);
        let mut tasks = self
            .tasks
            .lock()
            .map_err(|_| ConnError::InvalidRequest("list source poisoned".into()))?;
        let held = Arc::new(Held::default());
        let join = self.scope.spawn(pump(
            self.hub.clone(),
            sub.clone(),
            sink,
            delivery.receiver,
            delivery.mode,
            rx,
            held.clone(),
        ));
        tasks.insert(sub.sid.clone(), Task { resume, join, held });
        Ok(())
    }
    fn resume(&self, sid: &str, cursor: Cursor) {
        if let Ok(tasks) = self.tasks.lock()
            && let Some(task) = tasks.get(sid)
        {
            task.resume.send_replace(cursor);
        }
    }
    fn close(&self) -> super::CloseFuture<'_> {
        Box::pin(async {
            if let Ok(mut tasks) = self.tasks.lock() {
                tasks.clear();
            }
            let _report = self.scope.close(std::time::Duration::from_secs(1)).await;
        })
    }
    fn end(&self, sid: &str) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.remove(sid);
        }
    }
}

#[derive(Clone, Copy)]
enum Mode {
    Live,
    Replay(u64),
    Paused,
}
struct Delivery {
    receiver: ListReceiver,
    first: Frame,
    cursor: Cursor,
    mode: Mode,
}

fn open(hub: &Hub, sub: &Sub) -> Result<Delivery, ConnError> {
    let subscription = hub.subscribe(sub)?;
    if sub.edition.is_none_or(|edition| edition == 0)
        && let Some(cursor) = sub.cursor
        && let Some(target) = hub.resume_target(cursor.0)?
    {
        subscription.receiver.reposition(cursor.0);
        if target == cursor.0 {
            return Ok(Delivery {
                receiver: subscription.receiver,
                first: end(&sub.sid)?,
                cursor,
                mode: Mode::Live,
            });
        }
        if let Some(item) = subscription.receiver.try_next()
            && !matches!(item, ListItem::Lagged { .. })
        {
            let (frame, cursor, mode) = event_frame(&sub.sid, item, Mode::Replay(target))?;
            return Ok(Delivery { receiver: subscription.receiver, first: frame, cursor, mode });
        }
    }
    // The frame and cursor come from ONE snapshot. Never substitute a second read.
    subscription.receiver.reposition(subscription.cursor);
    Ok(Delivery {
        receiver: subscription.receiver,
        first: subscription.window,
        cursor: Cursor(subscription.cursor),
        mode: Mode::Live,
    })
}

fn end(sid: &str) -> Result<Frame, ConnError> {
    Ok(Frame::json(
        FrameKind::Delta,
        &DeltaFrame::<Summary> {
            sid: sid.to_owned(),
            replay: Some(ReplayMark::End),
            ops: Vec::new(),
        },
    )?)
}

fn event_frame(sid: &str, item: ListItem, mode: Mode) -> Result<(Frame, Cursor, Mode), ConnError> {
    let (seq, op) = match item {
        ListItem::Summary(event) => {
            (event.seq, DeltaOp::Summary { seq: event.seq, summary: (*event.summary).clone() })
        }
        ListItem::Gone { seq, chat_id } => (seq, DeltaOp::Gone { seq, chat_id }),
        ListItem::Lagged { .. } => {
            return Err(ConnError::InvalidRequest("list cursor expired".into()));
        }
    };
    let (replay, next) = match mode {
        Mode::Replay(target) if seq >= target => (Some(ReplayMark::End), Mode::Live),
        Mode::Replay(_) => (Some(ReplayMark::Replay), mode),
        _ => (None, Mode::Live),
    };
    let frame =
        Frame::json(FrameKind::Delta, &DeltaFrame { sid: sid.to_owned(), replay, ops: vec![op] })?;
    if frame.encoded_len() > crate::wire::MAX_REPLAY_FRAME_BYTES {
        return Err(ConnError::InvalidRequest("list operation exceeds replay bound".into()));
    }
    Ok((frame, Cursor(seq), next))
}

async fn pump(
    hub: Arc<Hub>,
    mut sub: Sub,
    sink: Arc<dyn OfferSink>,
    mut receiver: ListReceiver,
    mut mode: Mode,
    mut resume: watch::Receiver<Cursor>,
    held: Arc<Held>,
) {
    loop {
        if resume.has_changed().unwrap_or(false) {
            held.paused.store(false, Ordering::Release);
            // Keep the original viewport anchor for a fresh window if the
            // cursor has fallen outside retained history. It does not affect replay.
            sub.cursor = Some(*resume.borrow_and_update());
            sub.edition = Some(0);
            let Ok(delivery) = open(&hub, &sub) else {
                sink.fail(&sub.sid);
                return;
            };
            // The frame is moved into offer and released on NotFed BEFORE any await.
            let outcome = held.offer(sink.as_ref(), &sub.sid, delivery.first, delivery.cursor);
            match outcome {
                Offer::Taken => {
                    delivery.receiver.reposition(delivery.cursor.0);
                    receiver = delivery.receiver;
                    mode = delivery.mode;
                }
                Offer::NotFed => mode = Mode::Paused,
                _ => return,
            }
            continue;
        }
        if matches!(mode, Mode::Paused) {
            if resume.changed().await.is_err() {
                return;
            }
            // changed() marks the version seen; retain the cursor as a pending resume.
            held.paused.store(false, Ordering::Release);
            sub.cursor = Some(*resume.borrow());
            sub.edition = Some(0);
            let Ok(delivery) = open(&hub, &sub) else {
                sink.fail(&sub.sid);
                return;
            };
            let outcome = held.offer(sink.as_ref(), &sub.sid, delivery.first, delivery.cursor);
            match outcome {
                Offer::Taken => {
                    delivery.receiver.reposition(delivery.cursor.0);
                    receiver = delivery.receiver;
                    mode = delivery.mode;
                }
                Offer::NotFed => {}
                _ => return,
            }
            continue;
        }
        let item = tokio::select! {
            biased;
            changed = resume.changed() => {
                if changed.is_err() { return; }
                // Re-use the paused branch without losing the stored version.
                resume.mark_changed();
                continue;
            }
            item = receiver.recv() => match item {
                Some(item) => item,
                None => { sink.fail(&sub.sid); return; }
            },
        };
        let result = if matches!(item, ListItem::Lagged { .. }) {
            sub.cursor = None;
            match open(&hub, &sub) {
                Ok(delivery) => {
                    receiver = delivery.receiver;
                    Ok((delivery.first, delivery.cursor, delivery.mode))
                }
                Err(error) => Err(error),
            }
        } else {
            event_frame(&sub.sid, item, mode)
        };
        let Ok((frame, cursor, next)) = result else {
            sink.fail(&sub.sid);
            return;
        };
        match held.offer(sink.as_ref(), &sub.sid, frame, cursor) {
            Offer::Taken => {
                receiver.reposition(cursor.0);
                mode = next;
            }
            Offer::NotFed => mode = Mode::Paused,
            _ => return,
        }
    }
}
