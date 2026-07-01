import Foundation

/// A single key cmux synthesizes into a Claude agent pane to drive its
/// compacted-session resume menu. Maps to cmux's named-key sender so libghostty
/// encodes the correct escape sequence for the pane's cursor mode.
public enum ClaudeResumeKey: String, Sendable {
    /// Move the highlighted menu row up.
    case up
    /// Move the highlighted menu row down.
    case down
    /// Confirm the highlighted menu row.
    case enter

    /// Name understood by `TerminalSurface.sendNamedKey` / `TerminalPanel.sendNamedKeyResult`.
    public var namedKey: String { rawValue }
}
