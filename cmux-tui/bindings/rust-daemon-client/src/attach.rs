//! Terminal byte attachment: the seam a frontend codes against.
//!
//! Terminal bytes come from protocol-12 `attach-surface` with `mode: bytes`
//! and input goes back through protocol-12 `send` on the same connection, as
//! the cmux-next Swift app does. [`crate::DaemonAttacher`] implements the
//! seam on `cmux::raw::ByteAttachment`; [`UnsupportedAttacher`] refuses every
//! attach (a frontend without a daemon).
//!
//! # Thread contract
//!
//! - [`TerminalAttacher::attach`] blocks the calling thread for the
//!   handshake (bounded by the attacher's timeout; the replay can be large),
//!   so call it off the UI thread.
//! - Each attachment owns one reader thread. It calls the
//!   [`TerminalByteSink`] on that thread, sequentially, in wire order, and
//!   exits after [`TerminalByteSink::ended`], which is always the last call.
//!   A sink may block to apply backpressure (the daemon then queues, and a
//!   view that falls 8 MiB behind ends with an overflow that asks for a
//!   reattach), but it must not wait on a thread that waits on the
//!   attachment, and it must never block forever.
//! - [`TerminalAttachment`] is `Send + Sync`: input from a terminal IO thread
//!   and resizes from the UI thread can share it (`Arc`). Every call is a
//!   fire-and-forget write bounded by the write timeout; it never reads. A
//!   daemon rejection arrives on the sink as an [`AttachmentItem`].
//! - Dropping an attachment detaches the view and never blocks on the reader
//!   thread. `ended(Released)` can therefore run after the drop returned.
//!
//! # Reconnect
//!
//! The caller owns it, because a reattach replays into a fresh terminal
//! surface and a daemon restart must first resolve the terminal in the
//! caller's control mirror. See [`crate::reattach`].

use cmux::TerminalId;
pub use cmux::raw::{AttachmentItem, CellSize, EndReason, Reattach, Replay};

/// Why an attachment ended.
#[derive(Clone, Debug, PartialEq)]
pub enum AttachEnd {
    /// This client detached (`detach` or drop).
    Released,
    /// The terminal is gone: a reattach found no such terminal in the
    /// daemon, or the identity fence rejected it.
    TerminalGone(String),
    /// Another client disconnected this view (a kick). Do not reattach.
    Replaced,
    /// The stream ended for a reason a reattach can fix (network, overflow,
    /// daemon shutdown). [`AttachEnd::reattach`] says when.
    Interrupted { reason: EndReason, reattach: Reattach },
    /// Transport or protocol failure outside the daemon's stream protocol.
    Failed(String),
}

impl AttachEnd {
    /// Maps the SDK's end of stream.
    pub fn from_end(reason: EndReason) -> Self {
        use cmux::raw::DetachReason;
        match reason {
            EndReason::ClosedByClient => Self::Released,
            EndReason::Detached { reason: Some(DetachReason::DisconnectedBy), .. } => {
                Self::Replaced
            }
            reason => Self::Interrupted { reattach: reason.reattach(), reason },
        }
    }

    /// What the caller should do next.
    pub fn reattach(&self) -> Reattach {
        match self {
            Self::Interrupted { reattach, .. } => *reattach,
            _ => Reattach::Never,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttachError {
    /// No implementation is available (no daemon in this frontend).
    Unsupported,
    /// The daemon refused the attach: unknown terminal, or the generation
    /// fence did not match (the terminal is gone or the daemon restarted).
    Rejected(String),
    /// The attachment is closed (detached, ended, or a failed write).
    Closed,
    Failed(String),
}

impl std::fmt::Display for AttachError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => write!(f, "terminal byte attachment is not available"),
            Self::Rejected(e) => write!(f, "the daemon refused the attach: {e}"),
            Self::Closed => write!(f, "the terminal attachment is closed"),
            Self::Failed(e) => write!(f, "terminal attachment failed: {e}"),
        }
    }
}

impl std::error::Error for AttachError {}

