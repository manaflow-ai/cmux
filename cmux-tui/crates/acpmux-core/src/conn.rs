//! One bounded v2 connection over any ordered byte stream.

use crate::hub::HubError;
mod list;
use crate::wire::{Cursor, Frame, FrameError, FrameKind, Hello, HelloReply, Limits, Page, Sub};
pub use list::HubSource;
use std::collections::VecDeque;
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};

pub const MAX_SUBSCRIPTIONS: usize = crate::wire::MAX_SUBSCRIPTIONS;
pub use crate::wire::Request;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Offer {
    Taken,
    NotFed,
    Dropped { sid: String, cursor: Cursor },
    UnknownSubscription,
}

mod state;
pub use state::{ConnectionMetrics, ConnectionState, FrameLease, SubscriptionControl};

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
    #[error("sid or id is longer than 256 UTF-8 bytes")]
    IdentifierTooLong,
    #[error("identity proof is larger than 64 bytes")]
    IdentityTooLarge,
}

/// The source's non-blocking sink. A source must treat `NotFed` as a cursor
/// boundary: it stops reading and calls `resume` after the connection signals
/// credit. No source task is allowed to await this method.
pub trait OfferSink: Send + Sync {
    fn offer(&self, sid: &str, frame: Frame, cursor: Cursor) -> Offer;
    fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>>;
    fn metrics(&self) -> Arc<ConnectionMetrics>;
}

/// A source owns its delivery tasks and the order of its frames. `subscribe`
/// queues its first frame through the handle before returning. `NotFed` consumes
/// the offered frame: the source retains only its last taken cursor until resume.
pub type CloseFuture<'a> = std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>>;

pub trait Source: Send + Sync + 'static {
    fn subscribe(
        &self,
        sub: &Sub,
        person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError>;
    fn resume(&self, sid: &str, cursor: Cursor);
    fn page(&self, _page: &Page, _person: Option<&[u8]>) -> Result<Frame, ConnError> {
        Err(ConnError::InvalidRequest("page is not supported for this stream".into()))
    }
    fn end(&self, sid: &str);
    /// Join tasks released by end, including on a read or write error.
    fn close(&self) -> CloseFuture<'_> {
        Box::pin(std::future::ready(()))
    }
}

pub struct MissingChatSource;

impl Source for MissingChatSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _identity: Option<&[u8]>,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        if sub.stream.as_str().starts_with("chat:") {
            Err(ConnError::InvalidRequest("no such stream".into()))
        } else {
            Err(ConnError::InvalidRequest("unsupported stream".into()))
        }
    }
    fn resume(&self, _sid: &str, _cursor: Cursor) {}
    fn end(&self, _sid: &str) {}
}

#[derive(Clone)]
struct ConnectionSink {
    state: Arc<std::sync::Mutex<ConnectionState>>,
    control: Arc<SubscriptionControl>,
}
impl OfferSink for ConnectionSink {
    fn metrics(&self) -> Arc<ConnectionMetrics> {
        self.state
            .lock()
            .map_or_else(|_| Arc::new(ConnectionMetrics::default()), |state| state.metrics.clone())
    }
    fn offer(&self, sid: &str, frame: Frame, cursor: Cursor) -> Offer {
        self.state.lock().map_or(Offer::UnknownSubscription, |mut state| {
            state.offer_from(sid, &self.control, frame, cursor)
        })
    }
    fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>> {
        self.state.lock().ok()?.control(sid).filter(|c| Arc::ptr_eq(c, &self.control))
    }
}
struct Cleanup {
    state: Arc<std::sync::Mutex<ConnectionState>>,
    source: Arc<dyn Source>,
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        let sids = if let Ok(mut state) = self.state.lock() {
            let mut sids: Vec<_> = state.subscriptions.keys().cloned().collect();
            sids.extend(state.take_ended());
            for sid in &sids {
                state.unsubscribe(sid);
            }
            sids
        } else {
            Vec::new()
        };
        for sid in sids {
            self.source.end(&sid);
        }
    }
}

