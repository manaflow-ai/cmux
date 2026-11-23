//! A pane move or resize is not work (W5-Q, bench round 4 screen friction 8).
//!
//! A resized terminal sends SIGWINCH and the agent redraws its whole screen,
//! so the output revision moves for a moment. Read as fresh output, that
//! redraw upgraded the agent's idle prompt to `working` for a few seconds
//! after every `pane move` or split. The tracker is told the terminal's
//! size, as the scanner reads it from the terminal snapshot, and output that
//! only answers a size change is no working signal.
//!
//! The row drives a screen that no rule of the manifest matches. There fresh
//! output is the only fact and still starts `working`, so the row is red
//! without the size rule. On the agent's own idle prompt output no longer
//! starts work for an agent at rest (`output_on_idle_screen.rs`), and a row
//! on that prompt would be green with or without the size rule.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{DetectionInput, ManifestSet};

const TERMINAL: &str = "term_00000000000000000000000000000e05";
const RESIZE_AT_MS: u64 = 3_000;
const END_MS: u64 = 6_000;
const TICK_MS: u64 = 20;

/// Claude Code's screen after a command printed: no prompt box, no spinner,
/// no question. No rule of the manifest matches it.
const CLAUDE_NO_RULE: &str =
    "⏺ Running the build.\n\n   Compiling serde v1.0.219\n   Compiling regex v1.11.1\n";

#[test]
fn w5q_a_resize_redraw_does_not_read_as_working() {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == "claude").expect("bundled manifest");
    let none = DetectionInput { screen: CLAUDE_NO_RULE, osc_title: "", osc_progress: "" };
    assert_eq!(manifest.detect(none).matched_rule, None, "the row needs a screen with no rule");
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    let mut revision = 1;
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        let (cols, rows) = if ms < RESIZE_AT_MS { (120, 40) } else { (60, 40) };
        tracker.observe_size(TERMINAL, cols, rows, now);
        // The agent redraws after SIGWINCH: a burst of output over 200 ms
        // that ends on the same screen.
        if [RESIZE_AT_MS, RESIZE_AT_MS + 20, RESIZE_AT_MS + 100, RESIZE_AT_MS + 200].contains(&ms) {
            revision += 1;
        }
        if !tracker.observe_revision(TERMINAL, revision, now) {
            continue;
        }
        let mut detection = manifest.detect(none);
        tracker.apply_output_activity(TERMINAL, &mut detection, now);
        if let Some(emission) =
            tracker.record_detection_at(TERMINAL, Some(("claude", detection)), now, false, false)
        {
            emitted.push((ms, emission.state));
        }
    }
    assert_eq!(emitted.first().map(|(_, state)| *state), Some(AgentState::Idle), "{emitted:?}");
    assert!(
        !emitted.iter().any(|(_, state)| *state == AgentState::Working),
        "the resize redraw read as working: {emitted:?}"
    );
}
