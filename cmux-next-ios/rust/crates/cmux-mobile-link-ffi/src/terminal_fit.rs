//! The phone's scaled projection of a full-screen app and its one exception
//! (`cmux_terminal_projection::{zoom, fit_policy}`):
//!
//! - [`TerminalFitPolicy`]: when the phone claims its grid after all (typing
//!   text into a TUI fits it, remembered per program, released when the
//!   program exits or the page leaves, toggled from the title menu).
//! - `terminal_zoom_*`: pinch, double tap and pan over the host's grid.
//!
//! Swift does UIKit and gestures; the decisions are here.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_terminal_projection::fit_policy::{self, FitPolicy, FitReason, Foreground};
use cmux_terminal_projection::zoom::{ZoomGeometry, ZoomState};

use crate::terminal_projection::TerminalProjection;

/// Why the phone claims its grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalFitReason {
    /// Projected: the Mac keeps its grid.
    Projected,
    /// The person typed text into this TUI.
    Typed,
    /// This program was fitted before.
    Remembered,
    /// Fit to Phone, chosen.
    Forced,
}

/// The policy's answer after an event.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalFitDecision {
    /// The phone claims its grid now.
    pub claims: bool,
    /// `claims` changed with this event.
    pub changed: bool,
    pub reason: TerminalFitReason,
    /// The foreground is a TUI (alternate screen, or an inline TUI).
    pub is_tui: bool,
    /// The foreground program's key, if named.
    pub program: Option<String>,
    /// Persist ``TerminalFitPolicy/remembered()`` now.
    pub remembered_changed: bool,
}

/// One terminal's fit state; called on the main actor.
#[derive(uniffi::Object)]
pub struct TerminalFitPolicy {
    inner: Mutex<FitPolicy>,
}

impl TerminalFitPolicy {
    fn inner(&self) -> MutexGuard<'_, FitPolicy> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn answer(policy: &FitPolicy, decision: fit_policy::FitDecision) -> TerminalFitDecision {
        TerminalFitDecision {
            claims: decision.claims,
            changed: decision.changed,
            reason: match decision.reason {
                FitReason::Projected => TerminalFitReason::Projected,
                FitReason::Typed => TerminalFitReason::Typed,
                FitReason::Remembered => TerminalFitReason::Remembered,
                FitReason::Forced => TerminalFitReason::Forced,
            },
            is_tui: policy.foreground().is_tui(),
            program: policy.foreground().program.clone(),
            remembered_changed: decision.remembered_changed,
        }
    }
}

#[uniffi::export]
impl TerminalFitPolicy {
    /// `remembered`: the programs fitted before, most recent last.
    #[uniffi::constructor]
    pub fn new(remembered: Vec<String>) -> Self {
        Self { inner: Mutex::new(FitPolicy::new(remembered)) }
    }

    /// After each feed: what the projection's model has in the foreground.
    /// The program is the terminal title's, else `fallback_program` (the tab's).
    pub fn observe(
        &self,
        projection: Arc<TerminalProjection>,
        fallback_program: String,
    ) -> TerminalFitDecision {
        let foreground = {
            let projection = projection.inner();
            let term = projection.terminal();
            let program = term
                .title_text()
                .and_then(|title| fit_policy::program_key(&title))
                .or_else(|| fit_policy::program_key(&fallback_program));
            Foreground { alternate: term.is_alternate(), cursor_hidden: !term.cursor_visible, program }
        };
        let mut policy = self.inner();
        let decision = policy.observe(foreground);
        Self::answer(&policy, decision)
    }

    /// Bytes the person sent.
    pub fn typed(&self, bytes: Vec<u8>) -> TerminalFitDecision {
        let mut policy = self.inner();
        let decision = policy.typed(&bytes);
        Self::answer(&policy, decision)
    }

    /// Fit to Phone from the title menu or the key bar.
    pub fn toggle(&self) -> TerminalFitDecision {
        let mut policy = self.inner();
        let decision = policy.toggle();
        Self::answer(&policy, decision)
    }

    /// The page is on screen and interactive, or not.
    pub fn set_page_present(&self, present: bool) -> TerminalFitDecision {
        let mut policy = self.inner();
        let decision = policy.set_page_present(present);
        Self::answer(&policy, decision)
    }

    pub fn is_fitted(&self) -> bool {
        self.inner().is_fitted()
    }

    pub fn claims(&self) -> bool {
        self.inner().claims()
    }

    /// The programs that fit at once, most recent last.
    pub fn remembered(&self) -> Vec<String> {
        self.inner().remembered().to_vec()
    }
}

/// The host grid and the page, in points at the reader's font size.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TerminalZoomGeometry {
    pub grid_width: f64,
    pub grid_height: f64,
    pub page_width: f64,
    pub page_height: f64,
}

/// A zoom and a pan (page points; the grid's top-left is at minus the pan).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TerminalZoomState {
    pub scale: f64,
    pub pan_x: f64,
    pub pan_y: f64,
}

fn to_geometry(g: TerminalZoomGeometry) -> ZoomGeometry {
    ZoomGeometry {
        grid_width: g.grid_width,
        grid_height: g.grid_height,
        page_width: g.page_width,
        page_height: g.page_height,
    }
}

fn state(s: TerminalZoomState) -> ZoomState {
    ZoomState { scale: s.scale, pan_x: s.pan_x, pan_y: s.pan_y }
}

fn out(s: ZoomState) -> TerminalZoomState {
    TerminalZoomState { scale: s.scale, pan_x: s.pan_x, pan_y: s.pan_y }
}

/// Fit width: the whole grid's width on the page (at most readable).
#[uniffi::export]
pub fn terminal_zoom_initial(grid: TerminalZoomGeometry) -> TerminalZoomState {
    out(to_geometry(grid).initial())
}