/// The only stream writer. Reads, source wakes and cancellation-safe partial
/// writes share one select. No subscription task lives in the connection.
pub async fn run<R, W>(
    reader: R,
    writer: W,
    source: Arc<dyn Source>,
    daemon_id: impl Into<String>,
    surfaces: &[String],
) -> Result<(), ConnError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let state = Arc::new(std::sync::Mutex::new(ConnectionState::default()));
    let cleanup = Cleanup { state: state.clone(), source: source.clone() };
    let result =
        run_connection(reader, writer, source.clone(), daemon_id.into(), surfaces, state).await;
    drop(cleanup);
    source.close().await;
    result
}

async fn run_connection<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    mut reader: R,
    mut writer: W,
    source: Arc<dyn Source>,
    daemon_id: String,
    surfaces: &[String],
    state: Arc<std::sync::Mutex<ConnectionState>>,
) -> Result<(), ConnError> {
    let wake = state.lock().map_err(|_| poisoned())?.wake.clone();
    let hello = Frame::json(
        FrameKind::Hello,
        &HelloReply { daemon_id: daemon_id.into(), limits: Limits::default() },
    )?;
    state.lock().map_err(|_| poisoned())?.offer_reply(hello)?;
    let mut decoder = crate::wire::FrameDecoder::default();
    let mut buffer = [0_u8; 16 * 1024];
    let mut pending = VecDeque::<Frame>::new();
    let mut writing: Option<WritingFrame> = None;
    let mut hello_seen = false;
    loop {
        let ended = state.lock().map_err(|_| poisoned())?.take_ended();
        for sid in ended {
            source.end(&sid);
        }
        if writing.is_none() {
            writing = state.lock().map_err(|_| poisoned())?.take().map(WritingFrame::new);
        }
        let can_process = if let Some(frame) = pending.front() {
            let state = state.lock().map_err(|_| poisoned())?;
            state.request_room() || (hello_seen && known_control(frame, &state))
        } else {
            false
        };
        tokio::select! {
            // The default select is fair: a perpetually ready writer cannot
            // starve credit, and a request burst cannot starve a partial write.
            result = write_lease(&mut writer, writing.as_mut()), if writing.is_some() => {
                if result? && let Some(written) = writing.take() {
                    let mut state = state.lock().map_err(|_| poisoned())?;
                    if written.cancelled { state.abandon(&written.lease); }
                    else { state.written(&written.lease); }
                }
            }
            _ = wake.notified() => {}
            _ = std::future::ready(()), if can_process => {
                let Some(frame) = pending.pop_front() else { continue };
                let control = {
                    let mut state = state.lock().map_err(|_| poisoned())?;
                    if hello_seen && known_control(&frame, &state) {
                        // Validate and apply under the SAME lock. A source drop
                        // cannot turn this reply-free control into an error
                        // after we chose to process it without a reply reserve.
                        match frame.decode_json::<Request>()? {
                            Request::Credit(credit) => {
                                let sid = credit.sid.clone();
                                Some(Control::Credit(sid, state.credit(credit)?))
                            }
                            Request::Unsub(unsub) => {
                                state.unsubscribe(&unsub.sid);
                                Some(Control::End(unsub.sid))
                            }
                            _ => return Err(poisoned()),
                        }
                    } else if state.reserve_reply() { None }
                    else { pending.push_front(frame); continue; }
                };
                if let Some(control) = control {
                    match control {
                        Control::Credit(sid, Some(cursor)) => source.resume(&sid, cursor),
                        Control::Credit(_, None) => {},
                        Control::End(sid) => source.end(&sid),
                    }
                    continue;
                }
                let result = process_frame(&state, source.clone(), &frame, &mut hello_seen, surfaces);
                if let Err(error) = result {
                    let reply = error_frame(&frame, &error)?;
                    state.lock().map_err(|_| poisoned())?.offer_reply(reply)?;
                }
                state.lock().map_err(|_| poisoned())?.release_reply();
            }
            read = reader.read(&mut buffer), if pending.is_empty() => {
                let read = read?;
                if read == 0 { return Ok(()); }
                // An invalid length loses framing: close, release the decoder,
                // and run Cleanup. Unknown kinds are valid frames, handled below.
                pending.extend(decoder.push(buffer.get(..read).ok_or_else(poisoned)?)?);
            }
        }
    }
}
fn poisoned() -> ConnError {
    ConnError::InvalidRequest("connection state poisoned".into())
}
enum Control {
    Credit(String, Option<Cursor>),
    End(String),
}

