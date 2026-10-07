/// Where an on-demand scrollback request stands (`terminal.history`).
public enum TerminalHistoryState: Sendable, Hashable {
    case idle
    case loading
    /// Older pages arrived (prepended to the scrollback).
    case loaded
    /// The host keeps no older history for this viewer, or does not serve it.
    case unavailable
}
