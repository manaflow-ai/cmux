//! Output on a screen that shows the agent at rest is not work.
//!
//! The tracker reads recent terminal output as a working signal: an idle
//! read taken while output is fresh becomes `working`, and one more read at
//! the end of the output window says `idle` again. That rule is for a read
//! that matched no rule of the manifest, where the output is the only fact.
//!
//! A read that matched the agent's own idle chrome (its prompt box, its
//! status footer), with no working rule and no blocker rule, has a fact of
//! the screen. One redraw of that screen (a clock in a status line, a
//! notice) is not a turn. Read as work, each redraw is one `working` report
//! and one `idle` report, and the daemon takes that pair as the end of a
//! turn.
//!
//! The same output rule also holds a `working` state through a read that
//! lands between two parts of a redraw. That hold stays: the last row here
//! guards it.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{DetectionInput, ManifestSet};

const TERMINAL: &str = "term_00000000000000000000000000000e07";
/// The one redraw. The read before it is then older than the tracker's 1 s
/// pace, so the tracker reads the screen at once, while the output is fresh.
const OUTPUT_AT_MS: u64 = 3_000;
const END_MS: u64 = 6_000;
const TICK_MS: u64 = 20;

/// Claude Code waiting at its own prompt.
const CLAUDE_IDLE: &str = "⏺ The capital of Australia is Canberra.\n\n\
     ────────────────────────────────\n❯ \n────────────────────────────────\n  ? for shortcuts\n";

/// Muse Code at rest: its `model · effort · cwd` footer and no interrupt hint.
const MUSE_IDLE: &str = "The capital of Australia is Canberra.\n\n  muse-1 · medium · ~/project\n";

/// Claude Code's screen while a command prints: no prompt box, no spinner,
/// no question. No rule of the manifest matches it.
const CLAUDE_NO_RULE: &str =
    "⏺ Running the build.\n\n   Compiling serde v1.0.219\n   Compiling regex v1.11.1\n";

/// What the bundled manifest of `agent` says of `screen`: the matched rule
/// and whether that rule is the agent's own idle chrome.
fn read(agent: &str, screen: &str) -> (Option<String>, bool) {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == agent).expect("bundled manifest");
    let detection = manifest.detect(DetectionInput { screen, osc_title: "", osc_progress: "" });
    (detection.matched_rule, detection.visible_idle)
}

/// Drives the tracker over a screen that stays the same, whose output
/// revision moves one time and whose size never changes. Answers each
/// emitted state with its time in ms from the start.
fn drive(agent: &str, screen: &str) -> Vec<(u64, AgentState)> {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == agent).expect("bundled manifest");
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        tracker.observe_size(TERMINAL, 120, 40, now);
        let revision = if ms < OUTPUT_AT_MS { 1 } else { 2 };
        if !tracker.observe_revision(TERMINAL, revision, now) {
            continue;
        }
        let mut detection =
            manifest.detect(DetectionInput { screen, osc_title: "", osc_progress: "" });
        tracker.apply_output_activity(TERMINAL, &mut detection, now);
        if let Some(emission) =
            tracker.record_detection_at(TERMINAL, Some((agent, detection)), now, false, false)
        {
            emitted.push((ms, emission.state));
        }
    }
    emitted
}

#[test]
fn one_redraw_of_claudes_idle_prompt_makes_no_report() {
    assert_eq!(read("claude", CLAUDE_IDLE), (Some("live_prompt_box".to_owned()), true));
    let emitted = drive("claude", CLAUDE_IDLE);
    assert_eq!(
        emitted,
        [(0_u64, AgentState::Idle)],
        "one redraw of the idle prompt made a report after the first idle"
    );
}

#[test]
fn one_redraw_of_muses_idle_footer_makes_no_report() {
    assert_eq!(read("muse", MUSE_IDLE), (Some("idle_status_fallback".to_owned()), true));
    let emitted = drive("muse", MUSE_IDLE);
    assert_eq!(
        emitted,
        [(0_u64, AgentState::Idle)],
        "one redraw of the idle footer made a report after the first idle"
    );
}

/// The output rule's own case stays: with no rule to say what the screen is,
/// fresh output is the only fact and reads as working until it is old.
#[test]
fn output_on_a_screen_with_no_rule_reads_as_working() {
    assert_eq!(read("claude", CLAUDE_NO_RULE), (None, false));
    let emitted = drive("claude", CLAUDE_NO_RULE);
    let states: Vec<AgentState> = emitted.iter().map(|(_, state)| *state).collect();
    assert_eq!(states, [AgentState::Idle, AgentState::Working, AgentState::Idle], "{emitted:?}");
    assert_eq!(emitted[1].0, OUTPUT_AT_MS, "the output reads as working at once: {emitted:?}");
}

/// Claude Code in a turn. Its spinner line redraws every 100 ms; a read
/// between two parts of a redraw can see the frame without that line.
fn claude_turn(frame: u64, spinner: bool) -> String {
    let glyph = ['✻', '✶', '✳', '✢', '·', '*'][frame as usize % 6];
    let line = if spinner {
        format!("{glyph} Thinking… ({}s · esc to interrupt)", frame / 10)
    } else {
        String::new()
    };
    format!(
        "⏺ Writing the essay about oak trees.\n\n{line}\n\n\
         ────────────────────────────────\n❯ \n────────────────────────────────\n  ? for shortcuts\n"
    )
}

/// The output's age holds a `working` state that a rule made. While a turn
/// runs the tracker reads the screen once a second without waiting for it to
/// be quiet, so a read can see the prompt box and no spinner. That read is
/// not the end of the turn: the output is fresh and the state before it is
/// `working`.
#[test]
fn a_read_between_two_parts_of_a_redraw_does_not_end_a_working_turn() {
    assert_eq!(
        read("claude", &claude_turn(0, true)),
        (Some("live_turn_working".to_owned()), false)
    );
    assert_eq!(read("claude", &claude_turn(0, false)), (Some("live_prompt_box".to_owned()), true));
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == "claude").expect("bundled manifest");
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    let mut reads = 0;
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        tracker.observe_size(TERMINAL, 120, 40, now);
        let frame = ms / 100;
        if !tracker.observe_revision(TERMINAL, frame + 1, now) {
            continue;
        }
        reads += 1;
        // The third read of the turn sees the frame without its spinner line.
        let screen = claude_turn(frame, reads != 3);
        let mut detection =
            manifest.detect(DetectionInput { screen: &screen, osc_title: "", osc_progress: "" });
        tracker.apply_output_activity(TERMINAL, &mut detection, now);
        if let Some(emission) =
            tracker.record_detection_at(TERMINAL, Some(("claude", detection)), now, false, false)
        {
            emitted.push((ms, emission.state));
        }
    }
    assert!(reads > 3, "the tracker read the screen {reads} times");
    assert_eq!(
        emitted,
        [(0_u64, AgentState::Working)],
        "a read of the prompt with no spinner ended a turn that still prints"
    );
}
