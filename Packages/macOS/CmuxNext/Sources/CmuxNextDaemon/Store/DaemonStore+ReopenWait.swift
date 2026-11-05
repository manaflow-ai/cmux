import CmuxNextCompat
import Foundation

extension DaemonStore {
    /// A restore reply can precede its workspace event. Wait for that exact
    /// workspace, with one cancellable deadline rather than polling the mirror.
    ///
    /// The mirror gives the answer. The wait ends when it hears the workspace, at the deadline or
    /// on cancellation, and then reads the mirror once more here, on the main actor. The deadline's
    /// child runs off the main actor, so on a busy main actor it can end the wait while the re-read
    /// that would hear a workspace already in the mirror still waits for its turn.
    public func workspace(afterReopen id: ResourceID, timeout: Duration = .seconds(5),
                          clock: any Clock<Duration> = ContinuousClock()) async -> String? {
        if let workspace = workspace(resourceID: id) { return workspace.id }
        // The miss and the tracking that hears the workspace arrive are one read in this turn: the
        // wait listens before its deadline starts, with no main-actor hop to start listening.
        let (found, later) = ObservationStream.current { self.reopenedWorkspace(id) }
        if let found { return found }
        // concurrency-allow: Observations ends on cancellation; the one-shot deadline bounds the wait.
        let heard = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await workspace in later { if let workspace { return workspace } }
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
        return heard ?? reopenedWorkspace(id)
    }

    /// The store key of the workspace whose public id is `id`. A miss of the index also reads each
    /// workspace's resource id: one set on a workspace already listed changes no list a tracked read
    /// of the index would observe. Only the reopen wait pays that walk, and only while it waits.
    private func reopenedWorkspace(_ id: ResourceID) -> String? {
        workspace(resourceID: id)?.id ?? workspaces.first { $0.resourceID == id }?.id
    }
}
