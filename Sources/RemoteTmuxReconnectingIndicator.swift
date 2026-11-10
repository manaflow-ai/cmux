import CmuxSidebar
import Foundation

extension Workspace {
    static let remoteTmuxReconnectingStatusKey = "remoteTmux.reconnecting"
}

/// Shows "Reconnecting" on a mirrored session's sidebar row once a reconnect has
/// lasted long enough for the frozen panes to be noticed, and removes it when the
/// connection is back or gone. A drop that recovers within the delay shows nothing.
///
/// The connection owns the reconnect: its state and when the reconnect began. This only
/// derives the row from them. Generic over its clock, and all of its timing comes from that
/// clock, so the delay counts from the drop even for a mirror that attached partway through.
@MainActor
final class RemoteTmuxReconnectingIndicator<C: Clock> where C.Duration == Duration {
    private let delay: Duration
    private let clock: C
    /// The presentation scheduled for the current reconnect, until it shows or is cancelled.
    private(set) var pendingPresentation: Task<Void, Never>?

    /// - Parameters:
    ///   - delay: How long a reconnect lasts before the row says so.
    ///   - clock: The clock reconnect start times come from and the delay is waited on.
    init(delay: Duration = .seconds(5), clock: C) {
        self.delay = delay
        self.clock = clock
    }

    /// Follows a connection state change. Reconnecting schedules the row for when the reconnect
    /// reaches `delay`, counted from `reconnectingSince`; any other state clears it.
    func connectionStateChanged(
        _ state: RemoteTmuxControlConnection.ConnectionState,
        reconnectingSince: C.Instant?,
        workspace: Workspace?
    ) {
        guard state == .reconnecting else {
            clear(workspace: workspace)
            return
        }
        guard pendingPresentation == nil,
              workspace?.statusEntries[Workspace.remoteTmuxReconnectingStatusKey] == nil else { return }
        let elapsed = reconnectingSince.map { $0.duration(to: clock.now) } ?? .zero
        let remaining = max(.zero, delay - elapsed)
        // Presentation timing, not synchronization: the delay decides only when the person is
        // told. Injected-clock sleep, cancelled by ``clear(workspace:)`` on every state change.
        pendingPresentation = Task { @MainActor [weak self, weak workspace, clock] in
            do {
                try await clock.sleep(for: remaining)
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

    /// Cancels a scheduled presentation and removes the row's entry.
    func clear(workspace: Workspace?) {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        workspace?.removeStatusEntry(forKey: Workspace.remoteTmuxReconnectingStatusKey)
    }
}

extension RemoteTmuxReconnectingIndicator where C == ContinuousClock {
    /// An indicator on the clock ``RemoteTmuxControlConnection/reconnectingSince`` comes from.
    convenience init(delay: Duration = .seconds(5)) {
        self.init(delay: delay, clock: ContinuousClock())
    }
}
