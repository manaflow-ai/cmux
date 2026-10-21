public import CmuxNextDaemon
import CmuxNextCompat
import Foundation

extension DaemonStore {
    /// The first pane of workspace `key` once this store mirrors it (10 s at most): a workspace
    /// just created on its daemon (an agent chat's, a moved or adopted chat's) shows its tab there.
    public func mirroredPane(of key: WorkspaceKey) async -> PaneModel? {
        if let pane = firstPane(of: key) { return pane }
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        let mirrored = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await self.waitForPane(of: key) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        return mirrored ? firstPane(of: key) : nil
    }

    private func firstPane(of key: WorkspaceKey) -> PaneModel? {
        workspaces.first { $0.key == key }?.screens.first?.panes.first
    }

    private func waitForPane(of key: WorkspaceKey) async -> Bool {
        for await ready in ObservationStream({ self.firstPane(of: key) != nil }) where ready { return true }
        return false
    }
}
