//! [`TerminalAttacher`] on `cmux::raw::ByteAttachment` (protocol-12 byte
//! mode on a dedicated connection per view). See [`crate::attach`] for the
//! thread contract.

use crate::attach::{
    AttachEnd, AttachError, AttachRequest, AttachmentItem, CellSize, TerminalAttacher,
    TerminalAttachment, TerminalByteSink,
};
use cmux::TerminalId;
use cmux::raw::{
    AttachInfo, AttachOptions, AttachTarget, ByteAttachment, ByteAttachmentReader,
    ByteAttachmentWriter, ClientConfig, ClientIdentity, Error as RawError,
};
use std::path::PathBuf;
use std::time::Duration;

/// Opens byte attachments to one daemon socket.
#[derive(Clone, Debug)]
pub struct DaemonAttacher {
    config: ClientConfig,
    client: ClientIdentity,
    write_timeout: Option<Duration>,
}

impl DaemonAttacher {
    /// Attaches through `socket`. The handshake deadline is 10 s by default
    /// (the attach reply carries a replay of up to 32 MiB).
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            config: ClientConfig::from_socket_path(socket).with_timeout(Duration::from_secs(10)),
            client: ClientIdentity::default(),
            write_timeout: None,
        }
    }

    /// Deadline for each handshake step (and writes, unless
    /// [`Self::with_write_timeout`] sets another).
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.config = self.config.with_timeout(timeout);
        self
    }

    /// Deadline for each input or geometry write after the handshake.
    pub fn with_write_timeout(mut self, timeout: Duration) -> Self {
        self.write_timeout = Some(timeout);
        self
    }

    /// Identity sent with `set-client-info` on each attachment connection
    /// (name, device kind; kind defaults to `frontend`).
    pub fn with_client(mut self, client: ClientIdentity) -> Self {
        self.client = client;
        self
    }

    pub fn socket(&self) -> &std::path::Path {
        &self.config.socket_path
    }

    /// [`TerminalAttacher::attach`] with the concrete attachment type.
    /// Blocks for the handshake, then starts the reader thread.
    pub fn open(
        &self,
        request: AttachRequest,
        sink: Box<dyn TerminalByteSink>,
    ) -> Result<DaemonAttachment, AttachError> {
        let target =
            AttachTarget::Terminal { id: request.terminal.clone(), generation: request.generation };
        let options = AttachOptions {
            client: self.client.clone(),
            claim_geometry: request.claim_geometry,
            write_timeout: self.write_timeout,
        };
        let ByteAttachment { writer, reader, info } =
            ByteAttachment::open(&self.config, target, request.size, options)
                .map_err(open_error)?;
        std::thread::Builder::new()
            .name(format!("cmux-attach-{}", info.surface))
            .spawn(move || pump(reader, sink))
            .map_err(|e| {
                let _ = writer.detach();
                AttachError::Failed(format!("cannot start the attachment reader: {e}"))
            })?;
        Ok(DaemonAttachment { terminal: request.terminal, writer, info })
    }
}

impl TerminalAttacher for DaemonAttacher {
    fn attach(
        &self,
        request: AttachRequest,
        sink: Box<dyn TerminalByteSink>,
    ) -> Result<Box<dyn TerminalAttachment>, AttachError> {
        Ok(Box::new(self.open(request, sink)?))
    }
}

/// One attached view. Dropping it detaches (best effort, never blocks on the
/// reader thread).
pub struct DaemonAttachment {
    terminal: TerminalId,
    writer: ByteAttachmentWriter,
    info: AttachInfo,
}

impl DaemonAttachment {
    /// What the daemon reported while attaching (numeric surface, lease,
    /// shared-sizing participant, generation).
    pub fn info(&self) -> &AttachInfo {
        &self.info
    }
}

impl Drop for DaemonAttachment {
    fn drop(&mut self) {
        // Explicit, so a writer clone kept elsewhere cannot delay it.
        let _ = self.writer.detach();
    }
}

impl TerminalAttachment for DaemonAttachment {
    fn terminal(&self) -> &TerminalId {
        &self.terminal
    }

    fn write(&self, data: &[u8]) -> Result<(), AttachError> {
        self.writer.send_bytes(data).map_err(write_error)
    }

    fn resize(&self, size: CellSize) -> Result<(), AttachError> {
        self.writer.resize(size).map_err(write_error)
    }

    fn claim_geometry(&self, size: Option<CellSize>) -> Result<(), AttachError> {
        self.writer.claim_geometry(size).map_err(write_error)
    }

    fn release_geometry(&self) -> Result<(), AttachError> {
        self.writer.release_geometry().map_err(write_error)
    }

    fn detach(&self) {
        let _ = self.writer.detach();
    }
}

/// The reader thread: forwards every item to the sink until the end.
fn pump(mut reader: ByteAttachmentReader, mut sink: Box<dyn TerminalByteSink>) {
    let end = loop {
        match reader.recv() {
            Ok(AttachmentItem::VtState(replay)) => sink.replay(&replay),
            Ok(AttachmentItem::Resized(replay)) => sink.resized(&replay),
            Ok(AttachmentItem::Output { data, colors }) => {
                if let Some(colors) = colors {
                    sink.item(&AttachmentItem::ColorsChanged(colors));
                }
                sink.bytes(&data);
            }
            Ok(AttachmentItem::Ended(reason)) => break AttachEnd::from_end(reason),
            Ok(item) => sink.item(&item),
            // One malformed event; the stream continues.
            Err(RawError::Decode(message)) => log::warn!("cmux attach: bad event: {message}"),
            Err(error) => break AttachEnd::Failed(error.to_string()),
        }
    };
    sink.ended(end);
}

fn open_error(error: RawError) -> AttachError {
    match error {
        RawError::Command { message, .. } => AttachError::Rejected(message),
        RawError::Protocol { message, .. } => AttachError::Rejected(message),
        RawError::Closed => AttachError::Closed,
        other => AttachError::Failed(other.to_string()),
    }
}

fn write_error(error: RawError) -> AttachError {
    match error {
        RawError::Closed => AttachError::Closed,
        other => AttachError::Failed(other.to_string()),
    }
}