/// Receives one attachment's stream. Called on the attachment's reader
/// thread, in wire order: `replay`, then any mix of `bytes`, `resized` and
/// `item`, then `ended` exactly once.
pub trait TerminalByteSink: Send {
    /// Full screen state. Always the first call. Build a FRESH terminal
    /// surface of `replay.cols` x `replay.rows`, feed `replay.data` (or
    /// restore it with its Kitty state), restore the cursor shape from
    /// `replay.colors` (see [`cursor_restore`]), then write `replay.pending`
    /// before the next `bytes`.
    fn replay(&mut self, replay: &Replay);
    /// The PTY grid changed at this point in the stream. `replay` is the
    /// daemon's screen at the new grid. A mirror that parsed every earlier
    /// byte resizes in place to `cols` x `rows` after its queued output and
    /// drops the replay (cmux-next does); a consumer that cannot reflow
    /// rebuilds a fresh surface from it instead.
    fn resized(&mut self, replay: &Replay);
    /// Live PTY output, in order.
    fn bytes(&mut self, data: &[u8]);
    /// Everything else (colors, scroll, shared sizing, command rejections,
    /// events this crate does not model). `Output` colors arrive here as
    /// `ColorsChanged` right before their bytes.
    fn item(&mut self, _item: &AttachmentItem) {}
    /// The stream ended. The last call.
    fn ended(&mut self, end: AttachEnd);
}

/// A live attachment. `Send + Sync`; dropping it detaches the view (the
/// terminal keeps running in the daemon).
pub trait TerminalAttachment: Send + Sync {
    fn terminal(&self) -> &TerminalId;
    /// Keyboard/paste input as Ghostty encoded it (protocol-12 `send`).
    fn write(&self, data: &[u8]) -> Result<(), AttachError>;
    /// This view's grid in cells (`resize-attached-view`). Skipped when it
    /// equals the last report. The PTY follows only while this view owns
    /// geometry; the new grid then arrives as `resized`.
    fn resize(&self, size: CellSize) -> Result<(), AttachError>;
    /// Makes this view the geometry owner (the focused, visible view).
    /// Reports `size` (or the last report) first, because the daemon accepts
    /// a claim only from a view that reported a size; after
    /// `release_geometry` there is no last report, so pass the grid.
    fn claim_geometry(&self, size: Option<CellSize>) -> Result<(), AttachError>;
    /// Withdraws this view's size but keeps the stream (the view is hidden).
    fn release_geometry(&self) -> Result<(), AttachError>;
    /// Detaches now. Idempotent; the sink then ends with `Released`.
    fn detach(&self);
}

/// What to attach.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttachRequest {
    pub terminal: TerminalId,
    /// The daemon generation the caller's mirror read `terminal` in. The
    /// daemon refuses the attach when it differs (identity fence).
    pub generation: String,
    /// The view's grid; the daemon uses it as this view's first report.
    pub size: CellSize,
    /// Claim canonical geometry before `attach` returns.
    pub claim_geometry: bool,
}

/// Opens attachments.
pub trait TerminalAttacher: Send + Sync {
    fn attach(
        &self,
        request: AttachRequest,
        sink: Box<dyn TerminalByteSink>,
    ) -> Result<Box<dyn TerminalAttachment>, AttachError>;
}

/// Refuses every attach with `Unsupported`.
#[derive(Clone, Copy, Debug, Default)]
pub struct UnsupportedAttacher;

impl TerminalAttacher for UnsupportedAttacher {
    fn attach(
        &self,
        _request: AttachRequest,
        _sink: Box<dyn TerminalByteSink>,
    ) -> Result<Box<dyn TerminalAttachment>, AttachError> {
        Err(AttachError::Unsupported)
    }
}

/// DECSCUSR that restores a replay's cursor shape (the replay itself omits
/// it), or nothing when the replay names no shape or the shape equals the
/// surface's own default (`default_style`: `block`, `bar` or `underline`;
/// `default_blink`: `None` is Ghostty's default, blinking). Write it after
/// the replay data and before `pending`, like cmux-next.
pub fn cursor_restore(
    replay: &Replay,
    default_style: &str,
    default_blink: Option<bool>,
) -> Vec<u8> {
    use cmux::raw::{CursorStyle, Optional};
    let Some(colors) = &replay.colors else { return Vec::new() };
    let (style, steady) = match &colors.cursor_style {
        Optional::Value(CursorStyle::Block) => ("block", 2),
        Optional::Value(CursorStyle::Underline) => ("underline", 4),
        Optional::Value(CursorStyle::Bar) => ("bar", 6),
        _ => return Vec::new(),
    };
    let default_blinks = default_blink.unwrap_or(true);
    let blinks = match &colors.cursor_blink {
        Optional::Value(blink) => *blink,
        _ => default_blinks,
    };
    if style == default_style && blinks == default_blinks {
        return Vec::new();
    }
    format!("\x1b[{} q", if blinks { steady - 1 } else { steady }).into_bytes()
}
