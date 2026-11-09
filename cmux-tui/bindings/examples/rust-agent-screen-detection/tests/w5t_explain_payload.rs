//! What a screen report tells `cmux agent explain` (bench round 4, herdr
//! `agent explain`): the rule that matched, the manifest version and source
//! it came from, what the state rests on (`basis`), and the screen text the
//! rule matched (`evidence`). The journal record is `sensitive`, so the text
//! stays with local clients.

use std::time::Instant;

use cmux_agent_screen_detection::detect::{AgentState, ScreenDetectTracker};
use cmux_agent_screen_detection::manifest::{DetectionInput, ManifestSet};
use cmux_agent_screen_detection::scanner::native_payload;

const TERMINAL: &str = "term_00000000000000000000000000000e5a";

const CLAUDE_BASH_PERMISSION: &str = "\
Bash command

  rm -rf build

Do you want to proceed?
❯ 1. Yes
  2. No

Esc to cancel · Tab to amend
";

fn claude() -> &'static cmux_agent_screen_detection::manifest::CompiledManifest {
    ManifestSet::bundled().manifests().find(|m| m.id() == "claude").expect("bundled claude")
}

fn input(screen: &str) -> DetectionInput<'_> {
    DetectionInput { screen, osc_title: "", osc_progress: "" }
}

#[test]
fn w5t_a_screen_report_names_its_rule_manifest_basis_and_matched_text() {
    let manifest = claude();
    let mut tracker = ScreenDetectTracker::default();
    let detection = manifest.detect(input(CLAUDE_BASH_PERMISSION));
    let emission = tracker
        .record_detection(TERMINAL, Some((manifest.id(), detection)))
        .expect("the first report is emitted");
    assert_eq!(emission.state, AgentState::Blocked);
    let native = native_payload(&emission);
    assert_eq!(native["matched_rule"], "bash_permission_prompt", "{native}");
    assert_eq!(native["basis"], "rule", "{native}");
    let version = manifest.version().map(ToString::to_string).expect("claude has a version");
    assert_eq!(native["manifest"]["version"], version.as_str(), "{native}");
    assert_eq!(native["manifest"]["source"], "bundled", "{native}");
    let evidence = native["evidence"].as_str().expect("the matched screen text");
    assert!(evidence.contains("Do you want to proceed?"), "{evidence}");
    assert!(evidence.len() <= 400, "{evidence}");
}

#[test]
fn w5t_an_unmatched_screen_says_idle_fallback_and_carries_no_text() {
    let manifest = claude();
    let mut tracker = ScreenDetectTracker::default();
    let detection = manifest.detect(input("plain output\n"));
    let emission = tracker
        .record_detection(TERMINAL, Some((manifest.id(), detection)))
        .expect("the first report is emitted");
    assert_eq!(emission.state, AgentState::Idle);
    let native = native_payload(&emission);
    assert_eq!(native["basis"], "idle_fallback", "{native}");
    assert!(native["matched_rule"].is_null(), "{native}");
    assert!(native.get("evidence").is_none_or(serde_json::Value::is_null), "{native}");
    assert_eq!(native["manifest"]["source"], "bundled", "{native}");
}

#[test]
fn w5t_output_activity_and_process_exit_name_their_basis() {
    let manifest = claude();
    let mut tracker = ScreenDetectTracker::default();
    let start = Instant::now();
    // Output moves on an idle-looking screen: the plugin reports working.
    tracker.observe_revision(TERMINAL, 1, start);
    tracker.observe_revision(TERMINAL, 2, start);
    let mut detection = manifest.detect(input("plain output\n"));
    tracker.apply_output_activity(TERMINAL, &mut detection, start);
    let emission = tracker
        .record_detection(TERMINAL, Some((manifest.id(), detection)))
        .expect("the first report is emitted");
    assert_eq!(emission.state, AgentState::Working);
    let native = native_payload(&emission);
    assert_eq!(native["basis"], "output_activity", "{native}");
    // The agent's process leaves: the report ends the session.
    let ended = tracker.record_detection(TERMINAL, None).expect("the end is emitted");
    assert_eq!(ended.state, AgentState::Done);
    let native = native_payload(&ended);
    assert_eq!(native["basis"], "process_exit", "{native}");
    assert!(native["manifest"].is_null(), "{native}");
}
