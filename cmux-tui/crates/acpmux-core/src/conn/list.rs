//! The list source owns delivery and resumes. No replay prefix is retained.
use super::{ConnError, ConnectionMetrics, Offer, OfferSink, Source};
use crate::hub::{Hub, ListReceiver, RawRead};
use crate::wire::{Cursor, Frame, FrameKind, Page, ReplayMark, Sub};
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
    view: Option<crate::wire::ListView>,
    window_out: Arc<AtomicBool>,
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
    peer: bool,
    scope: cmux_scope::Scope,
    tasks: Mutex<HashMap<String, Task>>,
    metrics: Mutex<Option<Arc<ConnectionMetrics>>>,
}
impl HubSource {
    pub fn new(hub: Arc<Hub>) -> Self {
        Self {
            hub,
            peer: false,
            scope: cmux_scope::Scope::new("v2 list connection"),
            tasks: Mutex::new(HashMap::new()),
            metrics: Mutex::new(None),
        }
    }

    pub fn for_peer(hub: Arc<Hub>) -> Self {
        hub.enable_peer_history();
        Self {
            hub,
            peer: true,
            scope: cmux_scope::Scope::new("v2 peer list connection"),
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
        if sub.view == Some(crate::wire::ListView::Folders) {
            self.hub.validate_folder_sub(sub)?;
        }
        if let Ok(mut metrics) = self.metrics.lock() {
            *metrics = Some(sink.metrics());
        }
        let (resume, rx) = watch::channel(Cursor(0));
        let held = Arc::new(Held::default());
        let window_out = Arc::new(AtomicBool::new(false));
        let folders = sub.view == Some(crate::wire::ListView::Folders);
        let join = if folders {
            let hub = self.hub.clone();
            let sub = sub.clone();
            let sink = sink.clone();
            let held = held.clone();
            let window_out = window_out.clone();
            self.scope.spawn(folder_task(hub, sub, sink, rx, held, window_out))
        } else {
            let delivery = open(&self.hub, sub, self.peer)?;
            // The window (or first replay frame) is queued before a task can offer live data.
            if !matches!(sink.offer(&sub.sid, delivery.first, delivery.cursor), Offer::Taken) {
                return Ok(());
            }
            delivery.receiver.reposition(delivery.cursor.0);
            let mut resumed = sub.clone();
            resumed.anchor = None;
            self.scope.spawn(pump(
                self.hub.clone(),
                resumed,
                sink,
                delivery.receiver,
                delivery.mode,
                rx,
                held.clone(),
                self.peer,
            ))
        };
        let mut tasks = self
            .tasks
            .lock()
            .map_err(|_| ConnError::InvalidRequest("list source poisoned".into()))?;
        tasks.insert(sub.sid.clone(), Task { view: sub.view, window_out, resume, join, held });
        Ok(())
    }
    fn page(&self, page: &Page, _person: Option<&[u8]>) -> Result<Frame, ConnError> {
        let tasks = self
            .tasks
            .lock()
            .map_err(|_| ConnError::InvalidRequest("list source poisoned".into()))?;
        let task =
            tasks.get(&page.sid).ok_or_else(|| ConnError::UnknownSubscription(page.sid.clone()))?;
        if task.view == Some(crate::wire::ListView::Folders)
            && !task.window_out.load(Ordering::Acquire)
        {
            return Err(crate::hub::HubError::InvalidPage.into());
        }
        let held_view = task.view;
        if self.peer {
            return Ok(self.hub.peer_page(page)?);
        }
        Ok(self.hub.page_for_view(page, held_view)?)
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

async fn folder_task(
    hub: Arc<Hub>,
    mut sub: Sub,
    sink: Arc<dyn OfferSink>,
    mut resume: watch::Receiver<Cursor>,
    held: Arc<Held>,
    window_out: Arc<AtomicBool>,
) {
    if hub.wait_hydrated().await.is_err() {
        sink.fail(&sub.sid);
        return;
    }
    loop {
        let Ok(delivery) = open(&hub, &sub, false) else {
            sink.fail(&sub.sid);
            return;
        };
        match held.offer(sink.as_ref(), &sub.sid, delivery.first, delivery.cursor) {
            Offer::Taken => {
                window_out.store(true, Ordering::Release);
                delivery.receiver.reposition(delivery.cursor.0);
                sub.anchor = None;
                pump(hub, sub, sink, delivery.receiver, delivery.mode, resume, held, false).await;
                return;
            }
            Offer::NotFed => {
                held.paused.store(true, Ordering::Release);
                if resume.changed().await.is_err() {
                    return;
                }
                sub.cursor = Some(*resume.borrow_and_update());
                sub.edition = Some(0);
            }
            Offer::Dropped { .. } | Offer::UnknownSubscription => return,
        }
    }
}

fn open(hub: &Hub, sub: &Sub, peer: bool) -> Result<Delivery, ConnError> {
    if sub.view != Some(crate::wire::ListView::Folders)
        && sub.edition.is_none_or(|edition| edition == 0 || edition == hub.snapshot().edition())
        && let Some(cursor) = sub.cursor
        && let Some(target) =
            if peer { hub.peer_resume_target(cursor.0)? } else { hub.resume_target(cursor.0)? }
    {
        let receiver = if peer {
            hub.subscribe_replay_peer(sub, cursor.0)?
        } else {
            hub.subscribe_replay(sub, cursor.0)?
        };
        if target == cursor.0 {
            return Ok(Delivery {
                receiver,
                first: raw_frame(&sub.sid, Some(ReplayMark::End), &[])?
                    .map_err(ConnError::InvalidRequest)?,
                cursor,
                mode: Mode::Live,
            });
        }
        let max_bytes = raw_budget(&sub.sid, Some(ReplayMark::Replay))?;
        if let Some(RawRead::Span(span)) = receiver.try_next_raw(Some(target), max_bytes) {
            let final_frame = span.last_seq >= target;
            let mode = if final_frame { Mode::Live } else { Mode::Replay(target) };
            let mark = final_frame.then_some(ReplayMark::End).or(Some(ReplayMark::Replay));
            let frame =
                raw_frame(&sub.sid, mark, &span.bytes)?.map_err(ConnError::InvalidRequest)?;
            let first = frame;
            return Ok(Delivery { receiver, first, cursor: Cursor(span.last_seq), mode });
        }
    }
    let subscription = if peer { hub.subscribe_peer(sub)? } else { hub.subscribe(sub)? };
    // The frame and cursor come from ONE snapshot. Never substitute a second read.
    subscription.receiver.reposition(subscription.cursor);
    let first = if peer { hub.peer_window(sub)? } else { subscription.window };
    Ok(Delivery {
        receiver: subscription.receiver,
        first,
        cursor: Cursor(subscription.cursor),
        mode: Mode::Live,
    })
}

fn raw_parts(sid: &str, replay: Option<ReplayMark>) -> Result<(Vec<u8>, Vec<u8>), ConnError> {
    let encoded_sid = serde_json::to_vec(sid)
        .map_err(|error| ConnError::InvalidRequest(format!("invalid list sid: {error}")))?;
    let mut prefix = br#"{"sid":"#.to_vec();
    prefix.extend_from_slice(&encoded_sid);
    if let Some(replay) = replay {
        let encoded_replay = serde_json::to_vec(&replay)
            .map_err(|error| ConnError::InvalidRequest(format!("invalid replay mark: {error}")))?;
        prefix.extend_from_slice(br#","replay":"#);
        prefix.extend_from_slice(&encoded_replay);
    }
    prefix.extend_from_slice(br#","ops":["#);
    Ok((prefix, b"]}".to_vec()))
}

fn raw_budget(sid: &str, replay: Option<ReplayMark>) -> Result<usize, ConnError> {
    let (prefix, suffix) = raw_parts(sid, replay)?;
    Ok(crate::wire::MAX_REPLAY_FRAME_BYTES
        .saturating_sub(5)
        .saturating_sub(prefix.len())
        .saturating_sub(suffix.len()))
}

fn raw_frame(
    sid: &str,
    replay: Option<ReplayMark>,
    ops: &[u8],
) -> Result<Result<Frame, String>, ConnError> {
    let replay_present = replay.is_some();
    let (prefix, suffix) = raw_parts(sid, replay)?;
    let mut payload = Vec::with_capacity(prefix.len() + ops.len() + suffix.len());
    payload.extend_from_slice(&prefix);
    payload.extend_from_slice(ops);
    payload.extend_from_slice(&suffix);
    let frame = Frame::new(FrameKind::Delta, payload)
        .map_err(|error| ConnError::InvalidRequest(error.to_string()))?;
    if replay_present && frame.encoded_len() > crate::wire::MAX_REPLAY_FRAME_BYTES {
        return Ok(Err("list replay operation exceeds replay bound".into()));
    }
    Ok(Ok(frame))
}

#[allow(clippy::too_many_arguments)]
async fn pump(
    hub: Arc<Hub>,
    mut sub: Sub,
    sink: Arc<dyn OfferSink>,
    mut receiver: ListReceiver,
    mut mode: Mode,
    mut resume: watch::Receiver<Cursor>,
    held: Arc<Held>,
    peer: bool,
) {
    loop {
        if resume.has_changed().unwrap_or(false) {
            held.paused.store(false, Ordering::Release);
            sub.cursor = Some(*resume.borrow_and_update());
            sub.edition = Some(0);
            if sub.view == Some(crate::wire::ListView::Folders) {
                // Credit resumes this live sid from its last accepted step.
                // A new sub still always starts with a window; only a tail
                // overrun below needs to replace this sid's existing window.
                receiver.reposition(sub.cursor.unwrap_or_default().0);
                mode = Mode::Live;
                continue;
            }
            let Ok(delivery) = open(&hub, &sub, peer) else {
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
            if sub.view == Some(crate::wire::ListView::Folders) {
                // Credit resumes this live sid from its last accepted step.
                // A new sub still always starts with a window; only a tail
                // overrun below needs to replace this sid's existing window.
                receiver.reposition(sub.cursor.unwrap_or_default().0);
                mode = Mode::Live;
                continue;
            }
            let Ok(delivery) = open(&hub, &sub, peer) else {
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
        let replay_mark = match mode {
            Mode::Replay(_) => Some(ReplayMark::Replay),
            _ => None,
        };
        let max_bytes = match raw_budget(&sub.sid, replay_mark) {
            Ok(max_bytes) => max_bytes,
            Err(_) => {
                sink.fail(&sub.sid);
                return;
            }
        };
        let read = tokio::select! {
            biased;
            changed = resume.changed() => {
                if changed.is_err() { return; }
                // Re-use the paused branch without losing the stored version.
                resume.mark_changed();
                continue;
            }
            item = receiver.recv_raw(match mode { Mode::Replay(target) => Some(target), _ => None }, max_bytes) => match item {
                Some(item) => item,
                None => { sink.fail(&sub.sid); return; }
            },
        };
        let result = match read {
            RawRead::Lagged => {
                sub.cursor = None;
                match open(&hub, &sub, peer) {
                    Ok(delivery) => {
                        receiver = delivery.receiver;
                        Ok((delivery.first, delivery.cursor, delivery.mode))
                    }
                    Err(error) => Err(error),
                }
            }
            RawRead::Span(span) => {
                if span.bytes.is_empty() && matches!(mode, Mode::Live) {
                    continue;
                }
                let final_frame = matches!(mode, Mode::Replay(target) if span.last_seq >= target);
                let replay = match mode {
                    Mode::Replay(_) => {
                        Some(if final_frame { ReplayMark::End } else { ReplayMark::Replay })
                    }
                    _ => None,
                };
                let next = if final_frame { Mode::Live } else { mode };
                raw_frame(&sub.sid, replay, &span.bytes)
                    .and_then(|frame| frame.map_err(ConnError::InvalidRequest))
                    .map(|frame| (frame, Cursor(span.last_seq), next))
            }
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
