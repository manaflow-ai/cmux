//! One bounded v2 connection over any ordered byte stream.

use crate::hub::{Hub, HubError, ListItem, ListReceiver};
use crate::wire::{
    CONNECTION_BUDGET_BYTES, CREDIT_WINDOW_BYTES, Credit, Cursor, DeltaFrame, DeltaOp, Dropped,
    Frame, FrameError, FrameKind, Hello, HelloReply, Limits, Page, ReplayMark, Sub, Unsub,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Notify;

pub const MAX_SUBSCRIPTIONS: usize = crate::wire::MAX_SUBSCRIPTIONS;
const DROPPED_NOTICE_RESERVE_BYTES: usize = 256;

fn notice_reserve(budget: usize) -> usize {
    if budget > DROPPED_NOTICE_RESERVE_BYTES.saturating_mul(2) {
        DROPPED_NOTICE_RESERVE_BYTES
    } else {
        0
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "method", content = "params", rename_all = "lowercase")]
pub enum Request {
    Hello(Hello),
    Sub(Sub),
    Page(Page),
    Credit(Credit),
    Unsub(Unsub),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Offer {
    Taken,
    NotFed,
    Dropped { sid: String, cursor: Cursor },
    UnknownSubscription,
}

#[derive(Clone, Debug)]
struct Queued {
    sid: Option<String>,
    cursor: Cursor,
    frame: Frame,
}

#[derive(Clone, Debug)]
struct SubscriptionState {
    sent: u64,
    consumed: u64,
    cursor: Cursor,
    dropped: bool,
    control: Arc<SubscriptionControl>,
}

#[derive(Debug, Default)]
pub struct SubscriptionControl {
    ended: AtomicBool,
    wake: Notify,
}

impl SubscriptionControl {
    pub fn end(&self) {
        self.ended.store(true, Ordering::Release);
        self.wake.notify_waiters();
    }

    pub fn ended(&self) -> bool {
        self.ended.load(Ordering::Acquire)
    }

    pub async fn wait(&self) {
        self.wake.notified().await;
    }
}

/// The connection-owned queue and credit accounting.
#[derive(Debug)]
pub struct ConnectionState {
    queue: VecDeque<Queued>,
    subscriptions: HashMap<String, SubscriptionState>,
    queued_bytes: usize,
    budget: usize,
    identity: Option<Vec<u8>>,
}

impl Default for ConnectionState {
    fn default() -> Self {
        Self::new(CONNECTION_BUDGET_BYTES)
    }
}

impl ConnectionState {
    pub fn new(budget: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            subscriptions: HashMap::new(),
            queued_bytes: 0,
            budget,
            identity: None,
        }
    }

    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    pub fn subscription_count(&self) -> usize {
        self.subscriptions.len()
    }

    pub fn identity(&self) -> Option<&[u8]> {
        self.identity.as_deref()
    }

    fn set_identity(&mut self, identity: Option<&str>) -> Result<(), ConnError> {
        if identity.is_some_and(|identity| identity.len() > 64) {
            return Err(ConnError::IdentityTooLarge);
        }
        self.identity = identity.map(|identity| identity.as_bytes().to_vec());
        Ok(())
    }

    pub fn subscribe(&mut self, sid: impl Into<String>, cursor: Cursor) -> Result<(), ConnError> {
        if self.subscriptions.len() >= MAX_SUBSCRIPTIONS {
            return Err(ConnError::TooManySubscriptions);
        }
        let sid = sid.into();
        if self.subscriptions.contains_key(&sid) {
            return Err(ConnError::DuplicateSubscription(sid));
        }
        self.subscriptions.insert(
            sid,
            SubscriptionState {
                sent: 0,
                consumed: 0,
                cursor,
                dropped: false,
                control: Arc::new(SubscriptionControl::default()),
            },
        );
        Ok(())
    }

    pub fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>> {
        self.subscriptions.get(sid).map(|state| state.control.clone())
    }

    pub fn unsubscribe(&mut self, sid: &str) -> bool {
        let removed = self.subscriptions.remove(sid);
        if let Some(subscription) = removed {
            subscription.control.end();
            self.remove_queued_for(sid);
            return true;
        }
        false
    }

    pub fn credit(&mut self, credit: Credit) -> Result<bool, ConnError> {
        let Some(subscription) = self.subscriptions.get_mut(&credit.sid) else {
            return Err(ConnError::UnknownSubscription(credit.sid));
        };
        subscription.consumed = subscription.consumed.max(credit.consumed).min(subscription.sent);
        subscription.control.wake.notify_waiters();
        Ok(subscription.consumed < subscription.sent)
    }

    pub fn offer(&mut self, sid: &str, frame: Frame, cursor: Cursor) -> Offer {
        let Some(subscription) = self.subscriptions.get(sid) else {
            return Offer::UnknownSubscription;
        };
        if subscription.dropped {
            return Offer::NotFed;
        }
        let encoded = frame.encoded_len();
        if subscription.sent.saturating_sub(subscription.consumed).saturating_add(encoded as u64)
            > CREDIT_WINDOW_BYTES
        {
            return Offer::NotFed;
        }
        if self.queued_bytes.saturating_add(encoded).saturating_add(notice_reserve(self.budget))
            > self.budget
        {
            let cursor = self.drop_subscription(sid);
            return Offer::Dropped { sid: sid.to_owned(), cursor };
        }
        let Some(subscription) = self.subscriptions.get_mut(sid) else {
            return Offer::UnknownSubscription;
        };
        subscription.sent = subscription.sent.saturating_add(encoded as u64);
        self.queued_bytes = self.queued_bytes.saturating_add(encoded);
        self.queue.push_back(Queued { sid: Some(sid.to_owned()), cursor, frame });
        Offer::Taken
    }

    pub fn offer_reply(&mut self, frame: Frame) -> Result<(), ConnError> {
        let encoded = frame.encoded_len();
        if self.queued_bytes.saturating_add(encoded).saturating_add(notice_reserve(self.budget))
            > self.budget
        {
            return Err(ConnError::ReplyBudget);
        }
        self.queued_bytes = self.queued_bytes.saturating_add(encoded);
        self.queue.push_back(Queued { sid: None, cursor: Cursor::default(), frame });
        Ok(())
    }

    pub fn take(&mut self) -> Option<FrameLease> {
        self.queue.pop_front().map(|queued| {
            self.queued_bytes = self.queued_bytes.saturating_sub(queued.frame.encoded_len());
            FrameLease { sid: queued.sid, cursor: queued.cursor, frame: queued.frame }
        })
    }

    pub fn written(&mut self, lease: &FrameLease) {
        if let Some(sid) = lease.sid.as_deref()
            && let Some(subscription) = self.subscriptions.get_mut(sid)
        {
            subscription.cursor = lease.cursor;
        }
    }

    fn drop_subscription(&mut self, sid: &str) -> Cursor {
        let cursor = self.subscriptions.get(sid).map(|s| s.cursor).unwrap_or_default();
        self.remove_queued_for(sid);
        let subscription = self.subscriptions.remove(sid);
        if let Some(subscription) = subscription {
            subscription.control.end();
        }
        let notice = Frame::json(FrameKind::Dropped, &Dropped { sid: sid.to_owned(), cursor });
        if let Ok(frame) = notice
            && self.queued_bytes.saturating_add(frame.encoded_len()) <= self.budget
        {
            self.queued_bytes = self.queued_bytes.saturating_add(frame.encoded_len());
            self.queue.push_back(Queued { sid: None, cursor, frame });
        }
        cursor
    }

    fn remove_queued_for(&mut self, sid: &str) {
        let mut kept = VecDeque::with_capacity(self.queue.len());
        while let Some(queued) = self.queue.pop_front() {
            if queued.sid.as_deref() == Some(sid) {
                self.queued_bytes = self.queued_bytes.saturating_sub(queued.frame.encoded_len());
            } else {
                kept.push_back(queued);
            }
        }
        self.queue = kept;
    }
}

pub struct FrameLease {
    sid: Option<String>,
    cursor: Cursor,
    pub frame: Frame,
}

#[derive(Debug, thiserror::Error)]
pub enum ConnError {
    #[error("frame error: {0}")]
    Frame(#[from] FrameError),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("too many subscriptions")]
    TooManySubscriptions,
    #[error("duplicate subscription {0:?}")]
    DuplicateSubscription(String),
    #[error("unknown subscription {0:?}")]
    UnknownSubscription(String),
    #[error("reply queue budget exceeded")]
    ReplyBudget,
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("hub error: {0}")]
    Hub(#[from] HubError),
    #[error("identity proof is larger than 64 bytes")]
    IdentityTooLarge,
}

/// The source's non-blocking sink. A source must treat `NotFed` as a cursor
/// boundary: it stops reading and calls `resume` after the connection signals
/// credit. No source task is allowed to await this method.
pub trait OfferSink: Send + Sync {
    fn offer(&self, sid: &str, frame: Frame, cursor: Cursor) -> Offer;
    fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>>;
}

pub struct SourceSubscription {
    pub initial: Option<(Frame, Cursor)>,
    pub replay: Vec<(Frame, Cursor)>,
    pub events: Option<SubscriptionEvents>,
}

/// Events a source can deliver after its initial frame. The source owns the
/// receiver and its task; the connection owns only the sink and byte budget.
pub enum SubscriptionEvents {
    List(ListReceiver),
}

/// A source owns ordering and resume policy. Chat actors implement this trait
/// without exposing a queue to the connection; list uses the same seam.
pub trait Source: Send + Sync + 'static {
    fn subscribe(
        &self,
        sub: &Sub,
        identity: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<SourceSubscription, ConnError>;

    fn resume(
        &self,
        _sid: &str,
        _cursor: Cursor,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        Ok(())
    }

    fn page(&self, _page: &Page, _identity: Option<&[u8]>) -> Result<Frame, ConnError> {
        Err(ConnError::InvalidRequest("page is not supported for this stream".into()))
    }

    fn end(&self, _sid: &str) {}
}

pub struct HubSource {
    hub: Arc<Hub>,
}

impl HubSource {
    pub fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl Source for HubSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _identity: Option<&[u8]>,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<SourceSubscription, ConnError> {
        if sub.stream.as_str() != "list" {
            return Err(ConnError::InvalidRequest("no such stream".into()));
        }
        let subscription = self.hub.subscribe(sub)?;
        let resume = if sub.edition.is_none_or(|edition| edition == 0) {
            self.hub.list_resume(sub)?
        } else {
            None
        };
        let (initial, replay) = if let Some(items) = resume {
            let mut frames = list_replay_frames(&sub.sid, &items)?;
            if items.is_empty()
                && let Some((_, cursor)) = frames.last_mut()
            {
                *cursor = Cursor(sub.cursor.map_or(0, |cursor| cursor.0));
            }
            let mut frames = frames.into_iter();
            (frames.next(), frames.collect())
        } else {
            (Some((subscription.window, Cursor(self.hub.snapshot().seq()))), Vec::new())
        };
        Ok(SourceSubscription {
            initial,
            replay,
            events: Some(SubscriptionEvents::List(subscription.receiver)),
        })
    }

    fn resume(
        &self,
        _sid: &str,
        _cursor: Cursor,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        // The list receiver is cursor based; its task retries from the same
        // receiver cursor after credit. A missed-history source returns a fresh
        // window from `subscribe` instead.
        Ok(())
    }

    fn page(&self, page: &Page, _identity: Option<&[u8]>) -> Result<Frame, ConnError> {
        if page.stream.as_str() != "list" {
            return Err(ConnError::InvalidRequest("no such stream".into()));
        }
        let sub = Sub::new(page.sid.clone(), page.stream.clone());
        Ok(self.hub.list_window(&sub)?)
    }
}

pub struct MissingChatSource;

impl Source for MissingChatSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _identity: Option<&[u8]>,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<SourceSubscription, ConnError> {
        if sub.stream.as_str().starts_with("chat:") {
            Err(ConnError::InvalidRequest("no such stream".into()))
        } else {
            Err(ConnError::InvalidRequest("unsupported stream".into()))
        }
    }
}

/// Runs the framing loop. The writer is owned exclusively by this task.
#[derive(Clone)]
struct ConnectionSink {
    state: Arc<std::sync::Mutex<ConnectionState>>,
}

impl OfferSink for ConnectionSink {
    fn offer(&self, sid: &str, frame: Frame, cursor: Cursor) -> Offer {
        self.state
            .lock()
            .map_or(Offer::UnknownSubscription, |mut state| state.offer(sid, frame, cursor))
    }

    fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>> {
        self.state.lock().ok().and_then(|state| state.control(sid))
    }
}

pub async fn run<R, W, S>(
    mut reader: R,
    mut writer: W,
    source: Arc<S>,
    daemon_id: impl Into<String>,
) -> Result<(), ConnError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    S: Source,
{
    let hello = Frame::json(
        FrameKind::Hello,
        &HelloReply { daemon_id: daemon_id.into(), limits: Limits::default() },
    )?;
    writer.write_all(&hello.encode()).await?;
    let mut decoder = crate::wire::FrameDecoder::default();
    let mut buffer = [0_u8; 16 * 1024];
    let state = Arc::new(std::sync::Mutex::new(ConnectionState::default()));
    let sink: Arc<dyn OfferSink> = Arc::new(ConnectionSink { state: state.clone() });
    let mut pending = VecDeque::new();
    let mut writing: Option<FrameLease> = None;
    let mut hello_seen = false;
    loop {
        if writing.is_none() {
            writing = state.lock().ok().and_then(|mut state| state.take());
        }
        tokio::select! {
            biased;
            result = write_lease(&mut writer, writing.as_ref()), if writing.is_some() => {
                result?;
                if let Some(lease) = writing.take()
                    && let Ok(mut state) = state.lock()
                {
                    state.written(&lease);
                }
            }
            Some(frame) = async { pending.pop_front() }, if !pending.is_empty() => {
                if let Err(error) = process_frame(&state, source.clone(), frame, sink.clone(), &mut hello_seen).await {
                    queue_error(&state, &error.to_string());
                }
            }
            read = reader.read(&mut buffer) => {
                let read = read?;
                if read == 0 {
                    let sids = state
                        .lock()
                        .map(|state| state.subscriptions.keys().cloned().collect::<Vec<_>>())
                        .unwrap_or_default();
                    for sid in sids {
                        source.end(&sid);
                        if let Ok(mut state) = state.lock() {
                            state.unsubscribe(&sid);
                        }
                    }
                    return Ok(());
                }
                match decoder.push(&buffer[..read]) {
                    Ok(frames) => pending.extend(frames),
                    Err(error) => queue_error(&state, &error.to_string()),
                }
            }
        }
    }
}

async fn process_frame<S: Source>(
    state: &Arc<std::sync::Mutex<ConnectionState>>,
    source: Arc<S>,
    frame: Frame,
    sink: Arc<dyn OfferSink>,
    hello_seen: &mut bool,
) -> Result<(), ConnError> {
    if frame.kind != FrameKind::Request {
        return Err(ConnError::InvalidRequest("expected request frame".into()));
    }
    let request: Request = match frame.decode_json() {
        Ok(request) => request,
        Err(error) => {
            queue_error(state, &format!("invalid request: {error}"));
            return Ok(());
        }
    };
    match request {
        Request::Hello(hello) => {
            validate_hello(&hello)?;
            if *hello_seen {
                return Err(ConnError::InvalidRequest("hello was already received".into()));
            }
            state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .set_identity(hello.identity.as_deref())?;
            *hello_seen = true;
            Ok(())
        }
        Request::Sub(sub) => {
            if !*hello_seen {
                return Err(ConnError::InvalidRequest("hello must be first".into()));
            }
            let sid = sub.sid.clone();
            let identity =
                state.lock().ok().and_then(|state| state.identity().map(ToOwned::to_owned));
            state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .subscribe(sid.clone(), Cursor(sub.cursor.map_or(0, |c| c.0)))?;
            let subscription = match source.subscribe(&sub, identity.as_deref(), sink.clone()) {
                Ok(subscription) => subscription,
                Err(error) => {
                    if let Ok(mut state) = state.lock() {
                        state.unsubscribe(&sid);
                    }
                    return Err(error);
                }
            };
            let mut prefix = subscription.replay;
            if let Some(initial) = subscription.initial {
                prefix.insert(0, initial);
            }
            let events = subscription.events;
            let task_sid = sid;
            let sink = sink.clone();
            let control = sink.control(&task_sid);
            if let Some(control) = control {
                tokio::spawn(async move {
                    let replay_cursor = prefix.last().map(|(_, cursor)| *cursor);
                    for (frame, cursor) in prefix {
                        let outcome = drive_offer(
                            source.as_ref(),
                            sink.clone(),
                            task_sid.clone(),
                            control.clone(),
                            frame,
                            cursor,
                        )
                        .await;
                        if control.ended()
                            || matches!(outcome, Offer::Dropped { .. } | Offer::UnknownSubscription)
                        {
                            return;
                        }
                    }
                    if let Some(SubscriptionEvents::List(receiver)) = events {
                        if let Some(cursor) = replay_cursor {
                            receiver.advance_to(cursor.0);
                        }
                        while !control.ended() {
                            let Some(item) = receiver.recv().await else { break };
                            let Ok((frame, cursor)) = list_item_frame(&task_sid, item) else {
                                break;
                            };
                            let outcome = drive_offer(
                                source.as_ref(),
                                sink.clone(),
                                task_sid.clone(),
                                control.clone(),
                                frame,
                                cursor,
                            )
                            .await;
                            if matches!(outcome, Offer::Taken) {
                                receiver.advance_to(cursor.0);
                            }
                            if control.ended()
                                || matches!(
                                    outcome,
                                    Offer::Dropped { .. } | Offer::UnknownSubscription
                                )
                            {
                                return;
                            }
                        }
                    }
                });
            }
            Ok(())
        }
        Request::Credit(credit) => {
            let cursor = state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .subscriptions
                .get(&credit.sid)
                .map(|subscription| subscription.cursor)
                .unwrap_or_default();
            state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .credit(credit.clone())?;
            source.resume(&credit.sid, cursor, sink)?;
            Ok(())
        }
        Request::Unsub(unsub) => {
            source.end(&unsub.sid);
            state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .unsubscribe(&unsub.sid);
            Ok(())
        }
        Request::Page(page) => {
            if page.before.is_some() || page.after.is_some() {
                return Err(ConnError::InvalidRequest("page anchors are not available yet".into()));
            }
            let identity =
                state.lock().ok().and_then(|state| state.identity().map(ToOwned::to_owned));
            let frame = source.page(&page, identity.as_deref())?;
            state
                .lock()
                .map_err(|_| ConnError::InvalidRequest("connection state poisoned".into()))?
                .offer_reply(frame)
        }
    }
}

async fn write_lease<W: AsyncWrite + Unpin>(
    writer: &mut W,
    lease: Option<&FrameLease>,
) -> Result<(), std::io::Error> {
    match lease {
        Some(lease) => writer.write_all(&lease.frame.encode()).await,
        None => std::future::pending().await,
    }
}

fn queue_error(state: &Arc<std::sync::Mutex<ConnectionState>>, message: &str) {
    if let Ok(frame) = Frame::json(FrameKind::Error, &serde_json::json!({"message": message}))
        && let Ok(mut state) = state.lock()
    {
        let _ = state.offer_reply(frame);
    }
}

async fn drive_offer(
    source: &dyn Source,
    sink: Arc<dyn OfferSink>,
    sid: String,
    control: Arc<SubscriptionControl>,
    frame: Frame,
    cursor: Cursor,
) -> Offer {
    drive_offer_inner(Some(source), sink, sid, control, frame, cursor).await
}

async fn drive_offer_inner(
    source: Option<&dyn Source>,
    sink: Arc<dyn OfferSink>,
    sid: String,
    control: Arc<SubscriptionControl>,
    frame: Frame,
    cursor: Cursor,
) -> Offer {
    loop {
        if control.ended() {
            return Offer::UnknownSubscription;
        }
        match sink.offer(&sid, frame.clone(), cursor) {
            Offer::Taken => return Offer::Taken,
            Offer::Dropped { sid: dropped_sid, cursor: dropped_cursor } => {
                if let Some(source) = source {
                    source.end(&sid);
                }
                return Offer::Dropped { sid: dropped_sid, cursor: dropped_cursor };
            }
            Offer::UnknownSubscription => return Offer::UnknownSubscription,
            Offer::NotFed => control.wait().await,
        }
    }
}

fn validate_hello(hello: &Hello) -> Result<(), ConnError> {
    if hello.identity.as_ref().is_some_and(|identity| identity.len() > 64) {
        return Err(ConnError::IdentityTooLarge);
    }
    if hello.protocol != 2 {
        return Err(ConnError::InvalidRequest("unsupported protocol".into()));
    }
    Ok(())
}

fn item_cursor(item: &ListItem) -> u64 {
    match item {
        ListItem::Summary(event) => event.seq,
        ListItem::Gone { seq, .. } => *seq,
        ListItem::Dropped { cursor } => *cursor,
    }
}

fn list_item_frame(sid: &str, item: ListItem) -> Result<(Frame, Cursor), ConnError> {
    match item {
        ListItem::Summary(event) => Ok((
            Frame::json(
                FrameKind::Delta,
                &DeltaFrame {
                    sid: sid.to_owned(),
                    replay: None,
                    ops: vec![DeltaOp::Summary {
                        seq: event.seq,
                        summary: (*event.summary).clone(),
                    }],
                },
            )?,
            Cursor(event.seq),
        )),
        ListItem::Gone { seq, chat_id } => Ok((
            Frame::json(
                FrameKind::Delta,
                &DeltaFrame::<serde_json::Value> {
                    sid: sid.to_owned(),
                    replay: None,
                    ops: vec![DeltaOp::Gone { seq, chat_id }],
                },
            )?,
            Cursor(seq),
        )),
        ListItem::Dropped { cursor } => Ok((
            Frame::json(
                FrameKind::Dropped,
                &Dropped { sid: sid.to_owned(), cursor: Cursor(cursor) },
            )?,
            Cursor(cursor),
        )),
    }
}

fn list_replay_frames(sid: &str, items: &[ListItem]) -> Result<Vec<(Frame, Cursor)>, ConnError> {
    let mut result = Vec::new();
    let mut ops: Vec<DeltaOp<acpmux_book::index::Summary>> = Vec::new();
    let mut cursor = 0;
    let flush = |result: &mut Vec<(Frame, Cursor)>,
                 ops: &mut Vec<DeltaOp<acpmux_book::index::Summary>>,
                 sid: &str,
                 cursor: u64,
                 mark: ReplayMark|
     -> Result<(), ConnError> {
        let frame = Frame::json(
            FrameKind::Delta,
            &DeltaFrame { sid: sid.to_owned(), replay: Some(mark), ops: std::mem::take(ops) },
        )?;
        result.push((frame, Cursor(cursor)));
        Ok(())
    };
    for item in items {
        let op = match item {
            ListItem::Summary(event) => {
                DeltaOp::Summary { seq: event.seq, summary: (*event.summary).clone() }
            }
            ListItem::Gone { seq, chat_id } => {
                DeltaOp::Gone { seq: *seq, chat_id: chat_id.clone() }
            }
            ListItem::Dropped { cursor: dropped } => {
                let frame = Frame::json(
                    FrameKind::Dropped,
                    &Dropped { sid: sid.to_owned(), cursor: Cursor(*dropped) },
                )?;
                result.push((frame, Cursor(*dropped)));
                continue;
            }
        };
        let next_cursor = item_cursor(item);
        ops.push(op);
        let probe = Frame::json(
            FrameKind::Delta,
            &DeltaFrame { sid: sid.to_owned(), replay: Some(ReplayMark::Replay), ops: ops.clone() },
        )?;
        if probe.encoded_len() > crate::wire::MAX_REPLAY_FRAME_BYTES && ops.len() > 1 {
            let last = ops
                .pop()
                .ok_or_else(|| ConnError::InvalidRequest("empty replay operation".into()))?;
            let previous_cursor = cursor;
            flush(&mut result, &mut ops, sid, previous_cursor, ReplayMark::Replay)?;
            ops.push(last);
        }
        cursor = next_cursor;
    }
    if ops.is_empty() {
        let frame = Frame::json(
            FrameKind::Delta,
            &DeltaFrame::<serde_json::Value> {
                sid: sid.to_owned(),
                replay: Some(ReplayMark::End),
                ops: Vec::new(),
            },
        )?;
        result.push((frame, Cursor(cursor)));
    } else {
        flush(&mut result, &mut ops, sid, cursor, ReplayMark::End)?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::SummaryHub;
    use acpmux_book::index::{Summary, SummaryIndex};
    use serde_json::json;

    fn frame(bytes: usize) -> Frame {
        Frame::new(FrameKind::Delta, vec![0; bytes]).unwrap()
    }

    #[test]
    fn queue_is_bounded_and_drops_only_the_overflowing_subscription() {
        let mut state = ConnectionState::new(128);
        state.subscribe("slow", Cursor(7)).unwrap();
        state.subscribe("fast", Cursor(2)).unwrap();
        assert_eq!(state.offer("slow", frame(90), Cursor(8)), Offer::Taken);
        assert!(matches!(state.offer("slow", frame(40), Cursor(9)), Offer::Dropped { .. }));
        assert_eq!(state.subscription_count(), 1);
        assert_eq!(state.offer("fast", frame(16), Cursor(3)), Offer::Taken);
        state.subscribe("slow", Cursor(9)).expect("dropped sid is reusable");
    }

    #[test]
    fn credit_is_monotonic_and_duplicate_credit_is_free() {
        let mut state = ConnectionState::default();
        state.subscribe("s", Cursor(0)).unwrap();
        assert_eq!(state.offer("s", frame(20), Cursor(1)), Offer::Taken);
        assert!(state.credit(Credit { sid: "s".into(), consumed: 10 }).unwrap());
        assert!(state.credit(Credit { sid: "s".into(), consumed: 5 }).unwrap());
    }

    #[test]
    fn request_shape_is_tagged() {
        let request = Request::Credit(Credit { sid: "s".into(), consumed: 4 });
        let value = serde_json::to_value(request).unwrap();
        assert_eq!(value, json!({"method":"credit","params":{"sid":"s","consumed":4}}));
    }

    #[test]
    fn list_resume_that_missed_nothing_is_one_end_marker() {
        let frames = list_replay_frames("s", &[]).unwrap();
        assert_eq!(frames.len(), 1);
        let delta: DeltaFrame<Summary> = frames[0].0.decode_json().unwrap();
        assert_eq!(delta.replay, Some(ReplayMark::End));
        assert!(delta.ops.is_empty());
    }

    #[test]
    fn a_cursor_only_subscriber_reports_zero_retained_bytes() {
        let (hub, _) = SummaryHub::new(SummaryIndex::new());
        assert_eq!(hub.not_fed_bytes(), 0);
    }
}
