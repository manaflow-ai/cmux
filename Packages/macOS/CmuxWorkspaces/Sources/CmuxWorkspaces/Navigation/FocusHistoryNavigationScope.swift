/// Controls which recorded focus changes back/forward navigation can visit.
public enum FocusHistoryNavigationScope: Equatable, Sendable {
    /// Navigate every recorded pane or tab focus change, including changes inside one workspace.
    case panesAndTabs
    /// Navigate only entries that move focus to a different workspace.
    case workspacesOnly
}
