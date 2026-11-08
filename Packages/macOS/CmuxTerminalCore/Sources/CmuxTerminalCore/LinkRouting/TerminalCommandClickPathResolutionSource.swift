/// Identifies the terminal-text source used to resolve a local path candidate.
public enum TerminalCommandClickPathResolutionSource: Equatable, Sendable {
    /// Ghostty's quick-look word supplied the candidate.
    case quicklook
    /// cmux's pointer-anchored terminal snapshot supplied the candidate.
    case snapshot
}
