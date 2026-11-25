//! The phone's own view of a Mac terminal it does not size
//! (`cmux-terminal-projection`): a VT model at the Mac's grid, fed the PTY
//! bytes, whose primary screen is re-wrapped at the phone's width as VT bytes
//! for the phone's Ghostty surface. The Mac's PTY never resizes for the phone
//! while a shell or an inline TUI is on its primary screen.
//!
//! One object per terminal, called on the main actor; a mutex keeps it
//! `Sync` for uniffi and is held only for the call.

use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_terminal_projection::{AltPan, DEFAULT_HISTORY_LIMIT, Projection, Segment};

/// What a feed gives the phone's surface, in order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ProjectionSegment {
    /// Bytes for the surface as it is.
    Paint { bytes: Vec<u8> },
    /// The surface starts over (`ESC c`, sent by the caller), then these bytes.
    Reset { bytes: Vec<u8> },
    /// The program switched to (true) or from the alternate screen here.
    Alternate { on: bool },
    /// The alternate screen's bytes, unchanged.
    Raw { bytes: Vec<u8> },
}

/// Bytes painted and surface resets, for the sizing log and benches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProjectionStats {
    pub bytes_out: u64,
    pub resets: u64,
}

/// A `terminal-find` cell on the phone's re-wrapped rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProjectionLocation {
    /// Rows from the bottom of the re-wrapped content (1: its last row).
    pub from_bottom: u64,
    pub column: u32,
}

/// A full-screen app's transcript as one document for a fresh surface of
/// the Mac's grid (`ESC c` first): its scrollback is the rows the app
/// scrolled away, its screen the app's screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TranscriptPaint {
    pub bytes: Vec<u8>,
    /// The document's rows.
    pub rows: u32,
    /// The document row the app's screen begins at.
    pub screen_top: u32,
}

/// What a vertical pan over a full-screen app does: bytes the phone's
/// surface paints itself (nothing sent), then rows of wheel for the app on
/// the Mac (0: nothing goes).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProjectionAltPan {
    pub paint: Vec<u8>,
    /// Rows of wheel, positive toward older content.
    pub forward_rows: f64,
}

/// Rows held for a pan over a full-screen app, and their bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProjectionHeld {
    pub rows: u64,
    pub bytes: u64,
}

#[derive(uniffi::Object)]
pub struct TerminalProjection {
    inner: Mutex<Projection>,
}

impl TerminalProjection {
    pub(crate) fn inner(&self) -> MutexGuard<'_, Projection> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn segments(segments: Vec<Segment>) -> Vec<ProjectionSegment> {
    segments
        .into_iter()
        .map(|segment| match segment {
            Segment::Paint(bytes) => ProjectionSegment::Paint { bytes },
            Segment::Reset(bytes) => ProjectionSegment::Reset { bytes },
            Segment::Alternate(on) => ProjectionSegment::Alternate { on },
            Segment::Raw(bytes) => ProjectionSegment::Raw { bytes },
        })
        .collect()
}

fn size(value: u32) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX).clamp(1, 4096)
}

#[uniffi::export]
impl TerminalProjection {
    /// A projection of a Mac terminal of `host_cols` x `host_rows`.
    #[uniffi::constructor]
    pub fn new(host_cols: u32, host_rows: u32) -> Self {
        Self { inner: Mutex::new(Projection::new(size(host_cols), size(host_rows), DEFAULT_HISTORY_LIMIT)) }
    }

    /// The Mac's PTY grid changed (its replay follows).
    pub fn set_host_grid(&self, cols: u32, rows: u32) {
        self.inner().set_host_grid(size(cols), size(rows));
    }

    /// The phone's grid; a change repaints at once.
    pub fn set_viewport(&self, cols: u32, rows: u32) -> Vec<ProjectionSegment> {
        segments(self.inner().set_viewport(size(cols), size(rows)))
    }

    /// The program's bytes. `paint` false: taken, painted at the next feed.
    pub fn feed(&self, bytes: Vec<u8>, paint: bool) -> Vec<ProjectionSegment> {
        segments(self.inner().feed(&bytes, paint))
    }

    /// Paints what unpainted feeds changed, once (nothing on the alternate screen).
    pub fn flush(&self) -> Vec<ProjectionSegment> {
        segments(self.inner().flush())
    }

    /// Paints what changed since the last paint.
    pub fn paint(&self) -> Vec<ProjectionSegment> {
        segments(self.inner().paint().into_iter().collect())
    }

    /// Where the reader is: phone rows from the end of the surface's
    /// document to the top of the rows read (0: at the bottom). A viewport
    /// change keeps those lines in the window it paints.
    pub fn set_reader_rows_from_end(&self, rows: u32) {
        self.inner().set_reader_rows_from_end(usize::try_from(rows).unwrap_or(usize::MAX));
    }

    /// Mac scrollback rows older than what the surface holds (a viewport
    /// change paints a window: the screen and two phone screens above it).
    pub fn older_rows(&self) -> u64 {
        u64::try_from(self.inner().older_rows()).unwrap_or(u64::MAX)
    }

    /// The reader reached the oldest row the surface holds: `host_rows` more
    /// of the scrollback, as a reset. Empty when the surface has all of it.
    pub fn load_older(&self, host_rows: u32) -> Vec<ProjectionSegment> {
        segments(self.inner().load_older(usize::try_from(host_rows).unwrap_or(usize::MAX)))
    }

    /// The next paint starts the surface over.
    pub fn request_reset(&self) {
        self.inner().request_reset();
    }

    /// Answers for the program (cursor and size reports in Mac cells).
    pub fn take_replies(&self) -> Vec<u8> {
        self.inner().take_replies()
    }

