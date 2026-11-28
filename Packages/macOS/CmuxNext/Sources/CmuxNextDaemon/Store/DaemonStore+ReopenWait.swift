import CmuxNextCompat
import Foundation

extension DaemonStore {
    /// A restore reply can precede its workspace event. Wait for that exact
    /// workspace, with one cancellable deadline rather than polling the mirror.
    public func workspace(afterReopen id: ResourceID, timeout: Duration = .seconds(5),
                          clock: any Clock<Duration> = ContinuousClock()) async -> String? {
        if let workspace = workspace(resourceID: id) { return workspace.id }
        // concurrency-allow: Observations ends on cancellation; the one-shot deadline bounds the wait.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await self.appearance(of: id) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a committed restore to reach the mirror.
                try? await clock.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    private func appearance(of id: ResourceID) async -> String? {
        for await workspace in ObservationStream({ self.workspace(resourceID: id)?.id }) {
            if let workspace { return workspace }
        }
        return nil
    }
}
