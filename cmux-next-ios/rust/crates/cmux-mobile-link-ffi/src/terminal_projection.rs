//! The phone's own view of a Mac terminal it does not size
//! (`cmux-terminal-projection`): a VT model at the Mac's grid, fed the PTY
//! bytes, whose primary screen is re-wrapped at the phone's width as VT bytes
//! for the phone's Ghostty surface. The Mac's PTY never resizes for the phone
//! while a shell or an inline TUI is on its primary screen.
//!
//! One object per terminal, called on the main actor; a mutex keeps it
//! `Sync` for uniffi and is held only for the call.

use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_terminal_projection::{DEFAULT_HISTORY_LIMIT, Projection, Segment};

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

#[derive(uniffi::Object)]
pub struct TerminalProjection {
    inner: Mutex<Projection>,
}

impl TerminalProjection {
    fn inner(&self) -> MutexGuard<'_, Projection> {
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

    pub fn is_alternate(&self) -> bool {
        self.inner().is_alternate()
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
}