fn known_control(frame: &Frame, state: &ConnectionState) -> bool {
    if frame.kind != FrameKind::Request {
        return false;
    }
    if !frame
        .decode_json::<serde_json::Value>()
        .is_ok_and(|value| validate_identifiers(&value).is_ok())
    {
        return false;
    }
    match frame.decode_json::<Request>() {
        Ok(Request::Credit(credit)) => state.subscriptions.contains_key(&credit.sid),
        Ok(Request::Unsub(unsub)) => state.subscriptions.contains_key(&unsub.sid),
        _ => false,
    }
}
fn process_frame(
    state: &Arc<std::sync::Mutex<ConnectionState>>,
    source: Arc<dyn Source>,
    frame: &Frame,
    hello_seen: &mut bool,
    surfaces: &[String],
) -> Result<(), ConnError> {
    if frame.kind != FrameKind::Request {
        return Err(ConnError::InvalidRequest("unknown request kind".into()));
    }
    let value: serde_json::Value = frame.decode_json()?;
    validate_identifiers(&value)?;
    let request: Request = frame.decode_json()?;
    if !*hello_seen && !matches!(request, Request::Hello(_)) {
        return Err(ConnError::InvalidRequest("hello must be first".into()));
    }
    match request {
        Request::Hello(hello) => {
            validate_hello(&hello)?;
            if *hello_seen {
                return Err(ConnError::InvalidRequest("hello was already received".into()));
            }
            state.lock().map_err(|_| poisoned())?.set_identity(hello.identity.as_deref())?;
            *hello_seen = true;
        }
        Request::Sub(sub) => {
            require_surface(&sub.stream, surfaces)?;
            let (identity, control, ended) = {
                let mut state = state.lock().map_err(|_| poisoned())?;
                state.subscribe_at(sub.sid.clone(), sub.cursor)?;
                (
                    state.identity().map(ToOwned::to_owned),
                    state.control(&sub.sid).ok_or_else(poisoned)?,
                    state.take_ended(),
                )
            };
            for sid in ended {
                source.end(&sid);
            }
            let sink = Arc::new(ConnectionSink { state: state.clone(), control });
            if let Err(error) = source.subscribe(&sub, identity.as_deref(), sink) {
                source.end(&sub.sid);
                state.lock().map_err(|_| poisoned())?.unsubscribe(&sub.sid);
                return Err(error);
            }
        }
        Request::Credit(credit) => {
            let sid = credit.sid.clone();
            let cursor = state.lock().map_err(|_| poisoned())?.credit(credit)?;
            if let Some(cursor) = cursor {
                source.resume(&sid, cursor);
            }
        }
        Request::Unsub(unsub) => {
            if !state.lock().map_err(|_| poisoned())?.unsubscribe(&unsub.sid) {
                return Err(ConnError::UnknownSubscription(unsub.sid));
            }
            source.end(&unsub.sid);
        }
        Request::Page(page) => {
            require_surface(&page.stream, surfaces)?;
            let identity = state.lock().map_err(|_| poisoned())?.identity().map(ToOwned::to_owned);
            let frame = source.page(&page, identity.as_deref())?;
            state.lock().map_err(|_| poisoned())?.offer_reply(frame)?;
        }
    }
    Ok(())
}

