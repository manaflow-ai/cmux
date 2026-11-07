import CmuxSidebar
import Foundation

extension Workspace {
    static let remoteTmuxReconnectingStatusKey = "remoteTmux.reconnecting"
}

/// Shows "Reconnecting" on a mirrored session's sidebar row once a reconnect has
/// lasted long enough for the frozen panes to be noticed, and removes it when the
/// connection is back or gone. A drop that recovers within the delay shows nothing.
@MainActor
final class RemoteTmuxReconnectingIndicator {
    private let delay: Duration
    /// The presentation scheduled for the current reconnect, until it shows or is cancelled.
    private(set) var pendingPresentation: Task<Void, Never>?

    init(delay: Duration = .seconds(5)) {
        self.delay = delay
    }

    func connectionStateChanged(
        _ state: RemoteTmuxControlConnection.ConnectionState,
        workspace: Workspace?
    ) {
        guard state == .reconnecting else {
            clear(workspace: workspace)
            return
        }
        guard pendingPresentation == nil,
              workspace?.statusEntries[Workspace.remoteTmuxReconnectingStatusKey] == nil else { return }
        // Presentation timing, not synchronization: the delay decides only when the
        // person is told, and a state change cancels it.
        pendingPresentation = Task { @MainActor [weak self, weak workspace, delay] in
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let workspace else { return }
            self.pendingPresentation = nil
            workspace.setStatusEntry(
                SidebarStatusEntry(
                    key: Workspace.remoteTmuxReconnectingStatusKey,
                    value: String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting"),
                    icon: "arrow.triangle.2.circlepath",
                    color: "#FF9500",
                    timestamp: Date()
                ),
                key: Workspace.remoteTmuxReconnectingStatusKey,
                panelId: nil
            )
        }
    }

    func clear(workspace: Workspace?) {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        workspace?.removeStatusEntry(forKey: Workspace.remoteTmuxReconnectingStatusKey)
    }
}
