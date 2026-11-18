//! The terminals that a connection pass reads before its first wait.
//!
//! A pass opens its two wake streams, reads the list of the terminals of the
//! session (one request), and then reads listed terminals one by one (one
//! request each) before it waits for a wake. [`first_scan_ids`] says which
//! of the listed terminals get such a read.
//!
//! This file uses the standard library only: a test of the cmux-tui
//! workspace compiles it too (`crates/cmux-tui/tests/detector_first_scan.rs`)
//! and makes the reads that it names against a real owner.

/// One row of the terminal list of a pass, as the first scan sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ListedTerminal<'a> {
    /// The id of the terminal.
    pub id: &'a str,
    /// The lifecycle of the row is `exited`: the process of the terminal
    /// ended and the owner keeps the row.
    pub exited: bool,
    /// The detector holds state for the id: a tracker entry, a probe cache,
    /// an agent job, or a journal request that it must send again.
    pub known: bool,
}

/// The ids that the pass reads before its first wait, in the order of
/// `listed`: each listed terminal but one that ended and for which the
/// detector holds no state.
///
/// A read of such a terminal gives the row that the list gave, and the
/// detector has nothing to close for it. If the terminal gets a new process
/// under the same id, the owner sends an upsert of the terminal on the
/// session event stream, which the pass opened before it read the list: that
/// wake gives the terminal its read.
pub fn first_scan_ids<'a>(listed: impl IntoIterator<Item = ListedTerminal<'a>>) -> Vec<&'a str> {
    listed
        .into_iter()
        .filter(|terminal| !terminal.exited || terminal.known)
        .map(|terminal| terminal.id)
        .collect()
}
