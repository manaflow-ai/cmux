/// Which way find steps through matches.
///
/// Ghostty numbers matches from the newest (bottom of the screen) to the
/// oldest (top of scrollback) and wraps at both ends.
public enum TerminalFindDirection: Sendable, Equatable {
    /// Toward older output (up into scrollback).
    case next
    /// Toward newer output (down to the prompt).
    case previous
}
