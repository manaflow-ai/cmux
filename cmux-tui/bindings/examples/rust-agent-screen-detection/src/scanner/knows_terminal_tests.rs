//! `ScannerState::knows_terminal`: each kind of state that the detector holds
//! for a terminal makes that terminal known, and no other terminal.
//!
//! A pass does not read a listed terminal that ended unless the detector
//! knows it (`first_scan.rs`). If this function left out a kind of state,
//! the detector would not close what it holds of that kind for a terminal
//! that ended.

use std::time::Instant;

use cmux::{JournalIngress, ProcessInfoResult};
use serde_json::json;

use super::{CachedProcessGroup, CachedProcessInfo, PendingAppend, ScannerState};
use crate::background_agent::AgentJobTracker;
use crate::detect::{AgentState, ScreenDetectEmission};
use crate::process::ForegroundJob;

const HELD: &str = "terminal-held";
const OTHER: &str = "terminal-other";

fn tracker_entry(state: &mut ScannerState) {
    state.tracker.observe_size(HELD, 80, 24, Instant::now());
}

fn journal_request(state: &mut ScannerState) {
    let emission = ScreenDetectEmission {
        terminal_id: HELD.to_string(),
        agent: "example".to_string(),
        state: AgentState::Idle,
        matched_rule: None,
        visible_idle: true,
        visible_blocker: false,
        visible_working: false,
    };
    let ingress = JournalIngress {
        producer_id: "example".to_string(),
        manifest_version: 1,
        kind: "plugin.example.state".to_string(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: Vec::new(),
        sensitivity: None,
        payload: json!({}),
        causation_id: None,
        correlation_id: None,
    };
    let request = PendingAppend {
        emission,
        ingress,
        idempotency_key: "key".to_string(),
        attempts: 1,
        retry_not_before: Instant::now(),
    };
    state.pending_appends.insert(HELD.to_string(), request);
}

fn agent_job(state: &mut ScannerState) {
    state.agent_jobs.insert(HELD.to_string(), AgentJobTracker::default());
}

fn process_group_probe(state: &mut ScannerState) {
    let probe = CachedProcessGroup {
        pid: 1,
        foreground_name: None,
        executable: None,
        argv: Vec::new(),
        checked_at: Instant::now(),
        stream_revision: None,
        job: ForegroundJob { process_group_id: 1, processes: Vec::new() },
        authoritative: false,
        identified: false,
        acquisition_started_at: None,
    };
    state.process_cache.entries.insert(HELD.to_string(), probe);
}

fn process_info_probe(state: &mut ScannerState) {
    let probe = CachedProcessInfo {
        process: ProcessInfoResult {
            pid: 1,
            executable: None,
            argv: Vec::new(),
            cwd: None,
            foreground_cwd: None,
            foreground_executable: None,
            children: Vec::new(),
        },
        checked_at: Instant::now(),
        stream_revision: None,
        identified: false,
        acquisition_started_at: None,
    };
    state.process_info_cache.entries.insert(HELD.to_string(), probe);
}

/// Puts one entry of one kind of state for `HELD`.
type Hold = fn(&mut ScannerState);

/// Each kind of state of `ScannerState` that has a terminal id as its key,
/// with the function that puts one entry of that kind for `HELD`.
const KINDS: [(&str, Hold); 5] = [
    ("a tracker entry", tracker_entry),
    ("a journal request to send again", journal_request),
    ("an agent job", agent_job),
    ("a process group probe", process_group_probe),
    ("a process info probe", process_info_probe),
];

#[test]
fn a_new_scanner_state_knows_no_terminal() {
    let state = ScannerState::new();
    assert!(!state.knows_terminal(HELD), "a detector that has just started knows a terminal");
}

#[test]
fn each_kind_of_held_state_makes_its_terminal_known_and_no_other() {
    for (kind, hold) in KINDS {
        let mut state = ScannerState::new();
        hold(&mut state);
        assert!(
            state.knows_terminal(HELD),
            "the detector holds {kind} for a terminal and does not know that terminal"
        );
        assert!(
            !state.knows_terminal(OTHER),
            "{kind} for one terminal makes another terminal known"
        );
    }
}
