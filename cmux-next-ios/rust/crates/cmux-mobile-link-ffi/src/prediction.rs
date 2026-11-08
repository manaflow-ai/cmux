//! Predictive local echo for the phone's terminals: the engine the Mac app
//! uses for Cloud and SSH terminals (`cmux-terminal-prediction`), over uniffi.
//!
//! Every phone terminal is remote (its shell runs on the Mac or a Cloud VM),
//! so every key waits a round trip of the link before it shows. The engine
//! decides which typed characters the phone may draw before the remote echoes
//! them; the terminal screen draws them over the Ghostty surface and never
//! writes them to the grid. On a link faster than the engine's threshold
//! (25 ms) it draws nothing.
//!
//! One object per terminal. Input comes on the main thread and output on the
//! surface's output queue, so the engine sits behind a mutex held only for the
//! call. Times are microseconds of one monotonic clock the app picks. Each
//! event answers whether the overlay must be drawn again.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use cmux_terminal_prediction::{PredictionConfiguration, PredictionOverlayLayout, Standing, TerminalPredictionEngine};

/// Where a drawn cell stands against the remote's echo.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PredictedStanding {
    /// Sent, no echo yet: drawn underlined.
    Speculative,
    /// Echoed, held until the frame with the real character is on screen.
    Confirmed,
    /// Deleted before the remote erased it: the cell's background only.
    Erased,
}

impl From<Standing> for PredictedStanding {
    fn from(value: Standing) -> Self {
        match value {
            Standing::Speculative => Self::Speculative,
            Standing::Confirmed => Self::Confirmed,
            Standing::Erased => Self::Erased,
        }
    }
}

/// One cell to draw: `offset` cells right of the live cursor (negative for a
/// held confirmation). Only printable ASCII is predicted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PredictedCell {
    pub character: u8,
    pub offset: i32,
    pub standing: PredictedStanding,
}

/// The run on the cursor row: `cell_count` cells from `leading_offset`, and
/// the caret where typing continues when it is on the row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PredictionRun {
    pub cells: Vec<PredictedCell>,
    pub leading_offset: i32,
    pub cell_count: i32,
    pub caret_offset: Option<i32>,
}

/// One terminal's prediction.
#[derive(uniffi::Object)]
pub struct TerminalPrediction {
    engine: Mutex<TerminalPredictionEngine>,
}

fn instant(now_us: u64) -> Duration {
    Duration::from_micros(now_us)
}

