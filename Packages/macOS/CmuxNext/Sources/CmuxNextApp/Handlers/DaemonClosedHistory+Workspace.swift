import CmuxNextDaemon
import Foundation

extension DaemonClosedHistory {
    /// A restore reply can precede its workspace event. Wait for that exact
    /// workspace, with one cancellable deadline rather than polling the mirror.
    static func workspaceAfterReopen(_ id: ResourceID, in store: DaemonStore,
                                     timeout: Duration = .seconds(5),
                                     clock: any Clock<Duration> = ContinuousClock()) async -> String? {
        if let workspace = store.workspace(resourceID: id) { return workspace.id }
        // concurrency-allow: Observations ends on cancellation; the one-shot deadline bounds the wait.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                for await workspace in Observations({ store.workspace(resourceID: id)?.id }) {
                    if let workspace { return workspace }
                }
                return nil
            }
            group.addTask {
                // wakeup-allow: one-shot deadline for a committed restore to reach the mirror.
                try? await clock.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}
