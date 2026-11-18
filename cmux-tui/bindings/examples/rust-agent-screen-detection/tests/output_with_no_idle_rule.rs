//! One redraw of a screen at rest is not a turn, also for an agent whose
//! manifest has no rule that reads `idle`.
//!
//! A read that matches no rule of its manifest answers `idle`, and the
//! tracker then takes recent terminal output as a working signal: the read
//! becomes `working`, and one more read at the end of the output window says
//! `idle` again. For an agent whose manifest has an idle rule, a read with no
//! match says that the agent's prompt is not on the screen. For an agent
//! whose manifest has no idle rule, each read of the screen at rest is a read
//! with no match. One redraw of that screen (a clock in a status line, a
//! notice) is then one `working` report and one `idle` report, and the daemon
//! takes that pair as the end of a turn.
//!
//! The rows: which bundled manifests have no idle rule; one redraw of their
//! screen at rest makes no report; output that goes on still reads as
//! `working` within one read interval.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{
    CompiledManifest, DetectionInput, ManifestSet, ScreenState,
};

const TERMINAL: &str = "term_00000000000000000000000000000e09";
/// The first output. The read before it is then older than the tracker's 1 s
/// pace, so the tracker reads the screen at once, while the output is fresh.
const OUTPUT_AT_MS: u64 = 3_000;
/// The last output of the row whose output goes on.
const LAST_OUTPUT_MS: u64 = 5_000;
const END_MS: u64 = 9_000;
const TICK_MS: u64 = 20;
/// The tracker's pace on a screen that does not go quiet. The row's own copy
/// of the crate's `MAX_EVAL_INTERVAL_MS`, which the crate does not export.
const READ_INTERVAL_MS: u64 = 1_000;

/// The ids of the bundled manifests that have no rule with the state `idle`,
/// in the order of their names.
const NO_IDLE_RULE: [&str; 10] =
    ["agy", "copilot", "cursor", "droid", "gemini", "kilo", "kimi", "opencode", "pi", "qodercli"];

/// A screen at rest with a clock in its status line. No rule of a manifest
/// in [`NO_IDLE_RULE`] matches it.
fn rest_screen(minute: u64) -> String {
    format!("The capital of Australia is Canberra.\n\n  14:{minute:02}  ~/project\n")
}

/// A screen while a command prints. No rule of a manifest in
/// [`NO_IDLE_RULE`] matches it.
fn printing_screen(line: u64) -> String {
    format!("Running the build.\n\n   Compiling crate {line}\n")
}

/// The screen and the output revision of the row with one redraw: the clock
/// moves one minute at [`OUTPUT_AT_MS`].
fn one_redraw(ms: u64) -> (String, u64) {
    if ms < OUTPUT_AT_MS { (rest_screen(5), 1) } else { (rest_screen(6), 2) }
}

/// The screen and the output revision of the row whose output goes on: one
/// line each 100 ms from [`OUTPUT_AT_MS`] to [`LAST_OUTPUT_MS`].
fn output_that_goes_on(ms: u64) -> (String, u64) {
    if ms < OUTPUT_AT_MS {
        return (rest_screen(5), 1);
    }
    let line = (ms.min(LAST_OUTPUT_MS) - OUTPUT_AT_MS) / 100;
    (printing_screen(line), 2 + line)
}

fn bundled(agent: &str) -> &'static CompiledManifest {
    ManifestSet::bundled().manifests().find(|m| m.id() == agent).expect("bundled manifest")
}

/// Whether `screen` is a read with no match that answers `idle`.
fn reads_idle_with_no_rule(manifest: &CompiledManifest, screen: &str) -> bool {
    let detection = manifest.detect(DetectionInput { screen, osc_title: "", osc_progress: "" });
    detection.matched_rule.is_none() && detection.state == ScreenState::Idle
}

