import Foundation

/// How a committed block of terminal text (no active modifier) should reach the
/// remote terminal.
///
/// The soft keyboard delivers committed text two ways that need different
/// transports: a single typed character (or Return) is per-key input, while a
/// multi-character block (system dictation, an autocorrect/predictive
/// replacement, or keyboard-inserted clipboard text) should arrive as one
/// *bracketed paste* so embedded newlines do not fragment into separate
/// Returns. ``TerminalCommitRouter`` picks between them.
public enum TerminalCommitRoute: Equatable, Sendable {
    /// Send as ordinary per-character input (preserves CR-for-Return and control
    /// byte semantics).
    case input
    /// Send as a single bracketed paste (multi-character block).
    case paste
}
