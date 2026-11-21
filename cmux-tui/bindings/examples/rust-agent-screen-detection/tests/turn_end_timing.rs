//! An interrupted turn reads idle within a second of its last redraw.
//!
//! Claude Code fires no `Stop` hook on Esc (manaflow-ai/cmux#36529), so the
//! detector's idle report is the only signal that the turn ended. The bundled
//! manifests read each screen and the tracker paces them, as the scanner
//! does: the spinner redraws every 100 ms, Esc redraws once, and the screen
//! goes quiet on the agent's own idle prompt.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{DetectionInput, ManifestSet};

const TERMINAL: &str = "term_00000000000000000000000000000e02";
const ESC_AT_MS: u64 = 5_000;
const END_MS: u64 = 9_000;
/// The scanner's wake granularity in this drive.
const TICK_MS: u64 = 20;

fn claude_working(frame: u64) -> String {
    let glyph = ['✻', '✶', '✳', '✢', '·', '*'][frame as usize % 6];
    format!(
        "⏺ Writing the essay about oak trees.\n\n{glyph} Thinking… ({}s · esc to interrupt)\n\n\
         ────────────────────────────────\n❯ \n────────────────────────────────\n  ? for shortcuts\n",
        frame / 10
    )
}

const CLAUDE_INTERRUPTED: &str = "⏺ Writing the essay about oak trees.\n  ⎿  Interrupted · What should Claude do instead?\n\n\
     ────────────────────────────────\n❯ \n────────────────────────────────\n  ? for shortcuts\n";

/// One screen and window title at `ms`: the turn before Esc, the agent's
/// idle prompt after it.
type Frame = fn(u64) -> (String, String);

fn claude(ms: u64) -> (String, String) {
    if ms < ESC_AT_MS {
        (claude_working(ms / 100), String::new())
    } else {
        (CLAUDE_INTERRUPTED.into(), String::new())
    }
}

fn codex(ms: u64) -> (String, String) {
    let screen = "› Explain this repository\n\n• I'll start by reading the README.\n".to_owned();
    if ms < ESC_AT_MS {
        let glyph = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴'][(ms / 100) as usize % 6];
        (screen, format!("{glyph} repo"))
    } else {
        (screen, "repo".into())
    }
}

/// Drives the tracker through one turn and Esc; answers when each state was
/// first emitted, in ms from the start.
fn drive(agent: &str, frame: Frame) -> Vec<(u64, AgentState, bool)> {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == agent).expect("bundled manifest");
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    let mut revision = 0;
    let mut last_frame = None;
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        // The spinner redraws every 100 ms; after Esc the screen redraws once.
        let (screen, title) = frame(ms);
        if last_frame.as_ref() != Some(&(screen.clone(), title.clone())) {
            revision += 1;
            last_frame = Some((screen.clone(), title.clone()));
        }
        if !tracker.observe_revision(TERMINAL, revision, now) {
            continue;
        }
        let mut detection = manifest.detect(DetectionInput {
            screen: &screen,
            osc_title: &title,
            osc_progress: "",
        });
        tracker.apply_output_activity(TERMINAL, &mut detection, now);
        if let Some(emission) =
            tracker.record_detection_at(TERMINAL, Some((agent, detection)), now, false, false)
        {
            emitted.push((ms, emission.state, emission.visible_idle));
        }
    }
    emitted
}

fn assert_idle_within_a_second(agent: &str, frame: Frame) {
    let emitted = drive(agent, frame);
    let working =
        emitted.iter().position(|(ms, state, _)| *state == AgentState::Working && *ms < ESC_AT_MS);
    assert!(working.is_some(), "{agent}: the running turn reads working: {emitted:?}");
    assert!(
        !emitted.iter().any(|(ms, state, _)| *state == AgentState::Idle
            && *ms > emitted[working.unwrap()].0
            && *ms < ESC_AT_MS),
        "{agent}: the running turn never reads idle: {emitted:?}"
    );
    let (idle_at, _, visible) = *emitted
        .iter()
        .find(|(ms, state, _)| *state == AgentState::Idle && *ms >= ESC_AT_MS)
        .unwrap_or_else(|| panic!("{agent}: Esc reads idle: {emitted:?}"));
    let latency = idle_at - ESC_AT_MS;
    println!("turn-end timing: {agent} reads idle {latency} ms after Esc");
    assert!(visible, "{agent}: the idle read is the agent's own prompt");
    assert!(latency <= 1_000, "{agent}: idle {latency} ms after Esc, over 1 s: {emitted:?}");
}

#[test]
fn claude_reads_idle_within_a_second_of_esc() {
    assert_idle_within_a_second("claude", claude);
}

#[test]
fn codex_reads_idle_within_a_second_of_esc() {
    assert_idle_within_a_second("codex", codex);
}