fn validate_identifiers(value: &serde_json::Value) -> Result<(), ConnError> {
    for id in [value.pointer("/params/sid"), value.pointer("/params/id"), value.get("id")]
        .into_iter()
        .flatten()
    {
        if id.as_str().is_some_and(|s| !crate::wire::identifier_fits(s)) {
            return Err(ConnError::IdentifierTooLong);
        }
    }
    Ok(())
}

fn error_frame(request: &Frame, error: &ConnError) -> Result<Frame, ConnError> {
    let value = request.decode_json::<serde_json::Value>().unwrap_or_default();
    let method = value
        .get("method")
        .and_then(serde_json::Value::as_str)
        .map(|s| s.chars().take(256).collect::<String>())
        .unwrap_or_else(|| format!("kind:{:?}", request.kind));
    let code = match error {
        ConnError::IdentifierTooLong => "identifier_too_long",
        ConnError::UnknownSubscription(_) => "unknown_sid",
        ConnError::DuplicateSubscription(_) => "duplicate_sid",
        ConnError::TooManySubscriptions => "subscription_limit",
        ConnError::Frame(_) => "invalid_request",
        _ => "request_failed",
    };
    let mut fields = serde_json::Map::new();
    fields.insert("method".into(), method.into());
    fields.insert("code".into(), code.into());
    fields.insert("message".into(), error.to_string().chars().take(512).collect::<String>().into());
    // An oversized identifier is never echoed or truncated. Both keys are omitted.
    if validate_identifiers(&value).is_ok() {
        if let Some(sid) = value.pointer("/params/sid").filter(|s| s.is_string()) {
            fields.insert("sid".into(), sid.clone());
        }
        if let Some(id) = value
            .pointer("/params/id")
            .or_else(|| value.get("id"))
            .filter(|id| id.is_number() || id.is_string())
        {
            fields.insert("id".into(), id.clone());
        }
    }
    Ok(Frame::json(FrameKind::Error, &fields)?)
}

fn require_surface(stream: &crate::wire::Stream, surfaces: &[String]) -> Result<(), ConnError> {
    let surface = if stream.as_str().starts_with("chat:") { "chat" } else { stream.as_str() };
    if surfaces.iter().any(|enabled| enabled == surface) {
        Ok(())
    } else {
        Err(ConnError::InvalidRequest("surface was not negotiated".into()))
    }
}

struct WritingFrame {
    lease: FrameLease,
    offset: usize,
    cancelled: bool,
}

impl WritingFrame {
    fn new(lease: FrameLease) -> Self {
        Self { lease, offset: 0, cancelled: false }
    }
}

// `write` is cancellation safe; `write_all` is not. Progress lives outside the
// select future so an inbound request cannot cause a frame prefix to be written twice.
async fn write_lease<W: AsyncWrite + Unpin>(
    writer: &mut W,
    writing: Option<&mut WritingFrame>,
) -> Result<bool, std::io::Error> {
    let Some(writing) = writing else { return std::future::pending().await };
    let control = writing.lease.control.clone();
    let count = std::future::poll_fn(|cx| {
        let _start = if writing.offset == 0 {
            control.as_ref().map(|control| {
                control.write_start.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
            })
        } else {
            None
        };
        if writing.offset == 0 && writing.lease.ended() {
            writing.cancelled = true;
            return std::task::Poll::Ready(Ok(0));
        }
        let Some(remaining) = writing.lease.bytes.get(writing.offset..) else {
            return std::task::Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "invalid write offset",
            )));
        };
        // poll_write cannot retain a lock across Pending. A drop that follows
        // this poll either frees an unstarted frame or lets its prefix finish.
        std::pin::Pin::new(&mut *writer).poll_write(cx, remaining)
    })
    .await?;
    if writing.cancelled {
        return Ok(true);
    }
    if count == 0 {
        return Err(std::io::Error::new(std::io::ErrorKind::WriteZero, "frame write stopped"));
    }
    writing.offset += count;
    Ok(writing.offset == writing.lease.bytes.len())
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

#[cfg(test)]
mod tests;
