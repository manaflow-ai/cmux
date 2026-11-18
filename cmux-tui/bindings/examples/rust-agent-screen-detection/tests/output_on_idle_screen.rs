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
//! lands between two parts of a redraw. That hold stays: one row here guards
//! it.
//!
//! Two more rows hold the edges of that rule. After a `blocked` report the
//! output still reads as work one time, and the state is then `idle`. And an
//! agent with no hook, whose turn starts on its idle prompt, reads `working`
//! at the first read that matches its working rule: at most one read
//! interval after the first frame that shows it, when that read sees the
//! working frame. A read that sees the prompt and no working frame adds one
//! interval, and a turn that ends before the next read gets no `working`
//! report. No row here drives those two cases.
//!
//! One row holds the one exception: an idle rule that no working rule of
//! its manifest is above. No working rule below it can win on that prompt,
//! so output still starts `working` there. Two more rows hold the
//! condition itself: one with manifests of the row's own (no working rule,
//! a lower one, a tie in each order, a higher one), and one that names the
//! bundled manifests where the condition is true.

use std::time::{Duration, Instant};

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{Detection, DetectionInput, ManifestSet, ScreenState};

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

/// Claude Code asking to run a command: a blocker, and no prompt box.
const CLAUDE_ASKS: &str = "⏺ Bash(rm -rf build)\n\n Bash command\n\n   rm -rf build\n\n \
     Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend\n";

/// The answer to the question: the idle prompt comes back in one redraw.
const ANSWER_AT_MS: u64 = 3_200;
/// One more redraw of the idle prompt, long after the answer.
const LATER_REDRAW_AT_MS: u64 = 5_000;

/// The first frame of a turn that shows the spinner: one tick after the read
/// of the turn's first output, the worst case for the next read.
const FIRST_WORKING_FRAME_MS: u64 = OUTPUT_AT_MS + TICK_MS;
/// The tracker's pace on a screen that does not go quiet. The row's own copy
/// of the crate's `MAX_EVAL_INTERVAL_MS`, which the crate does not export.
const READ_INTERVAL_MS: u64 = 1_000;