#[uniffi::export]
pub fn terminal_zoom_fit_width_scale(grid: TerminalZoomGeometry) -> f64 {
    to_geometry(grid).fit_width_scale()
}

/// Kept on the page (and the scale within its bounds).
#[uniffi::export]
pub fn terminal_zoom_clamp(grid: TerminalZoomGeometry, zoom: TerminalZoomState) -> TerminalZoomState {
    out(to_geometry(grid).clamp(state(zoom)))
}

/// A pinch: `zoom` at `scale`, the point under the fingers kept under them.
#[uniffi::export]
pub fn terminal_zoom_about(
    grid: TerminalZoomGeometry,
    zoom: TerminalZoomState,
    scale: f64,
    focus_x: f64,
    focus_y: f64,
) -> TerminalZoomState {
    out(to_geometry(grid).zoom_about(state(zoom), scale, focus_x, focus_y))
}

/// A pinch ended: its scale snapped to fit width or readable when near one.
#[uniffi::export]
pub fn terminal_zoom_snap(
    grid: TerminalZoomGeometry,
    zoom: TerminalZoomState,
    focus_x: f64,
    focus_y: f64,
) -> TerminalZoomState {
    let g = to_geometry(grid);
    let snapped = g.snap(zoom.scale);
    out(g.zoom_about(state(zoom), snapped, focus_x, focus_y))
}

/// A double tap at the focus: fit width to readable and back.
#[uniffi::export]
pub fn terminal_zoom_toggle(
    grid: TerminalZoomGeometry,
    zoom: TerminalZoomState,
    focus_x: f64,
    focus_y: f64,
) -> TerminalZoomState {
    out(to_geometry(grid).toggle(state(zoom), focus_x, focus_y))
}

/// The least pan that shows the cell at `(x, y)` (`width` x `height`, scale-1
/// points) with `margin` page points beside it: typing follows the cursor.
#[uniffi::export]
pub fn terminal_zoom_reveal(
    grid: TerminalZoomGeometry,
    zoom: TerminalZoomState,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    margin: f64,
) -> TerminalZoomState {
    out(to_geometry(grid).reveal(state(zoom), x, y, width, height, margin))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typing_into_htop_fits_once_and_the_next_htop_fits_at_once() {
        let projection = Arc::new(TerminalProjection::new(120, 40));
        projection.set_viewport(54, 38);
        let policy = TerminalFitPolicy::new(Vec::new());
        projection.feed(b"$ ".to_vec(), true);
        assert!(!policy.observe(projection.clone(), "zsh".into()).is_tui);
        projection.feed(b"\x1b]2;htop\x07\x1b[?1049h\x1b[Hhtop".to_vec(), true);
        let entered = policy.observe(projection.clone(), "zsh".into());
        assert!(entered.is_tui && !entered.claims);
        assert_eq!(entered.program.as_deref(), Some("htop"));
        assert!(!policy.typed(b"\x1b[B\x1b[B".to_vec()).claims);
        let fit = policy.typed(b"/cla".to_vec());
        assert!(fit.claims && fit.changed && fit.remembered_changed);
        assert_eq!(policy.remembered(), ["htop"]);
        projection.feed(b"\x1b[?1049l\x1b]2;zsh\x07$ ".to_vec(), true);
        let exited = policy.observe(projection.clone(), "zsh".into());
        assert!(!exited.claims && exited.changed);
        // A new terminal (another page) remembers it.
        let next = TerminalFitPolicy::new(policy.remembered());
        projection.feed(b"\x1b]2;htop\x07\x1b[?1049h".to_vec(), true);
        let again = next.observe(projection, "zsh".into());
        assert!(again.claims && again.changed);
        assert_eq!(again.reason, TerminalFitReason::Remembered);
    }

    #[test]
    fn an_inline_tui_is_a_hidden_cursor_under_a_named_program() {
        let projection = Arc::new(TerminalProjection::new(120, 40));
        projection.set_viewport(54, 38);
        let policy = TerminalFitPolicy::new(Vec::new());
        projection.feed(b"\x1b]0;\xe2\x9c\xb3 Claude Code\x07\x1b[?25l> ".to_vec(), true);
        let entered = policy.observe(projection, "zsh".into());
        assert!(entered.is_tui);
        assert_eq!(entered.program.as_deref(), Some("claude"));
        assert!(policy.typed(b"fix it".to_vec()).claims);
    }

    #[test]
    fn zoom_round_trip() {
        let g = TerminalZoomGeometry {
            grid_width: 864.0,
            grid_height: 624.0,
            page_width: 378.0,
            page_height: 600.0,
        };
        let fit = terminal_zoom_initial(g);
        assert!((fit.scale - 378.0 / 864.0).abs() < 1e-9);
        let readable = terminal_zoom_toggle(g, fit, 100.0, 50.0);
        assert!((readable.scale - 1.0).abs() < 1e-9);
        let pinched = terminal_zoom_about(g, readable, 0.48, 0.0, 0.0);
        let snapped = terminal_zoom_snap(g, pinched, 0.0, 0.0);
        assert!((snapped.scale - fit.scale).abs() < 1e-9);
        assert_eq!(
            terminal_zoom_clamp(g, TerminalZoomState { scale: 1.0, pan_x: -5.0, pan_y: 1e9 }).pan_x,
            0.0
        );
        assert!((terminal_zoom_fit_width_scale(g) - fit.scale).abs() < 1e-9);
        let shown = terminal_zoom_reveal(g, readable, 800.0, 0.0, 7.2, 15.6, 0.0);
        assert!(shown.pan_x > readable.pan_x);
    }
}
