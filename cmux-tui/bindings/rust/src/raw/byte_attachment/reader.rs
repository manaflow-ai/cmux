//! The read half of a byte attachment: decodes the attach stream and the
//! replies to writer commands. See the module docs for the thread contract.

use super::{AttachmentItem, EndReason, Replay, Shared};
use crate::client::{CmuxError, Result, StreamCloser};
use crate::codec::JsonLineConnection;
use crate::generated::{
    Id, KittyGraphicsState, KittyImageAlias, SizeDetachActor, SizeState, TerminalColors,
};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

/// Receives attach items. `Send`, not `Sync`: one thread owns it.
pub struct ByteAttachmentReader {
    connection: JsonLineConnection,
    queued: VecDeque<Value>,
    shared: Arc<Shared>,
    finished: bool,
}

impl ByteAttachmentReader {
    pub(super) fn new(
        connection: JsonLineConnection,
        queued: VecDeque<Value>,
        shared: Arc<Shared>,
    ) -> Self {
        Self { connection, queued, shared, finished: false }
    }

    /// Blocks until the next item. There is no deadline, because an idle
    /// terminal is normal. A malformed event returns `Err(Decode)` and the
    /// stream continues; after `Ended` every call returns `Err(Closed)`.
    pub fn recv(&mut self) -> Result<AttachmentItem> {
        self.next_item(None)
    }

    /// Like [`Self::recv`], but returns `Err(Timeout)` when no item arrives
    /// within `timeout`. A partially received frame is kept for the next call.
    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<AttachmentItem> {
        self.next_item(Some(Instant::now() + timeout))
    }

    /// A handle that ends the stream from another thread and unblocks `recv`,
    /// which then returns `Ended(ClosedByClient)`.
    pub fn closer(&self) -> StreamCloser {
        StreamCloser { control: Arc::clone(&self.shared.control) }
    }

    fn next_item(&mut self, deadline: Option<Instant>) -> Result<AttachmentItem> {
        if self.finished {
            return Err(CmuxError::Closed);
        }
        loop {
            let value = match self.queued.pop_front() {
                Some(value) => value,
                None => match self.read(deadline) {
                    Ok(value) => value,
                    Err(CmuxError::Timeout(message)) if !self.shared.closed_by_client() => {
                        return Err(CmuxError::Timeout(message));
                    }
                    Err(CmuxError::Decode(message)) if !self.shared.is_closed() => {
                        return Err(CmuxError::Decode(message));
                    }
                    Err(error) => {
                        let reason = self.lost_reason(&error);
                        return Ok(self.end(reason));
                    }
                },
            };
            if let Some(item) = self.decode(value)? {
                return Ok(item);
            }
        }
    }

