//! One bounded v2 connection over any ordered byte stream.

use crate::hub::{Hub, HubError, ListItem, ListReceiver};
use crate::wire::{
    CONNECTION_BUDGET_BYTES, CREDIT_WINDOW_BYTES, Credit, Cursor, Delta, Dropped, Frame,
    FrameError, FrameKind, Hello, HelloReply, Limits, Page, ReplayMark, Sub, Unsub,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

pub const MAX_SUBSCRIPTIONS: usize = crate::wire::MAX_SUBSCRIPTIONS;

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
        self.subscriptions
            .insert(sid, SubscriptionState { sent: 0, consumed: 0, cursor, dropped: false });
        Ok(())
    }

    pub fn unsubscribe(&mut self, sid: &str) -> bool {
        let removed = self.subscriptions.remove(sid).is_some();
        if removed {
            self.remove_queued_for(sid);
        }
        removed
    }

    pub fn credit(&mut self, credit: Credit) -> Result<bool, ConnError> {
        let Some(subscription) = self.subscriptions.get_mut(&credit.sid) else {
            return Err(ConnError::UnknownSubscription(credit.sid));
        };
        subscription.consumed = subscription.consumed.max(credit.consumed).min(subscription.sent);
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
        if self.queued_bytes.saturating_add(encoded) > self.budget {
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
        if self.queued_bytes.saturating_add(encoded) > self.budget {
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
        if let Some(subscription) = self.subscriptions.get_mut(sid) {
            subscription.dropped = true;
            subscription.sent = subscription.consumed;
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

/// Events a source can deliver after its initial frame. A list receiver reads
/// from the hub's cursor history; chat actors can add their own event variant
/// without changing the connection's framing or queue policy.
pub enum SubscriptionEvents {
    List(ListReceiver),
}

pub struct SourceSubscription {
    pub initial: Frame,
    pub initial_cursor: Cursor,
    pub prefix: Vec<(Frame, Cursor)>,
    pub events: Option<SubscriptionEvents>,
}

/// A source can provide an initial bounded frame. The streaming method is a
/// default so chat sources can land later without changing existing adapters.
pub trait Source: Send + Sync {
    fn subscribe(&self, sub: &Sub) -> Result<Frame, ConnError>;

    fn subscribe_for(&self, sub: &Sub, _identity: Option<&[u8]>) -> Result<Frame, ConnError> {
        self.subscribe(sub)
    }

    fn subscribe_stream(&self, sub: &Sub) -> Result<SourceSubscription, ConnError> {
        Ok(SourceSubscription {
            initial: self.subscribe(sub)?,
            initial_cursor: Cursor(sub.cursor.map_or(0, |cursor| cursor.0)),
            prefix: Vec::new(),
            events: None,
        })
    }

    fn subscribe_stream_for(
        &self,
        sub: &Sub,
        identity: Option<&[u8]>,
    ) -> Result<SourceSubscription, ConnError> {
        Ok(SourceSubscription {
            initial: self.subscribe_for(sub, identity)?,
            initial_cursor: Cursor(sub.cursor.map_or(0, |cursor| cursor.0)),
            prefix: Vec::new(),
            events: None,
        })
    }

    fn page(&self, _page: &Page) -> Result<Frame, ConnError> {
        Err(ConnError::InvalidRequest("page is not supported for this stream".into()))
    }
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
    fn subscribe(&self, sub: &Sub) -> Result<Frame, ConnError> {
        if sub.stream.as_str() != "list" {
            return Err(ConnError::InvalidRequest("no such stream".into()));
        }
        Ok(self.hub.subscribe(sub)?.window)
    }

    fn subscribe_stream(&self, sub: &Sub) -> Result<SourceSubscription, ConnError> {
        if sub.stream.as_str() != "list" {
            return Err(ConnError::InvalidRequest("no such stream".into()));
        }
        let subscription = self.hub.subscribe(sub)?;
        let cursor = self.hub.snapshot().seq();
        let resume = self.hub.list_resume(sub)?;
        let resuming = resume.is_some();
        let mut prefix = Vec::new();
        if let Some(items) = resume {
            for item in items {
                let (frame, item_cursor) = list_item_frame(&sub.sid, item)?;
                prefix.push((frame, item_cursor));
            }
            prefix.push((
                Frame::json(
                    FrameKind::Delta,
                    &Delta::<serde_json::Value>::Marker {
                        sid: sub.sid.clone(),
                        replay: Some(ReplayMark::End),
                    },
                )?,
                Cursor(cursor),
            ));
            subscription.receiver.advance_to(cursor);
        }
        let (initial, initial_cursor) = if resuming {
            prefix.remove(0)
        } else {
            (subscription.window, Cursor(sub.cursor.map_or(0, |cursor| cursor.0)))
        };
        Ok(SourceSubscription {
            initial,
            initial_cursor,
            prefix,
            events: Some(SubscriptionEvents::List(subscription.receiver)),
        })
    }

    fn page(&self, page: &Page) -> Result<Frame, ConnError> {
        if page.stream.as_str() != "list" {
            return Err(ConnError::InvalidRequest("no such stream".into()));
        }
        let sub = Sub::new(page.sid.clone(), page.stream.clone());
        Ok(self.hub.list_window(&sub)?)
    }
}

pub struct MissingChatSource;

impl Source for MissingChatSource {
    fn subscribe(&self, sub: &Sub) -> Result<Frame, ConnError> {
        if sub.stream.as_str().starts_with("chat:") {
            Err(ConnError::InvalidRequest("no such stream".into()))
        } else {
            Err(ConnError::InvalidRequest("unsupported stream".into()))
        }
    }
}

/// Runs the framing loop. The writer is owned exclusively by this task.
pub async fn run<R, W, S>(
    mut reader: R,
    mut writer: W,
    source: Arc<S>,
    daemon_id: impl Into<String>,
) -> Result<(), ConnError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    S: Source + ?Sized,
{
    let hello = Frame::json(
        FrameKind::Hello,
        &HelloReply { daemon_id: daemon_id.into(), limits: Limits::default() },
    )?;
    writer.write_all(&hello.encode()).await?;
    let mut decoder = crate::wire::FrameDecoder::default();
    let mut buffer = [0_u8; 16 * 1024];
    let mut state = ConnectionState::default();
    let (events_tx, mut events_rx) = mpsc::channel::<(String, Frame, Cursor)>(128);
    loop {
        while let Some(lease) = state.take() {
            writer.write_all(&lease.frame.encode()).await?;
            state.written(&lease);
        }
        tokio::select! {
            Some((sid, frame, cursor)) = events_rx.recv() => {
                let _ = state.offer(&sid, frame, cursor);
            }
            read = reader.read(&mut buffer) => {
                let read = read?;
                if read == 0 {
                    return Ok(());
                }
                for frame in decoder.push(&buffer[..read])? {
                    handle_frame(&mut state, source.as_ref(), frame, &events_tx)?;
                }
            }
        }
    }
}

fn handle_frame<S: Source + ?Sized>(
    state: &mut ConnectionState,
    source: &S,
    frame: Frame,
    events_tx: &mpsc::Sender<(String, Frame, Cursor)>,
) -> Result<(), ConnError> {
    if frame.kind != FrameKind::Request {
        return Ok(());
    }
    let request: Request = frame.decode_json()?;
    match request {
        Request::Hello(hello) => {
            validate_hello(&hello)?;
            state.set_identity(hello.identity.as_deref())
        }
        Request::Sub(sub) => {
            let identity = state.identity().map(ToOwned::to_owned);
            let SourceSubscription { initial, initial_cursor, prefix, events } =
                source.subscribe_stream_for(&sub, identity.as_deref())?;
            let sid = sub.sid.clone();
            state.subscribe(sid.clone(), Cursor(sub.cursor.map_or(0, |c| c.0)))?;
            match state.offer(&sid, initial, initial_cursor) {
                Offer::Taken | Offer::NotFed => Ok(()),
                Offer::Dropped { .. } => Ok(()),
                Offer::UnknownSubscription => Err(ConnError::UnknownSubscription(sid.clone())),
            }?;
            for (frame, cursor) in prefix {
                let _ = state.offer(&sid, frame, cursor);
            }
            {
                if let Some(SubscriptionEvents::List(receiver)) = events {
                    let sid = sid.clone();
                    let tx = events_tx.clone();
                    // concurrency-allow: this task is owned by the connection's event channel;
                    // dropping the run loop drops its receiver and terminates the task.
                    tokio::spawn(async move {
                        while let Some(item) = receiver.recv().await {
                            let (frame, cursor) = list_item_frame(&sid, item)?;
                            if tx.send((sid.clone(), frame, cursor)).await.is_err() {
                                break;
                            }
                        }
                        Ok::<(), ConnError>(())
                    });
                }
            }
            Ok(())
        }
        Request::Credit(credit) => {
            let _ = state.credit(credit)?;
            Ok(())
        }
        Request::Unsub(unsub) => {
            state.unsubscribe(&unsub.sid);
            Ok(())
        }
        Request::Page(page) => state.offer_reply(source.page(&page)?),
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

fn list_item_frame(sid: &str, item: ListItem) -> Result<(Frame, Cursor), ConnError> {
    let (delta, cursor) = match item {
        ListItem::Summary(event) => (
            Delta::Summary {
                sid: sid.to_owned(),
                seq: event.seq,
                summary: (*event.summary).clone(),
            },
            event.seq,
        ),
        ListItem::Gone { seq, chat_id } => (Delta::Gone { sid: sid.to_owned(), seq, chat_id }, seq),
        ListItem::Dropped { cursor } => {
            let frame = Frame::json(
                FrameKind::Dropped,
                &Dropped { sid: sid.to_owned(), cursor: Cursor(cursor) },
            )?;
            return Ok((frame, Cursor(cursor)));
        }
    };
    Ok((Frame::json(FrameKind::Delta, &delta)?, Cursor(cursor)))
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
        assert_eq!(state.subscription_count(), 2);
        assert_eq!(state.offer("fast", frame(16), Cursor(3)), Offer::Taken);
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
        let (hub, mut writer) = SummaryHub::new(SummaryIndex::new());
        writer.apply(Summary::new("chat")).unwrap();
        let source = HubSource::new(Arc::new(hub));
        let sub = Sub::new("s", "list").from_cursor(Cursor(1));
        let subscription = source.subscribe_stream(&sub).unwrap();
        let delta: Delta<Summary> = subscription.initial.decode_json().unwrap();
        assert!(matches!(delta, Delta::Marker { replay: Some(ReplayMark::End), .. }));
        assert!(subscription.prefix.is_empty());
    }

    #[test]
    fn a_cursor_only_subscriber_reports_zero_retained_bytes() {
        let (hub, _) = SummaryHub::new(SummaryIndex::new());
        assert_eq!(hub.not_fed_bytes(), 0);
    }
}
