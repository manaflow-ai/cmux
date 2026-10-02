//! Seam for terminal byte attachment (stage 2; not implemented yet).
//!
//! Terminal bytes will come from protocol-12 `attach-surface` with
//! `mode: bytes` and go back through protocol-12 `send` on the same
//! connection, as the Swift app does. The cmux SDK's
//! `raw::attach_surface` has only the read half today (no send, resize,
//! release, detach, or `set-client-info` on the attachment connection); a
//! `raw::ByteAttachment` was requested upstream. Until it lands this crate
//! only defines the shape a frontend codes against, so the GPUI app and the
//! Chromium host can wire terminals without depending on how the bytes move.
//!
//! Threading follows the crate contract: an implementation owns its reader
//! thread and calls the [`TerminalByteSink`] on it, in order; sinks post to
//! their UI thread and return quickly.

use cmux::TerminalId;

/// Why an attachment ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttachEnd {
    /// `release` was called.
    Released,
    /// The terminal exited or was closed in the daemon.
    TerminalGone,
    /// Another viewer took the lease, or the daemon restarted.
    Replaced,
    /// Transport or protocol failure.
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttachError {
    /// No implementation is available yet (stage 1).
    Unsupported,
    Failed(String),
}

impl std::fmt::Display for AttachError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => write!(f, "terminal byte attachment is not implemented yet"),
            Self::Failed(e) => write!(f, "terminal attachment failed: {e}"),
        }
    }
}

impl std::error::Error for AttachError {}

/// Receives one terminal's output. Called on the attachment's own thread.
pub trait TerminalByteSink: Send {
    /// PTY output, in order. The first call after attach is the replay of
    /// the terminal's current screen state.
    fn bytes(&mut self, data: &[u8]);
    fn ended(&mut self, reason: AttachEnd);
}

/// A live attachment. Dropping it releases the viewer lease.
pub trait TerminalAttachment: Send {
    fn terminal(&self) -> &TerminalId;
    /// Keyboard/paste input (protocol-12 `send` on the attachment connection).
    fn write(&mut self, data: &[u8]) -> Result<(), AttachError>;
    /// Viewer size in cells.
    fn resize(&mut self, cols: u16, rows: u16) -> Result<(), AttachError>;
}

/// Opens attachments. One per daemon connection.
pub trait TerminalAttacher: Send + Sync {
    fn attach(
        &self,
        terminal: &TerminalId,
        cols: u16,
        rows: u16,
        sink: Box<dyn TerminalByteSink>,
    ) -> Result<Box<dyn TerminalAttachment>, AttachError>;
}

/// Stage-1 placeholder: every attach is `Unsupported`.
#[derive(Clone, Copy, Debug, Default)]
pub struct UnsupportedAttacher;

impl TerminalAttacher for UnsupportedAttacher {
    fn attach(
        &self,
        _terminal: &TerminalId,
        _cols: u16,
        _rows: u16,
        _sink: Box<dyn TerminalByteSink>,
    ) -> Result<Box<dyn TerminalAttachment>, AttachError> {
        Err(AttachError::Unsupported)
    }
}
