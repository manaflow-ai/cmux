import Foundation

extension DaemonStore {
    /// The first pane of workspace `key` once the mirror shows it, nil after
    /// `timeout`. A workspace made by key reaches the mirror after its reply.
    /// A keyed wait (recipe R-wait, StoreWaiters): read again only when that
    /// workspace is keyed or gains a pane, its timeout on the main thread's one
    /// deadline queue.
    public func firstPane(mirroring key: WorkspaceKey, timeout: Duration = .seconds(10)) async -> PaneModel? {
        await waitForFirstPane(workspace: key, timeout: timeout)
    }
}
