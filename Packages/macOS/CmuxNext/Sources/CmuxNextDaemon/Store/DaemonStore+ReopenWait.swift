import Foundation

extension DaemonStore {
    /// A restore reply can precede its workspace event. Waits for that exact
    /// workspace with a keyed wait (recipe R-wait, StoreWaiters): read again only
    /// when a workspace is keyed under `id`, its timeout on the main thread's one
    /// deadline queue, never a poll of the mirror.
    public func workspace(afterReopen id: ResourceID, timeout: Duration = .seconds(5)) async -> String? {
        await waitForWorkspace(resource: id, timeout: timeout)?.id
    }
}
