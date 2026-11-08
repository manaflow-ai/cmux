//! Predictive local echo for the phone's terminals: the shared engine
//! (`cmux-terminal-prediction`, the one the Mac app asks over cmux-app-ffi)
//! behind a uniffi object, so a typed key shows on the phone at once instead
//! of a round trip later.
//!
//! Every terminal on the phone runs its shell on another machine (a Mac, a
//! Cloud VM), so each one is remote. The engine still draws nothing until the
//! remote echoed two typed characters in a row and the measured echo is slower
//! than its threshold, so a fast link, a password prompt or a full-screen
//! program never sees a predicted glyph.
//!
//! One object per terminal. Input comes on the main thread and output on the
//! surface's output queue, so the engine sits behind a mutex held only for
//! the call. Times are microseconds of one monotonic clock Swift picks
//! (`CACurrentMediaTime`).

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use cmux_terminal_prediction::{PredictionConfiguration, PredictionOverlayLayout, TerminalPredictionEngine};

/// One cell to draw. `standing`: 0 speculative (underlined), 1 confirmed
/// (plain, held until its frame), 2 erased (the cell's background only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PredictedGlyph {
    /// One printable ASCII byte.
    pub character: u8,
    pub standing: u8,
    /// Cells right of the live cursor; negative for a held confirmation.
    pub offset: i32,
}

/// The run on the cursor row: `cell_count` cells from `leading_offset` (cells
/// from the cursor), and the caret where typing continues, if it fits.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PredictionLayout {
    pub leading_offset: i32,
    pub cell_count: i32,
    pub caret_offset: Option<i32>,
    pub glyphs: Vec<PredictedGlyph>,
}

/// One terminal's prediction.
#[derive(uniffi::Object)]
pub struct TerminalPrediction {
    engine: Mutex<TerminalPredictionEngine>,
}

fn at(now_us: u64) -> Duration {
    Duration::from_micros(now_us)
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

impl TerminalPrediction {
    fn engine(&self) -> MutexGuard<'_, TerminalPredictionEngine> {
        self.engine.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl TerminalPrediction {
    /// Predicts only while `enabled` (the setting) and `remote` (the shell
    /// runs on another machine).
    #[uniffi::constructor]
    pub fn new(enabled: bool, remote: bool) -> Self {
        Self {
            engine: Mutex::new(TerminalPredictionEngine::new(
                PredictionConfiguration::default(),
                enabled,
                remote,
            )),
        }
    }

    /// Sets the setting and remoteness. A change starts over from a fresh
    /// engine; answers whether anything drawn went.
    pub fn set(&self, enabled: bool, remote: bool) -> bool {
        let mut engine = self.engine();
        if engine.is_enabled == enabled && engine.is_remote_surface == remote {
            return false;
        }
        let drew = !engine.glyphs().is_empty();
        *engine = TerminalPredictionEngine::new(engine.configuration, enabled, remote);
        drew
    }

    /// Whether a full-screen program already owns the screen, read from the
    /// terminal before the first keystroke.
    pub fn seed_alternate_screen(&self, active: bool) {
        self.engine().seed_alternate_screen(active);
    }

    /// One write of encoded input about to go to the remote (Ghostty's
    /// `io_write_cb`: one key press, a paste, a mouse report). Answers whether
    /// the overlay must be drawn again.
    pub fn sent(&self, bytes: Vec<u8>, now_us: u64) -> bool {
        self.engine().sent(&bytes, at(now_us))
    }

    /// Output from the remote, just before the terminal parses it.
    pub fn output(&self, bytes: Vec<u8>, now_us: u64) -> bool {
        self.engine().observed_output(&bytes, at(now_us))
    }

    /// Output was lost or replaced before the terminal parsed it (a snapshot
    /// restore, a reattach): everything starts over.
    pub fn missed_output(&self, now_us: u64) -> bool {
        self.engine().missed_output(at(now_us))
    }

    /// A rendered frame reached the screen: held confirmations retire.
    pub fn presented_frame(&self, now_us: u64) -> bool {
        self.engine().presented_frame(at(now_us))
    }

    /// Time passed with no other event: withdraws what aged out.
    pub fn tick(&self, now_us: u64) -> bool {
        self.engine().tick(at(now_us))
    }

    /// When the next change to what is drawn falls due, or `None` when
    /// nothing is drawn: the one timer of a terminal gone quiet.
    pub fn next_expiry_us(&self) -> Option<u64> {
        self.engine().next_expiry().map(micros)
    }

    /// Whether the overlay stays where it is until the next presented frame.
    pub fn holds_layout(&self) -> bool {
        self.engine().holds_layout_until_frame()
    }

    /// 0 disabled, 1 local surface, 2 listening, 3 link fast enough, 4
    /// alternate screen, 5 suspended, 6 predicting.
    pub fn status(&self, now_us: u64) -> u8 {
        self.engine().status(at(now_us)) as u8
    }

    /// The smoothed round trip from keystroke to echo, before the first echo `None`.
    pub fn echo_latency_us(&self) -> Option<u64> {
        self.engine().observed_echo_latency().map(micros)
    }

    /// What to draw now on a row of `columns` cells with the live cursor at
    /// `cursor_column`, after withdrawing what aged out; `None` hides the overlay.
    pub fn layout(&self, now_us: u64, cursor_column: i32, columns: i32) -> Option<PredictionLayout> {
        let mut engine = self.engine();
        engine.tick(at(now_us));
        let layout = PredictionOverlayLayout::new(&engine.glyphs(), cursor_column, columns)?;
        Some(PredictionLayout {
            leading_offset: layout.leading_offset,
            cell_count: layout.cell_count,
            caret_offset: layout.caret_offset,
            glyphs: layout
                .glyphs
                .iter()
                .map(|glyph| PredictedGlyph {
                    character: glyph.character,
                    standing: glyph.standing as u8,
                    offset: glyph.offset,
                })
                .collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: u64 = 1_000;

    /// A shell 150 ms away: after two echoed keys, the third shows at once.
    #[test]
    fn predicts_after_a_confirmed_echo_run() {
        let prediction = TerminalPrediction::new(true, true);
        let mut now = 0;
        for byte in [b'l', b's'] {
            prediction.sent(vec![byte], now);
            now += 150 * MS;
            prediction.output(vec![byte], now);
            prediction.presented_frame(now);
        }
        assert!(prediction.layout(now, 2, 80).is_none(), "nothing in flight yet");
        prediction.sent(vec![b' '], now);
        prediction.sent(vec![b'-'], now + MS);
        let layout = prediction.layout(now + MS, 2, 80).expect("drawn before the echo");
        let drawn: Vec<u8> = layout.glyphs.iter().map(|glyph| glyph.character).collect();
        assert_eq!(drawn, b" -");
        assert!(layout.glyphs.iter().all(|glyph| glyph.standing == 0));
        assert_eq!(prediction.status(now + MS), 6);
    }

    #[test]
    fn a_local_terminal_never_predicts() {
        let prediction = TerminalPrediction::new(true, false);
        prediction.sent(vec![b'a'], 0);
        prediction.output(vec![b'a'], 150 * MS);
        prediction.sent(vec![b'b'], 150 * MS);
        prediction.output(vec![b'b'], 300 * MS);
        prediction.sent(vec![b'c'], 300 * MS);
        assert!(prediction.layout(301 * MS, 2, 80).is_none());
        assert_eq!(prediction.status(301 * MS), 1);
    }
}