/// Drives the tracker over `frame`, which answers the screen and the output
/// revision at each time. Answers each emitted state with its time in ms
/// from the start.
fn drive_frames(agent: &str, frame: impl Fn(u64) -> (String, u64)) -> Vec<(u64, AgentState)> {
    let manifest =
        ManifestSet::bundled().manifests().find(|m| m.id() == agent).expect("bundled manifest");
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

/// After a `blocked` report the output's age still makes `working`: a person
/// answers the question, the agent goes on, and a read can see the prompt
/// before the spinner. Here the agent does not go on. That is one `working`
/// and one `idle` report; the state is then `idle`, and a later redraw of
/// the prompt makes no report.
#[test]
fn after_blocked_one_redraw_makes_at_most_one_working_and_one_idle_report() {
    assert_eq!(read("claude", CLAUDE_ASKS), (Some("bash_permission_prompt".to_owned()), false));
    let emitted = drive_frames("claude", |ms| {
        if ms < ANSWER_AT_MS {
            (CLAUDE_ASKS.to_owned(), 1)
        } else if ms < LATER_REDRAW_AT_MS {
            (CLAUDE_IDLE.to_owned(), 2)
        } else {
            (CLAUDE_IDLE.to_owned(), 3)
        }
    });
    assert_eq!(emitted.first(), Some(&(0_u64, AgentState::Blocked)), "{emitted:?}");
    let after: Vec<AgentState> =
        emitted.iter().filter(|(ms, _)| *ms >= ANSWER_AT_MS).map(|(_, state)| *state).collect();
    assert_eq!(
        after,
        [AgentState::Working, AgentState::Idle],
        "the reports from the answer on: {emitted:?}"
    );
}

/// An agent with no hook starts a turn. The turn's first output is a frame
/// with the prompt and no spinner; the tracker reads it at once and it stays
/// `idle`. The `working` report comes at the first read that matches the
/// working rule: at most one read interval after the first frame that shows
/// the spinner, when that read sees the spinner. Here each later read does.
/// The row does not hold a turn that ends before that read, or a read that
/// lands between two parts of a redraw: each such read adds one interval.
#[test]
fn the_start_of_a_turn_is_reported_within_one_read_interval() {
    let emitted = drive_frames("claude", |ms| {
        if ms < OUTPUT_AT_MS {
            (CLAUDE_IDLE.to_owned(), 1)
        } else if ms < FIRST_WORKING_FRAME_MS {
            (claude_turn(0, false), 2)
        } else {
            let frame = (ms - FIRST_WORKING_FRAME_MS) / 100;
            (claude_turn(frame, true), frame + 3)
        }
    });
    let states: Vec<AgentState> = emitted.iter().map(|(_, state)| *state).collect();
    assert_eq!(states, [AgentState::Idle, AgentState::Working], "{emitted:?}");
    let working_at = emitted[1].0;
    assert!(
        working_at >= FIRST_WORKING_FRAME_MS,
        "working at {working_at} ms, before a frame showed work: {emitted:?}"
    );
    let latency = working_at - FIRST_WORKING_FRAME_MS;
    println!("turn-start timing: claude reads working {latency} ms after the first working frame");
    assert!(
        latency <= READ_INTERVAL_MS,
        "working {latency} ms after the first working frame, over one read interval: {emitted:?}"
    );
}

/// Kiro at its empty prompt. Its manifest gives the rule of this placeholder
/// line a higher priority than each of its working rules.
const KIRO_IDLE: &str = "Kiro\n\n> ask a question or describe a task\n";

/// Where the idle rule is above each working rule of its manifest, no
/// working rule can win while that prompt shows. Output is then the only
/// fact of work on that screen, so it still starts `working` there, and the
/// read at the end of the output window says `idle` again.
#[test]
fn output_still_starts_work_where_the_idle_rule_is_above_each_working_rule() {
    assert_eq!(read("kiro", KIRO_IDLE), (Some("live_prompt_idle".to_owned()), true));
    let emitted = drive("kiro", KIRO_IDLE);
    assert_eq!(
        emitted,
        [
            (0_u64, AgentState::Idle),
            (OUTPUT_AT_MS, AgentState::Working),
            (OUTPUT_AT_MS + 300, AgentState::Idle)
        ],
        "output on a prompt that no working rule can out-rank did not read as work"
    );
}

/// The idle rule of the row's own manifests: the agent's idle chrome, at
/// priority 100.
const ROW_IDLE_RULE: &str = "[[rules]]\nid = \"prompt_idle\"\nstate = \"idle\"\npriority = 100\n\
     visible_idle = true\ncontains = [\"ready\"]\n";

/// A working rule of the row's own manifests at `priority`.
fn row_working_rule(priority: i32) -> String {
    format!(
        "[[rules]]\nid = \"spinner_working\"\nstate = \"working\"\npriority = {priority}\n\
         visible_working = true\ncontains = [\"busy\"]\n"
    )
}

/// What a manifest made of `rules`, in that order, says of `screen`.
fn detect_in(rules: &str, screen: &str) -> Detection {
    let source = format!("id = \"row-agent\"\n\n{rules}");
    let set = ManifestSet::from_sources(&[("row-agent", source.as_str())]).expect("row manifest");
    let manifest = set.manifests().next().expect("one manifest");
    manifest.detect(DetectionInput { screen, osc_title: "", osc_progress: "" })
}

/// The condition of the exception, by the manifest's priorities alone: the
/// matched rule is the idle chrome and no working rule has a higher
/// priority. A tie counts as the idle rule's.
#[test]
fn the_idle_rule_counts_as_above_when_no_working_rule_has_a_higher_priority() {
    let idle = "ready\n";
    let with_working = |priority: i32, working_first: bool| {
        let working = row_working_rule(priority);
        if working_first {
            format!("{working}{ROW_IDLE_RULE}")
        } else {
            format!("{ROW_IDLE_RULE}{working}")
        }
    };
    assert!(detect_in(ROW_IDLE_RULE, idle).idle_above_working, "no working rule");
    assert!(detect_in(&with_working(90, false), idle).idle_above_working, "a lower working rule");
    assert!(detect_in(&with_working(100, false), idle).idle_above_working, "a tie, idle first");
    assert!(detect_in(&with_working(100, true), idle).idle_above_working, "a tie, working first");
    assert!(
        !detect_in(&with_working(110, false), idle).idle_above_working,
        "a higher working rule"
    );
    assert!(!detect_in(ROW_IDLE_RULE, "no rule knows this\n").idle_above_working, "no match");

    // A screen that matches both rules of a tie: the rule listed first wins.
    // The field is the matched rule's, so it is true only when that is the
    // idle rule.
    let both = "ready\nbusy\n";
    let working_won = detect_in(&with_working(100, true), both);
    assert_eq!((working_won.state, working_won.idle_above_working), (ScreenState::Working, false));
    let idle_won = detect_in(&with_working(100, false), both);
    assert_eq!((idle_won.state, idle_won.idle_above_working), (ScreenState::Idle, true));
}

/// The bundled manifests where an idle rule with `visible_idle` has no
/// working rule above it. For each name in this list one redraw of the idle
/// prompt still makes a `working` and an `idle` report. A sync of the
/// manifests that changes a priority shows here.
#[test]
fn of_the_bundled_manifests_only_kiro_has_an_idle_rule_above_each_working_rule() {
    let input = DetectionInput { screen: "x\n", osc_title: "", osc_progress: "" };
    let mut names = Vec::new();
    for manifest in ManifestSet::bundled().manifests() {
        let rules = manifest.explain(input).evaluated_rules;
        let top_working = rules
            .iter()
            .filter(|rule| rule.state == ScreenState::Working)
            .map(|rule| rule.priority)
            .max();
        let above = rules.iter().any(|rule| {
            rule.visible_idle
                && rule.state == ScreenState::Idle
                && top_working.is_none_or(|working| rule.priority >= working)
        });
        if above {
            names.push(manifest.id().to_owned());
        }
    }
    assert_eq!(names, ["kiro"], "the bundled manifests with an idle rule above each working rule");
}
