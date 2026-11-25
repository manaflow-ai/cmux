//! A pane move or resize is not work (W5-Q, bench round 4 screen friction 8).
//!
//! A resized terminal sends SIGWINCH and the agent redraws its whole screen,
//! so the output revision moves for a moment. Read as fresh output, that
//! redraw upgraded the agent's idle prompt to `working` for a few seconds
//! after every `pane move` or split. The tracker is told the terminal's
//! size, as the scanner reads it from the terminal snapshot, and output that
//! only answers a size change is no working signal.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{DetectionInput, ManifestSet};

const TERMINAL: &str = "term_00000000000000000000000000000e05";
const RESIZE_AT_MS: u64 = 3_000;
const END_MS: u64 = 6_000;
const TICK_MS: u64 = 20;

/// Claude Code waiting at its own prompt.
const CLAUDE_IDLE: &str = "⏺ The capital of Australia is Canberra.\n\n\
     ────────────────────────────────\n❯ \n────────────────────────────────\n  ? for shortcuts\n";

#[test]
fn w5q_a_resize_redraw_does_not_read_as_working() {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == "claude").expect("bundled manifest");
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    let mut revision = 1;
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        let (cols, rows) = if ms < RESIZE_AT_MS { (120, 40) } else { (60, 40) };
        tracker.observe_size(TERMINAL, cols, rows, now);
        // The agent redraws after SIGWINCH: a burst of output over 200 ms
        // that ends on the same idle prompt.
        if [RESIZE_AT_MS, RESIZE_AT_MS + 20, RESIZE_AT_MS + 100, RESIZE_AT_MS + 200].contains(&ms) {
            revision += 1;
        }
        if !tracker.observe_revision(TERMINAL, revision, now) {
            continue;
        }
        let mut detection = manifest.detect(DetectionInput {
            screen: CLAUDE_IDLE,
            osc_title: "",
            osc_progress: "",
        });
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
