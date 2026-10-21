public import CmuxNextDaemon

/// Finds the `cmux status run`s that finish between two looks at the
/// workspaces' status entries. Pure.
public struct FinishedStatusRunTracker: Sendable {
    public init() {}

    /// The runs that finished since the last update.
    public mutating func update(_ statuses: [WorkspaceStatus]) -> [FinishedStatusRun] {
        []
    }
}
