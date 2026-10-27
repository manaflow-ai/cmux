import CmuxNextCompat
import CmuxNextWakeups
import Foundation

extension DaemonStore {
    /// The first pane of workspace `key` once the mirror shows it, nil after
    /// `timeout`. A workspace made by key reaches the mirror after its reply.
    public func firstPane(mirroring key: WorkspaceKey, timeout: Duration = .seconds(10),
                          clock: any Clock<Duration> = ContinuousClock()) async -> PaneModel? {
        if let pane = firstPane(of: key) { return pane }
        let mirrored = await Deadline(timeout, clock: clock).value("DaemonStore.firstPane") {
            await self.appearance(ofPaneIn: key)
        } ?? false
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