impl TerminalPrediction {
    fn engine(&self) -> MutexGuard<'_, TerminalPredictionEngine> {
        self.engine.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl TerminalPrediction {
    /// Predicts only while `enabled` (Settings → Terminal → Predictive echo).
    #[uniffi::constructor]
    pub fn new(enabled: bool) -> Arc<Self> {
        Arc::new(Self { engine: Mutex::new(TerminalPredictionEngine::new(PredictionConfiguration::default(), enabled, true)) })
    }

    /// The setting changed. A change starts over from a fresh engine (nothing
    /// drawn, no echo run); answers whether something was drawn before.
    pub fn set_enabled(&self, enabled: bool) -> bool {
        let mut engine = self.engine();
        if engine.is_enabled == enabled {
            return false;
        }
        let drew = !engine.glyphs().is_empty();
        *engine = TerminalPredictionEngine::new(engine.configuration, enabled, true);
        drew
    }

    /// Whether the terminal's alternate screen is on, read before the first
    /// key (a switch seen in output outranks it).
    pub fn seed_alternate_screen(&self, active: bool) {
        self.engine().seed_alternate_screen(active);
    }

    /// One write Ghostty encoded for the remote (one key, a paste, a report).
    pub fn sent(&self, bytes: Vec<u8>, now_us: u64) -> bool {
        self.engine().sent(&bytes, instant(now_us))
    }

    /// One batch of session output, just before Ghostty parses it.
    pub fn output(&self, bytes: Vec<u8>, now_us: u64) -> bool {
        self.engine().observed_output(&bytes, instant(now_us))
    }

    /// Output was lost or skipped (a replay, a resync): nothing in flight can be trusted.
    pub fn missed_output(&self, now_us: u64) -> bool {
        self.engine().missed_output(instant(now_us))
    }

    /// A frame Ghostty drew is on screen.
    pub fn presented_frame(&self, now_us: u64) -> bool {
        self.engine().presented_frame(instant(now_us))
    }

    /// Expires what is overdue.
    pub fn tick(&self, now_us: u64) -> bool {
        self.engine().tick(instant(now_us))
    }

    /// When the next glyph expires (microseconds of the same clock), or `None`
    /// when nothing is in flight: the screen's one timer stops then.
    pub fn next_expiry_us(&self) -> Option<u64> {
        self.engine().next_expiry().map(|at| u64::try_from(at.as_micros()).unwrap_or(u64::MAX))
    }

    /// Output removed cells the frame on screen still shows: keep the overlay
    /// where it is until the next presented frame.
    pub fn holds_layout(&self) -> bool {
        self.engine().holds_layout_until_frame()
    }

    /// What to draw on the cursor row, for the cursor's zero-based column and
    /// the grid's width, or `None` when nothing is drawn.
    pub fn run(&self, now_us: u64, cursor_column: i32, columns: i32) -> Option<PredictionRun> {
        let mut engine = self.engine();
        engine.tick(instant(now_us));
        let layout = PredictionOverlayLayout::new(&engine.glyphs(), cursor_column, columns)?;
        Some(PredictionRun {
            cells: layout
                .glyphs
                .iter()
                .map(|glyph| PredictedCell { character: glyph.character, offset: glyph.offset, standing: glyph.standing.into() })
                .collect(),
            leading_offset: layout.leading_offset,
            cell_count: layout.cell_count,
            caret_offset: layout.caret_offset,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: u64 = 1_000;

    /// Two keys echoed 60 ms later each: the run arms, and the third key shows
    /// at the cursor before its echo.
    fn armed(prediction: &TerminalPrediction) {
        prediction.sent(b"l".to_vec(), 0);
        prediction.output(b"l".to_vec(), 60 * MS);
        prediction.sent(b"s".to_vec(), 100 * MS);
        prediction.output(b"s".to_vec(), 160 * MS);
        prediction.presented_frame(170 * MS);
    }

    #[test]
    fn a_key_typed_over_a_slow_link_shows_before_its_echo() {
        let prediction = TerminalPrediction::new(true);
        armed(&prediction);
        assert!(prediction.sent(b" ".to_vec(), 200 * MS));
        let run = prediction.run(201 * MS, 10, 80).expect("drawn");
        assert_eq!(run.cells, vec![PredictedCell { character: b' ', offset: 0, standing: PredictedStanding::Speculative }]);
        assert_eq!(run.caret_offset, Some(1));
        assert!(prediction.next_expiry_us().is_some());
    }

    #[test]
    fn the_echo_confirms_and_the_next_frame_retires_it() {
        let prediction = TerminalPrediction::new(true);
        armed(&prediction);
        prediction.sent(b"-".to_vec(), 200 * MS);
        prediction.output(b"-".to_vec(), 260 * MS);
        let run = prediction.run(261 * MS, 11, 80).expect("held until its frame");
        assert_eq!(run.cells[0].standing, PredictedStanding::Confirmed);
        prediction.presented_frame(270 * MS);
        assert_eq!(prediction.run(271 * MS, 11, 80), None);
    }

    #[test]
    fn backspace_retracts_an_unechoed_key() {
        let prediction = TerminalPrediction::new(true);
        armed(&prediction);
        prediction.sent(b"x".to_vec(), 200 * MS);
        prediction.sent(vec![0x7F], 210 * MS);
        let run = prediction.run(211 * MS, 10, 80);
        assert!(run.is_none_or(|run| run.cells.iter().all(|cell| cell.standing == PredictedStanding::Erased)));
    }

    #[test]
    fn off_draws_nothing() {
        let prediction = TerminalPrediction::new(false);
        armed(&prediction);
        assert!(!prediction.sent(b"x".to_vec(), 200 * MS));
        assert_eq!(prediction.run(201 * MS, 10, 80), None);
        assert_eq!(prediction.next_expiry_us(), None);
    }

    #[test]
    fn turning_it_off_takes_the_overlay_down() {
        let prediction = TerminalPrediction::new(true);
        armed(&prediction);
        prediction.sent(b"x".to_vec(), 200 * MS);
        assert!(prediction.set_enabled(false));
        assert_eq!(prediction.run(201 * MS, 10, 80), None);
    }

    #[test]
    fn a_fast_link_draws_nothing() {
        let prediction = TerminalPrediction::new(true);
        prediction.sent(b"l".to_vec(), 0);
        prediction.output(b"l".to_vec(), 3 * MS);
        prediction.sent(b"s".to_vec(), 50 * MS);
        prediction.output(b"s".to_vec(), 53 * MS);
        prediction.sent(b"x".to_vec(), 100 * MS);
        assert_eq!(prediction.run(101 * MS, 10, 80), None);
    }
}