    fn read(&mut self, deadline: Option<Instant>) -> Result<Value> {
        match deadline {
            None => self.connection.without_read_timeout(JsonLineConnection::recv),
            Some(deadline) => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err(CmuxError::Timeout("no attachment item before deadline".into()));
                }
                self.connection.with_read_timeout(left, JsonLineConnection::recv)
            }
        }
    }

    fn lost_reason(&self, error: &CmuxError) -> EndReason {
        if self.shared.closed_by_client() {
            EndReason::ClosedByClient
        } else {
            EndReason::ConnectionLost(self.shared.poison().unwrap_or_else(|| error.to_string()))
        }
    }

    /// Ends the stream once: marks it for the writer and closes the socket.
    fn end(&mut self, reason: EndReason) -> AttachmentItem {
        let reason =
            if self.shared.closed_by_client() { EndReason::ClosedByClient } else { reason };
        self.finished = true;
        self.shared.ended.store(true, Ordering::Release);
        self.shared.shutdown();
        self.connection.close();
        super::lock(&self.shared.pending).clear();
        AttachmentItem::Ended(reason)
    }

    fn decode(&mut self, value: Value) -> Result<Option<AttachmentItem>> {
        let Some(event) = value.get("event").and_then(Value::as_str).map(str::to_string) else {
            return Ok(self.reply(&value));
        };
        let surface = value.get("surface").and_then(Value::as_u64);
        if surface.is_some_and(|surface| surface != self.shared.surface) {
            return Ok(None);
        }
        let decoded = match event.as_str() {
            "vt-state" => AttachmentItem::VtState(replay(&event, value)?),
            "resized" => AttachmentItem::Resized(replay(&event, value)?),
            "output" => {
                let output: OutputWire = parse(&event, value)?;
                AttachmentItem::Output { data: bytes(&event, &output.data)?, colors: output.colors }
            }
            "colors-changed" => AttachmentItem::ColorsChanged(parse(&event, value)?),
            "scroll-changed" => {
                let scroll: ScrollWire = parse(&event, value)?;
                AttachmentItem::ScrollChanged { offset: scroll.offset, at_bottom: scroll.at_bottom }
            }
            "size-state" => {
                let state: SizeStateWire = parse(&event, value)?;
                AttachmentItem::SizeState(state.state)
            }
            "detached" => return self.detached(value).map(Some),
            "overflow" => self.end(EndReason::Overflow),
            _ => AttachmentItem::Other { event, raw: value },
        };
        Ok(Some(decoded))
    }

    fn detached(&mut self, value: Value) -> Result<AttachmentItem> {
        if value.get("view").is_some() {
            // A relay sub-view notice; this attachment creates no sub-views.
            return Ok(AttachmentItem::Other { event: "detached".into(), raw: value });
        }
        let scoped_to_view = value.get("scope").and_then(Value::as_str) == Some("view");
        let detached: DetachedWire = parse("detached", value)?;
        let reason = detached.reason.and_then(|reason| serde_json::from_value(reason).ok());
        if scoped_to_view {
            return Ok(AttachmentItem::ViewDetached { actor: detached.by });
        }
        Ok(self.end(EndReason::Detached { reason, actor: detached.by }))
    }

    /// Maps a reply to a writer command; only rejections become items.
    fn reply(&self, value: &Value) -> Option<AttachmentItem> {
        let id = value.get("id").and_then(Value::as_u64)?;
        let command = self.shared.take_pending(id);
        if value.get("ok") == Some(&Value::Bool(true)) {
            return None;
        }
        let message = value.get("error").and_then(Value::as_str).unwrap_or("unknown command error");
        Some(AttachmentItem::CommandRejected {
            command: command.unwrap_or("<unknown>"),
            message: message.to_string(),
        })
    }
}

impl Iterator for ByteAttachmentReader {
    type Item = Result<AttachmentItem>;

    /// Yields items until `Ended`, then stops.
    fn next(&mut self) -> Option<Self::Item> {
        (!self.finished).then(|| self.recv())
    }
}

impl Drop for ByteAttachmentReader {
    fn drop(&mut self) {
        self.connection.close();
    }
}

#[derive(Deserialize)]
struct ReplayWire {
    surface: Id,
    cols: u16,
    rows: u16,
    #[serde(default)]
    data: Option<String>,
    #[serde(default)]
    replay: Option<String>,
    #[serde(default)]
    pending: Option<String>,
    #[serde(default)]
    colors: Option<TerminalColors>,
    #[serde(default)]
    kitty_image_aliases: Option<Vec<KittyImageAlias>>,
    #[serde(default)]
    kitty_graphics_state: Option<KittyGraphicsState>,
}

#[derive(Deserialize)]
struct OutputWire {
    data: String,
    #[serde(default)]
    colors: Option<TerminalColors>,
}

#[derive(Deserialize)]
struct ScrollWire {
    offset: u64,
    at_bottom: bool,
}

#[derive(Deserialize)]
struct SizeStateWire {
    state: SizeState,
}

#[derive(Deserialize)]
struct DetachedWire {
    #[serde(default)]
    reason: Option<Value>,
    #[serde(default)]
    by: Option<SizeDetachActor>,
}

fn parse<T: for<'de> Deserialize<'de>>(event: &str, value: Value) -> Result<T> {
    serde_json::from_value(value).map_err(|error| CmuxError::Decode(format!("{event}: {error}")))
}

fn bytes(event: &str, encoded: &str) -> Result<Vec<u8>> {
    STANDARD.decode(encoded).map_err(|error| CmuxError::Decode(format!("{event}: {error}")))
}

/// Decodes `vt-state` and `resized`. A `resized` replay is in `replay`, or in
/// `data` from protocol-6 servers.
fn replay(event: &str, value: Value) -> Result<Replay> {
    let wire: ReplayWire = parse(event, value)?;
    let data = wire.replay.as_deref().or(wire.data.as_deref()).unwrap_or_default();
    Ok(Replay {
        surface: wire.surface,
        cols: wire.cols,
        rows: wire.rows,
        data: bytes(event, data)?,
        pending: bytes(event, wire.pending.as_deref().unwrap_or_default())?,
        colors: wire.colors,
        kitty_image_aliases: wire.kitty_image_aliases.unwrap_or_default(),
        kitty_graphics_state: wire.kitty_graphics_state,
    })
}
