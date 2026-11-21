import CmuxSidebar
import Foundation

extension Workspace {
    static let remoteTmuxReconnectingStatusKey = "remoteTmux.reconnecting"

    /// Puts back the status rows that mirror state owned elsewhere, after
    /// ``resetSidebarContext(reason:)`` removed every row: the failed-wake row while its banners
    /// are up, and the Reconnecting row while the session's connection is still reconnecting.
    func refreshDerivedStatusEntries() {
        refreshAgentWakeFailureStatusEntry()
        remoteTmuxSessionMirror?.refreshReconnectingStatus()
    }
}

extension RemoteTmuxSessionMirror {
    /// Derives the Reconnecting row again from the connection's current state.
    func refreshReconnectingStatus() {
        reconnectingIndicator.connectionStateChanged(
            connection.connectionState, reconnectingSince: connection.reconnectingSince, workspace: workspace)
    }
}

/// Shows "Reconnecting" on a mirrored session's sidebar row once a reconnect has
/// lasted long enough for the frozen panes to be noticed, and removes it when the
/// connection is back or gone. A drop that recovers within the delay shows nothing.
///
/// The connection owns the reconnect: its state and when the reconnect began. This only
/// derives the row from them, so the delay counts from the drop even for a mirror that
/// attached partway through, and a row cleared by a sidebar reset comes back. Nothing else
/// writes the row: ``Workspace/setStatusEntry(_:key:panelId:)`` and
/// ``Workspace/clearStatusEntry(key:panelId:)`` ignore its key.
@MainActor
final class RemoteTmuxReconnectingIndicator {
    private let delay: Duration
    /// The clock `reconnectingSince` is read against.
    private let now: () -> ContinuousClock.Instant
    /// The presentation scheduled for the current reconnect, until it shows or is cancelled.
    private(set) var pendingPresentation: Task<Void, Never>?

    /// - Parameters:
    ///   - delay: How long a reconnect lasts before the row says so.
    ///   - now: The clock `reconnectingSince` is measured on.
    init(delay: Duration = .seconds(5), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.delay = delay
        self.now = now
    }

    /// Follows a connection state change. Reconnecting schedules the row for when the reconnect
    /// reaches `delay`, counted from `reconnectingSince`; any other state clears it.
    func connectionStateChanged(
        _ state: RemoteTmuxControlConnection.ConnectionState,
        reconnectingSince: ContinuousClock.Instant?,
        workspace: Workspace?
    ) {
        guard state == .reconnecting else {
            clear(workspace: workspace)
            return
        }
        guard pendingPresentation == nil,
              workspace?.statusEntries[Workspace.remoteTmuxReconnectingStatusKey] == nil else { return }
        let clock = now
        let deadline = (reconnectingSince ?? clock()) + delay
        // Presentation timing only: it decides when the person is told, never what runs next.
        // ``RemoteTmuxRetryDelay`` is a one-shot timer that cancelling this task releases, and
        // ``clear(workspace:)`` cancels it on every state change and on detach. The time left is
        // read when the task runs, so a busy main actor does not add its wait to the delay.
        pendingPresentation = Task { @MainActor [weak self, weak workspace] in
            let remaining = max(.zero, clock().duration(to: deadline))
            await RemoteTmuxRetryDelay.wait(milliseconds: Int(remaining / .milliseconds(1)))
            guard !Task.isCancelled, let self, let workspace else { return }
            self.pendingPresentation = nil
            workspace.statusEntries[Workspace.remoteTmuxReconnectingStatusKey] = SidebarStatusEntry(
                key: Workspace.remoteTmuxReconnectingStatusKey,
                value: String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting"),
                icon: "arrow.triangle.2.circlepath",
                color: "#FF9500",
                timestamp: Date()
            )
        }
    }

    /// Cancels a scheduled presentation and removes the row's entry.
    func clear(workspace: Workspace?) {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        // Only this writes the key, and never for a pane, so there are no pane copies to remove.
        guard workspace?.statusEntries[Workspace.remoteTmuxReconnectingStatusKey] != nil else { return }
        workspace?.statusEntries.removeValue(forKey: Workspace.remoteTmuxReconnectingStatusKey)
    }
}
