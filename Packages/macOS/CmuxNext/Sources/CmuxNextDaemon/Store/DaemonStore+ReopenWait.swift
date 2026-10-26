import CmuxNextCompat
import CmuxNextWakeups
import Foundation

extension DaemonStore {
    /// A restore reply can precede its workspace event. Wait for that exact
    /// workspace, with one cancellable deadline rather than polling the mirror.
    public func workspace(afterReopen id: ResourceID, timeout: Duration = .seconds(5),
                          clock: any Clock<Duration> = ContinuousClock()) async -> String? {
        if let workspace = workspace(resourceID: id) { return workspace.id }
        return await Deadline(timeout, clock: clock).value("DaemonStore.reopen") { await self.appearance(of: id) } ?? nil
    }

    private func appearance(of id: ResourceID) async -> String? {
        for await workspace in ObservationStream({ self.workspace(resourceID: id)?.id }) {
            if let workspace { return workspace }
        }
        return nil
    }
}
