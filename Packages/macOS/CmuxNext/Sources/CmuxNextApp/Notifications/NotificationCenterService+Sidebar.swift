import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign

/// What a notification does to the sidebar, as classic did (hq#1870 P1 #11):
/// its workspace moves to the top of the unpinned rows
/// (`notifications.attention.moveToTop`), and its hover card shows the text
/// while it is unread (its row too with `sidebar.workspaceRow.notification`
/// on; the text comes from the daemon store, seeded here with the
/// notifications posted before launch).
extension NotificationCenterService {
    /// Moves a notified workspace first in its group, else first among the
    /// loose rows, as Move Workspace to Top does. A pinned workspace, a muted one, one a window shows
    /// and every row of a session tree that keeps rows in place (`sidebar.rowOrder`) stay where they are.
    func moveToTop(_ workspace: WorkspaceModel) {
        guard let services, !workspace.pinned, !preferences.mutedWorkspaces.contains(workspace.id),
              !services.windows.controllers.contains(where: { $0.state.workspaceID == workspace.id }),
              let owner = services.windows.registry.value.owner(of: workspace.id),
              let controller = services.windows.controller(for: owner), controller.sidebar.model.priorityOrdering else { return }
        if WorkspaceVerbHandlers.place(workspace, .top(anchor: workspace.id), in: controller.sidebar, services: services) {
            note("moved \(workspace.id) to the top")
        }
    }

    /// Seeds the local daemon's notification texts from its ledger each time
    /// it connects, so rows show notifications posted before the app did.
    func followNotificationLedger(_ daemon: DaemonService) -> Task<Void, Never> {
        // task-owner: the caller stores it with the service's other tasks and cancels them together.
        Task {
            let ready = ObservationStream { () -> Bool in
                guard daemon.store.isLoaded, case .connected = daemon.store.connectionState else { return false }
                return true
            }
            for await connected in ready where connected {
                guard daemon.supports(DaemonCapabilities.shared.notificationAck) else { continue }
                daemon.send("list-notifications") { connection in
                    let entries = try await connection.notificationLedger()
                    await MainActor.run { daemon.store.seedNotificationTexts(entries) }
                }
            }
        }
    }
}
