//! The journal kinds that wake a scan.
//!
//! This file uses the standard library only: a test of the cmux-tui
//! workspace compiles it too (`crates/cmux-tui/tests/detector_journal_filter.rs`),
//! to send this list to a daemon and to compare its length with the bound
//! of the request catalog.

/// The `terminal.<family>` journal kinds that wake a scan: every family of
/// the daemon's terminal operations and terminal facts but `progress` and
/// `program_status` ([`journal_wake_kinds`]).
const TERMINAL_WAKE_FAMILIES: [&str; 50] = [
    "adopt",
    "adopt_hosts",
    "attach",
    "changed",
    "clear",
    "close",
    "closed",
    "copy",
    "cwd",
    "decrease",
    "exit",
    "exited",
    "fill",
    "focus",
    "get",
    "history",
    "increase",
    "input",
    "input_busy",
    "keep",
    "launch",
    "link",
    "list",
    "move",
    "output",
    "output_read",
    "persistence",
    "process",
    "project",
    "renderer_grant",
    "reset",
    "resized",
    "respawn",
    "respawn_lost",
    "respawned",
    "run",
    "runtime",
    "screen",
    "scroll",
    "scrollback",
    "select",
    "send",
    "set",
    "split",
    "state",
    "tail_pin",
    "viewer",
    "viewport",
    "wait",
    "wait_exit",
];

/// The journal kinds that wake a scan.
///
/// Every change of a terminal's record comes from `session.events`
/// (`scanner::terminal_wakes`): a durable edge as a committed delta, a live fact (an
/// OSC 9;4 report, a moved last output time, a repeated status report) as a
/// delta that moves no revision. So no kind here matches `terminal.progress`
/// or `terminal.program_status`: the daemon writes a journal row for a live
/// fact only while a journal stream follows those kinds, and this plugin must
/// not be the reason for one commit per printing terminal each 5 s. The
/// journal has no "all but" filter, so the terminal kinds are named by family.
pub fn journal_wake_kinds() -> Vec<String> {
    let terminal = TERMINAL_WAKE_FAMILIES
        .iter()
        .flat_map(|family| [format!("terminal.{family}"), format!("terminal.{family}.*")]);
    let topology = ["workspace.*", "tab.*", "pane.*", "screen.*"].into_iter().map(String::from);
    terminal.chain(topology).collect()
}
