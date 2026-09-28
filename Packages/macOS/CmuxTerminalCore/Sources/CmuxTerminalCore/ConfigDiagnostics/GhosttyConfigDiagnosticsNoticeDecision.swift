/// What the app should do with its config-error notice after a config load.
public enum GhosttyConfigDiagnosticsNoticeDecision: Equatable, Sendable {
    /// Show (or replace the visible notice with) this notice.
    case present(GhosttyConfigDiagnosticsNotice)
    /// The errors were fixed; hide a visible notice.
    case dismiss
    /// Nothing changed since the last decision; leave the notice alone.
    case unchanged
}
