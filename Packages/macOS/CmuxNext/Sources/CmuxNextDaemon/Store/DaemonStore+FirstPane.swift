import CmuxNextCompat
import Foundation

extension DaemonStore {
    /// The first pane of workspace `key` once the mirror shows it, nil after
    /// `timeout`. A workspace made by key reaches the mirror after its reply.
    public func firstPane(mirroring key: WorkspaceKey, timeout: Duration = .seconds(10),
                          clock: any Clock<Duration> = ContinuousClock()) async -> PaneModel? {
        if let pane = firstPane(of: key) { return pane }
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        let mirrored = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await self.appearance(ofPaneIn: key) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await clock.sleep(for: timeout)
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

    private func appearance(ofPaneIn key: WorkspaceKey) async -> Bool {
        for await ready in ObservationStream({ self.firstPane(of: key) != nil }) where ready { return true }
        return false
    }
}
