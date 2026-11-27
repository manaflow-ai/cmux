import Foundation

extension TabManager {
    /// Upper bound on how many background-prime workspaces may be force-mounted
    /// into the single main-window SwiftUI GraphHost at once.
    ///
    /// `reconcileMountedWorkspaceIds` raises the mount cap by
    /// `mountedBackgroundWorkspaceLoadIds.count`, so an unbounded set here would
    /// let a burst of eagerly-loaded (unfocused) workspaces mount every one of
    /// their pane subtrees simultaneously — making `GraphHost.flushTransactions()`
    /// O(number-of-hosted-panes) per runloop tick and pinning the main thread at
    /// 100%+ CPU (issue #7136). Background priming is processed serially (one
    /// awaited workspace at a time via a single-flight `.task(id:)`), so a small
    /// constant is sufficient; overflow workspaces still start their terminal
    /// surface through the headless startup-window path, so priming is deferred,
    /// never dropped.
    static let maxConcurrentBackgroundWorkspaceMounts = 2

    /// Returns whether `workspaceId` may occupy a background-prime mount slot.
    func shouldRetainBackgroundWorkspaceMount(for workspaceId: UUID) -> Bool {
        !mountedBackgroundWorkspaceLoadIds.contains(workspaceId)
            && mountedBackgroundWorkspaceLoadIds.count < Self.maxConcurrentBackgroundWorkspaceMounts
    }
}
