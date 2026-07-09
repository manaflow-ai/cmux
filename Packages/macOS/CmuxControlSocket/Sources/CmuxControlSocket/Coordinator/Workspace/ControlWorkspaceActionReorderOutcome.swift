/// The post-mutation snapshot of a `workspace.action` single-slot reorder
/// (`move_up` / `move_down`).
public enum ControlWorkspaceActionReorderOutcome: Sendable, Equatable {
    /// The workspace could not be located in its TabManager (legacy `not_found`,
    /// from the per-case `firstIndex` guard).
    case notFound
    /// The reorder applied; carries the workspace's resulting index, or `nil`
    /// when it could not be located after the move (legacy
    /// `v2OrNull(tabs.firstIndex(...))`).
    case reordered(index: Int?)
}
