//! The write half of a byte attachment. See the module docs for the thread
//! contract.

use super::{CellSize, Outbound, Shared, lock};
use crate::client::{CmuxError, Result};
use crate::generated::Id;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};
use std::io::{ErrorKind, Write};
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// Raw input bytes per `send` frame. Base64 keeps a frame near 1.4 MiB, well
/// under the daemon's 16 MiB inbound line limit.
const SEND_CHUNK_BYTES: usize = 1024 * 1024;
/// The daemon's inbound line limit (`transports.md`).
const INBOUND_FRAME_LIMIT: usize = 16 * 1024 * 1024;

/// Sends input and view-geometry commands on the attachment connection.
/// `Clone + Send + Sync`; dropping the last clone detaches the view.
#[derive(Clone)]
pub struct ByteAttachmentWriter {
    handle: Arc<Handle>,
}

/// Owned by every clone; its drop is the last clone's drop.
struct Handle {
    shared: Arc<Shared>,
}

impl Drop for Handle {
    fn drop(&mut self) {
        let _ = detach(&self.shared);
    }
}

impl ByteAttachmentWriter {
    pub(super) fn new(shared: Arc<Shared>) -> Self {
        Self { handle: Arc::new(Handle { shared }) }
    }

    fn shared(&self) -> &Shared {
        &self.handle.shared
    }

    /// The attached numeric surface.
    pub fn surface(&self) -> Id {
        self.shared().surface
    }

    /// The opaque view lease of this attach stream.
    pub fn lease(&self) -> &str {
        &self.shared().lease
    }

    /// Writes input bytes to the PTY with `send {surface, bytes}`. Input
    /// larger than 1 MiB goes out as consecutive frames with no other request
    /// between them. Empty input sends nothing.
    pub fn send_bytes(&self, bytes: &[u8]) -> Result<()> {
        let mut outbound = self.outbound()?;
        for chunk in bytes.chunks(SEND_CHUNK_BYTES) {
            self.write(&mut outbound, "send", |fields| {
                fields.insert("bytes".into(), json!(STANDARD.encode(chunk)));
            })?;
        }
        Ok(())
    }

    /// Reports this view's grid with `resize-attached-view`. Skipped when it
    /// equals the last report (the attach size counts as the first report).
    /// Never call it because another client resized the terminal.
    pub fn resize(&self, size: CellSize) -> Result<()> {
        let size = size.clamped();
        let mut outbound = self.outbound()?;
        if outbound.last_reported == Some(size) {
            return Ok(());
        }
        self.report(&mut outbound, size)
    }

    /// Makes this view the geometry owner. Reports `report` (or the last
    /// report) first, because the daemon accepts a claim only from a view
    /// that has reported a size, then sends `set-client-sizing`.
    pub fn claim_geometry(&self, report: Option<CellSize>) -> Result<()> {
        let mut outbound = self.outbound()?;
        if let Some(size) = report.map(CellSize::clamped).or(outbound.last_reported) {
            self.report(&mut outbound, size)?;
        }
        self.write(&mut outbound, "set-client-sizing", |fields| {
            fields.insert("enabled".into(), json!(true));
            fields.insert("exclusive".into(), json!(true));
        })
    }

    /// Keeps the stream for cached rendering but withdraws this view's size
    /// (`release-attached-view-size`). Call it when the view is hidden.
    pub fn release_geometry(&self) -> Result<()> {
        let mut outbound = self.outbound()?;
        outbound.last_reported = None;
        let lease = self.lease().to_string();
        self.write(&mut outbound, "release-attached-view-size", |fields| {
            fields.insert("lease".into(), json!(lease));
        })
    }

    /// Sends `detach-attached-view` and closes the connection. The terminal
    /// keeps running. Idempotent; the reader then ends with
    /// [`EndReason::ClosedByClient`](super::EndReason::ClosedByClient).
    pub fn detach(&self) -> Result<()> {
        detach(self.shared())
    }

    fn outbound(&self) -> Result<std::sync::MutexGuard<'_, Outbound>> {
        if self.shared().is_closed() {
            return Err(CmuxError::Closed);
        }
        let outbound = lock(&self.shared().outbound);
        if self.shared().is_closed() {
            return Err(CmuxError::Closed);
        }
        Ok(outbound)
    }

    fn report(&self, outbound: &mut Outbound, size: CellSize) -> Result<()> {
        let lease = self.lease().to_string();
        self.write(outbound, "resize-attached-view", |fields| {
            fields.insert("lease".into(), json!(lease));
            fields.insert("cols".into(), json!(size.cols));
            fields.insert("rows".into(), json!(size.rows));
        })?;
        outbound.last_reported = Some(size);
        Ok(())
    }

    fn write(
        &self,
        outbound: &mut Outbound,
        command: &'static str,
        fill: impl FnOnce(&mut Map<String, Value>),
    ) -> Result<()> {
        write_frame(self.shared(), outbound, command, fill)
    }
}

/// Writes one request frame. A failed write poisons the connection, because
/// the daemon may have received a partial line.
fn write_frame(
    shared: &Shared,
    outbound: &mut Outbound,
    command: &'static str,
    fill: impl FnOnce(&mut Map<String, Value>),
) -> Result<()> {
    let id = outbound.next_id;
    outbound.next_id = outbound.next_id.wrapping_add(1).max(super::FIRST_WRITER_ID);
    let mut fields = Map::new();
    fields.insert("id".into(), json!(id));
    fields.insert("cmd".into(), json!(command));
    fields.insert("surface".into(), json!(shared.surface));
    fill(&mut fields);
    let mut encoded = serde_json::to_vec(&Value::Object(fields))
        .map_err(|error| CmuxError::Decode(error.to_string()))?;
    if encoded.len() >= INBOUND_FRAME_LIMIT {
        return Err(CmuxError::FrameTooLarge { size: encoded.len(), limit: INBOUND_FRAME_LIMIT });
    }
    encoded.push(b'\n');
    shared.track(id, command);
    if let Err(error) = outbound.socket.write_all(&encoded) {
        shared.take_pending(id);
        let message = format!("{command} write failed: {error}");
        shared.set_poison(message.clone());
        return Err(match error.kind() {
            ErrorKind::WouldBlock | ErrorKind::TimedOut => CmuxError::Timeout(message),
            _ => CmuxError::Connection(message),
        });
    }
    Ok(())
}

fn detach(shared: &Shared) -> Result<()> {
    if shared.detached.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    let ended = shared.ended.load(Ordering::Acquire)
        || shared.control.closed.load(Ordering::Acquire)
        || shared.poison().is_some();
    let result = if ended {
        Ok(())
    } else {
        let mut outbound = lock(&shared.outbound);
        let lease = shared.lease.clone();
        write_frame(shared, &mut outbound, "detach-attached-view", |fields| {
            fields.insert("lease".into(), json!(lease));
        })
    };
    shared.shutdown();
    result
}
