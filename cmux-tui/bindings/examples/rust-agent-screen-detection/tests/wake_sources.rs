//! What wakes a scan: the terminal journal kinds the plugin follows, and the
//! terminal changes of `session.events`.
//!
//! The daemon writes a journal row for a terminal's live fact (an OSC 9;4
//! report, a moved last output time, a repeated status report) only while a
//! live journal stream follows `terminal.progress` or
//! `terminal.program_status`. This plugin must not be such a stream: with it
//! as the only follower the daemon commits nothing for a terminal that only
//! prints, and the plugin's wake for that terminal is the live `delta` of
//! `session.events`.

use cmux::{Cursor, ResourceChange, ResourceKind, ResourceReference, SessionDeltaEvent};
use cmux::{SessionEvent, TerminalId, WorkspaceId};
use cmux_agent_screen_detection::scanner::{journal_wake_kinds, terminal_wakes};

const TERMINAL: &str = "term_00000000000000000000000000000e06";
const WORKSPACE: &str = "ws_00000000000000000000000000000e06";

/// The daemon's kind rule for a journal stream filter: an exact kind, or
/// `family.*` for every kind under `family.`.
fn follows(kinds: &[String], kind: &str) -> bool {
    kinds.iter().any(|filter| match filter.strip_suffix('*') {
        Some(prefix) => kind.starts_with(prefix),
        None => filter == kind,
    })
}

#[test]
fn the_journal_filter_follows_no_live_fact_row() {
    let kinds = journal_wake_kinds();
    for kind in ["terminal.progress", "terminal.program_status"] {
        assert!(!follows(&kinds, kind), "the plugin follows `{kind}` rows: {kinds:?}");
    }
    for kind in [
        "terminal.input.write",
        "terminal.input.keys",
        "terminal.resized",
        "terminal.viewer.resize",
        "terminal.exited",
        "terminal.exit.detach",
        "terminal.close",
        "terminal.respawned",
        "workspace.create",
        "tab.move",
        "pane.split",
    ] {
        assert!(follows(&kinds, kind), "the plugin does not follow `{kind}` rows: {kinds:?}");
    }
}

fn delta(revision: u64, changes: Vec<ResourceChange>) -> SessionEvent {
    SessionEvent::Delta(SessionDeltaEvent {
        cursor: Cursor { generation: "1".into(), revision },
        // A live fact moves no revision.
        previous_revision: revision,
        revision,
        changes,
    })
}

#[test]
fn a_terminal_change_of_session_events_wakes_that_terminal() {
    let terminal = TerminalId::parse(TERMINAL).expect("a terminal id");
    let workspace = WorkspaceId::parse(WORKSPACE).expect("a workspace id");
    let event = delta(
        7,
        vec![
            ResourceChange::Delete {
                sequence: 0,
                resource: ResourceKind::Workspace,
                id: ResourceReference::Workspace(workspace),
            },
            ResourceChange::Delete {
                sequence: 1,
                resource: ResourceKind::Terminal,
                id: ResourceReference::Terminal(terminal),
            },
        ],
    );
    assert_eq!(terminal_wakes(&event), vec![TERMINAL.to_string()]);
    assert!(terminal_wakes(&delta(7, Vec::new())).is_empty());
}