    /// A vertical pan of `rows` (positive: toward older content) over the
    /// alternate screen: within the rows the app scrolled off, the phone
    /// paints them and nothing is sent; past them, for an app that asked for
    /// the mouse, on the primary screen or with nothing held, the wheel goes
    /// to the Mac as before.
    pub fn alt_pan(&self, rows: f64) -> ProjectionAltPan {
        let AltPan { paint, forward_rows } = self.inner().alt_pan(rows);
        ProjectionAltPan { paint, forward_rows }
    }

    /// A key or a tap: bytes that show the app's live screen again (empty
    /// when the surface already shows it).
    pub fn alt_return_live(&self) -> Vec<u8> {
        self.inner().alt_return_live()
    }

    /// How many held rows back the surface shows the alternate screen.
    pub fn alt_rows_back(&self) -> u32 {
        u32::try_from(self.inner().alt_rows_back()).unwrap_or(u32::MAX)
    }

    pub fn held(&self) -> ProjectionHeld {
        let (rows, bytes) = self.inner().held();
        ProjectionHeld { rows: rows as u64, bytes: bytes as u64 }
    }

    pub fn is_alternate(&self) -> bool {
        self.inner().is_alternate()
    }

    /// Where a daemon `terminal-find` cell (`host_from_bottom`: 1 is the
    /// Mac's last row; its column in Mac cells) lands on the phone's rows.
    /// None: the projection does not hold that row (older than the replay).
    pub fn locate(&self, host_from_bottom: u64, host_column: u32) -> Option<ProjectionLocation> {
        let at = self
            .inner()
            .locate(usize::try_from(host_from_bottom).ok()?, usize::try_from(host_column).ok()?)?;
        Some(ProjectionLocation {
            from_bottom: u64::try_from(at.from_bottom).ok()?,
            column: u32::try_from(at.column).ok()?,
        })
    }

    /// Rows of the full-screen app's transcript above its screen: what the
    /// phone scrolls up to with no round trip (0: none kept, or not on the
    /// alternate screen).
    pub fn transcript_rows_above(&self) -> u32 {
        let inner = self.inner();
        if !inner.is_alternate() {
            return 0;
        }
        u32::try_from(inner.held().0).unwrap_or(u32::MAX)
    }

    /// The transcript as one document (none while no rows are kept).
    pub fn transcript_paint(&self) -> Option<TranscriptPaint> {
        let (bytes, rows, screen_top) = self.inner().alt_document()?;
        Some(TranscriptPaint {
            bytes,
            rows: u32::try_from(rows).unwrap_or(u32::MAX),
            screen_top: u32::try_from(screen_top).unwrap_or(u32::MAX),
        })
    }

    pub fn stats(&self) -> ProjectionStats {
        let (bytes_out, resets) = self.inner().stats();
        ProjectionStats { bytes_out, resets }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shell_line_is_painted_at_the_phone_width() {
        let projection = TerminalProjection::new(120, 40);
        let first = projection.set_viewport(54, 38);
        assert!(matches!(first.as_slice(), [ProjectionSegment::Reset { .. }]));
        let painted = projection.feed(b"$ echo hi\r\nhi\r\n$ ".to_vec(), true);
        let [ProjectionSegment::Paint { bytes }] = painted.as_slice() else { panic!("{painted:?}") };
        let text = String::from_utf8_lossy(bytes);
        assert!(text.contains("echo hi") && text.contains("hi"), "{text}");
        let vim = projection.feed(b"\x1b[?1049hvim".to_vec(), true);
        assert!(vim.contains(&ProjectionSegment::Alternate { on: true }));
        assert!(projection.is_alternate());
    }

    #[test]
    fn a_full_screen_apps_scrolled_rows_are_kept_for_the_phone() {
        let projection = TerminalProjection::new(40, 10);
        projection.set_viewport(40, 10);
        projection.feed(b"\x1b[?1049h".to_vec(), true);
        assert_eq!(projection.transcript_rows_above(), 0);
        assert!(projection.transcript_paint().is_none());
        // An app whose transcript (rows 1-9) moves up 3 rows a frame over a status row.
        for first in (0..=12).step_by(3) {
            let mut frame = String::new();
            for r in 0..9 {
                frame.push_str(&format!("\x1b[{};1H\x1b[2Kline {:03}", r + 1, first + r));
            }
            frame.push_str("\x1b[10;1H\x1b[2K> status");
            projection.feed(format!("\x1b[?2026h{frame}\x1b[?2026l").into_bytes(), true);
        }
        assert_eq!(projection.transcript_rows_above(), 12);
        let paint = projection.transcript_paint().expect("rows kept");
        assert_eq!((paint.rows, paint.screen_top), (22, 12));
        let text = String::from_utf8_lossy(&paint.bytes);
        assert!(
            text.contains("line 000") && text.contains("line 020") && text.ends_with("> status"),
            "{text}"
        );
    }

    #[test]
    fn a_pan_within_held_rows_paints_and_forwards_nothing() {
        let projection = TerminalProjection::new(80, 24);
        let _ = projection.set_viewport(54, 38);
        let mut bytes = b"\x1b[?1049h".to_vec();
        for i in 0..60 {
            bytes.extend_from_slice(format!("line {i}\r\n").as_bytes());
        }
        let _ = projection.feed(bytes, true);
        assert_eq!(projection.held().rows, 37);
        let step = projection.alt_pan(3.0);
        assert!(!step.paint.is_empty());
        assert_eq!(step.forward_rows, 0.0);
        assert_eq!(projection.alt_rows_back(), 3);
        assert!(!projection.alt_return_live().is_empty());
        assert_eq!(projection.alt_rows_back(), 0);
    }
}