/// Drives the tracker over `frame`, which answers the screen and the output
/// revision at each time. The size never changes. Answers each emitted state
/// with its time in ms from the start.
fn drive(agent: &str, frame: impl Fn(u64) -> (String, u64)) -> Vec<(u64, AgentState)> {
    let manifest = bundled(agent);
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    let mut emitted = Vec::new();
    for ms in (0..END_MS).step_by(TICK_MS as usize) {
        let now = start + Duration::from_millis(ms);
        tracker.observe_size(TERMINAL, 120, 40, now);
        let (screen, revision) = frame(ms);
        if !tracker.observe_revision(TERMINAL, revision, now) {
            continue;
        }
        let mut detection =
            manifest.detect(DetectionInput { screen: &screen, osc_title: "", osc_progress: "" });
        tracker.apply_output_activity(TERMINAL, &mut detection, now);
        if let Some(emission) =
            tracker.record_detection_at(TERMINAL, Some((agent, detection)), now, false, false)
        {
            emitted.push((ms, emission.state));
        }
    }
    emitted
}

/// The bundled manifests with no rule that reads `idle`. A sync of the
/// manifests that gives one of them an idle rule, or adds a manifest with
/// none, shows here.
#[test]
fn ten_bundled_manifests_have_no_rule_that_reads_idle() {
    let input = DetectionInput { screen: "x\n", osc_title: "", osc_progress: "" };
    let mut names = Vec::new();
    for manifest in ManifestSet::bundled().manifests() {
        let rules = manifest.explain(input).evaluated_rules;
        if !rules.iter().any(|rule| rule.state == ScreenState::Idle) {
            names.push(manifest.id().to_owned());
        }
    }
    names.sort();
    assert_eq!(names, NO_IDLE_RULE, "the bundled manifests with no idle rule");
}

/// The screen at rest redraws one time: its clock moves one minute. That is
/// no turn, so the first `idle` report is the only one.
#[test]
fn one_redraw_of_a_screen_at_rest_makes_no_report_where_no_rule_reads_idle() {
    let mut with_a_report = Vec::new();
    for agent in NO_IDLE_RULE {
        let manifest = bundled(agent);
        assert!(reads_idle_with_no_rule(manifest, &rest_screen(5)), "{agent}: before the redraw");
        assert!(reads_idle_with_no_rule(manifest, &rest_screen(6)), "{agent}: after the redraw");
        let emitted = drive(agent, one_redraw);
        if emitted != [(0_u64, AgentState::Idle)] {
            with_a_report.push((agent, emitted));
        }
    }
    assert!(
        with_a_report.is_empty(),
        "one redraw of the screen at rest made a report after the first idle: {with_a_report:?}"
    );
}

/// Output that goes on is work: a command prints one line each 100 ms for 2
/// s, and no rule of the manifest matches the screen. The agent reads
/// `working` at most one read interval after the first output, and `idle`
/// only after the last one.
#[test]
fn output_that_goes_on_reads_as_working_where_no_rule_reads_idle() {
    for agent in NO_IDLE_RULE {
        let manifest = bundled(agent);
        assert!(reads_idle_with_no_rule(manifest, &printing_screen(0)), "{agent}: the first line");
        assert!(reads_idle_with_no_rule(manifest, &printing_screen(20)), "{agent}: the last line");
        let emitted = drive(agent, output_that_goes_on);
        let states: Vec<AgentState> = emitted.iter().map(|(_, state)| *state).collect();
        assert_eq!(
            states,
            [AgentState::Idle, AgentState::Working, AgentState::Idle],
            "{agent}: {emitted:?}"
        );
        assert!(
            emitted[1].0 <= OUTPUT_AT_MS + READ_INTERVAL_MS,
            "{agent}: `working` came more than one read interval after the first output: {emitted:?}"
        );
        assert!(
            emitted[2].0 > LAST_OUTPUT_MS,
            "{agent}: `idle` came before the last output: {emitted:?}"
        );
    }
}
