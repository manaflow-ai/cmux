//! The opt-in Rust transcript prototype for RFD 0121.
//!
//! The normal agent pane remains the React transcript. Setting
//! CMUX_NATIVE_TRANSCRIPT=1 selects this read-only renderer in the Rust TUI,
//! which gives the fling benchmark a real native row model to exercise without
//! changing the shipped default.

use crate::App;
use acpmux::transcript::{Item, Transcript, item_text};
use ratatui::layout::Rect;
use ratatui::style::Style;
use unicode_width::UnicodeWidthStr;

/// Runtime opt-in for the disposable read-only transcript prototype.
pub const FLAG_ENV: &str = "CMUX_NATIVE_TRANSCRIPT";

pub fn enabled() -> bool {
    matches!(std::env::var(FLAG_ENV).ok().as_deref(), Some("1" | "true" | "on" | "yes"))
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct FlingStats {
    pub frames: usize,
    pub frame_p50_ms: f64,
    pub frame_p95_ms: f64,
    pub frame_max_ms: f64,
}

/// A flattened, read-only transcript. Rows are laid out once and scrolling
/// only changes the viewport offset, so a fling never rebuilds the document.
#[derive(Debug, Clone, Default)]
pub struct NativeTranscript {
    rows: Vec<String>,
    offset: usize,
}

impl NativeTranscript {
    pub fn from_transcript(transcript: &Transcript, width: usize) -> Self {
        let width = width.max(1);
        let mut rows = Vec::new();
        for item in &transcript.items {
            let prefix = match item {
                Item::User { .. } => "❯ ",
                Item::Thought { .. } => "· ",
                Item::Tool { .. } => "• ",
                Item::Error { .. } => "✗ ",
                _ => "  ",
            };
            for line in item_text(item).lines() {
                wrap_line(prefix, line, width, &mut rows);
            }
            if rows.is_empty() || !rows.last().is_some_and(|row| row.is_empty()) {
                rows.push(String::new());
            }
        }
        if rows.last().is_some_and(String::is_empty) {
            rows.pop();
        }
        Self { rows, offset: 0 }
    }

    /// Deterministic fixture used by transcript_fling and local profiling.
    pub fn seeded(rows: usize) -> Self {
        let rows = (0..rows)
            .map(|i| format!("{} transcript row {}", if i % 2 == 0 { "❯" } else { "•" }, i + 1))
            .collect();
        Self { rows, offset: 0 }
    }

    pub fn rows(&self) -> &[String] {
        &self.rows
    }

    pub fn offset(&self) -> usize {
        self.offset
    }

    pub fn scroll_by(&mut self, delta: usize) {
        self.offset = self.offset.saturating_add(delta).min(self.rows.len().saturating_sub(1));
    }

    pub fn scroll_to_top(&mut self) {
        self.offset = 0;
    }

    /// Move through a fixed fling sequence and return frame timing samples.
    /// The renderer calls this with the visible row count, while the bench
    /// uses the same method over a 3,000-row fixture.
    pub fn fling(&mut self, steps: &[usize], frames: usize) -> FlingStats {
        if steps.is_empty() || frames == 0 {
            return FlingStats::default();
        }
        let mut samples = Vec::with_capacity(frames);
        for i in 0..frames {
            let start = std::time::Instant::now();
            self.scroll_by(steps[i % steps.len()]);
            std::hint::black_box(self.rows.get(self.offset));
            samples.push(start.elapsed().as_secs_f64() * 1_000.0);
        }
        samples.sort_by(f64::total_cmp);
        let percentile = |p: usize| samples[(samples.len() - 1).min(samples.len() * p / 100)];
        FlingStats {
            frames: samples.len(),
            frame_p50_ms: percentile(50),
            frame_p95_ms: percentile(95),
            frame_max_ms: *samples.last().unwrap_or(&0.0),
        }
    }
}

fn wrap_line(prefix: &str, line: &str, width: usize, rows: &mut Vec<String>) {
    let prefix_width = prefix.width();
    let body_width = width.saturating_sub(prefix_width).max(1);
    if line.is_empty() {
        rows.push(prefix.to_owned());
        return;
    }
    let mut current = String::new();
    for word in line.split_whitespace() {
        let next_width =
            if current.is_empty() { word.width() } else { current.width() + 1 + word.width() };
        if next_width > body_width && !current.is_empty() {
            rows.push(format!("{prefix}{current}"));
            current.clear();
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(word);
    }
    if !current.is_empty() {
        rows.push(format!("{prefix}{current}"));
    }
}

/// Draw the flattened rows in the existing transcript viewport.
pub fn draw(f: &mut ratatui::Frame, area: Rect, app: &mut App, transcript: &Transcript, id: &str) {
    let model = NativeTranscript::from_transcript(transcript, area.width as usize);
    let viewport = app.viewport.entry(id.to_owned()).or_default();
    viewport.layout(
        model.rows.len(),
        area.height as usize,
        Rect { x: area.x + area.width.saturating_sub(1), y: area.y, width: 1, height: area.height },
    );
    let offset = viewport.offset;
    app.rows_cache = model.rows.clone();
    app.row_meta.clear();
    app.transcript_hitboxes.clear();
    let buf = f.buffer_mut();
    for (row, text) in model.rows.iter().enumerate().skip(offset).take(area.height as usize) {
        let y = area.y + (row - offset) as u16;
        buf.set_stringn(area.x, y, text, area.width.saturating_sub(1) as usize, Style::default());
        app.transcript_hitboxes.push((
            Rect {
                x: area.x,
                y,
                width: text.width().min(area.width.saturating_sub(1) as usize) as u16,
                height: 1,
            },
            row,
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flattening_wraps_and_keeps_item_order() {
        let mut transcript = Transcript::default();
        transcript.items.push(Item::User {
            text: "one two three".into(),
            steer: false,
            queued: false,
        });
        transcript.items.push(Item::Assistant { text: "answer".into() });
        let model = NativeTranscript::from_transcript(&transcript, 8);
        assert_eq!(model.rows(), &["❯ one", "❯ two", "❯ three", "  answer"]);
    }

    #[test]
    fn fling_is_bounded_at_the_last_row() {
        let mut model = NativeTranscript::seeded(3);
        let stats = model.fling(&[2, 2], 4);
        assert_eq!(model.offset(), 2);
        assert_eq!(stats.frames, 4);
    }
}
