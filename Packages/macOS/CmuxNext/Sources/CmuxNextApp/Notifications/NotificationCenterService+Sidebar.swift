import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups

/// What a notification does to the sidebar, as classic did (hq#1870 P1 #11):
/// its workspace moves to the top of the unpinned rows
/// (`notifications.attention.moveToTop`), and its hover card shows the text
/// while it is unread (its row too with `sidebar.workspaceRow.notification`
/// on; the text comes from the daemon store, seeded here with the
/// notifications posted before launch).
extension NotificationCenterService {
    /// Moves a notified workspace first in its group, else first among the
    /// loose rows, as Move Workspace to Top does. A pinned workspace, a muted
    /// one and one a window shows stay where they are.
    func moveToTop(_ workspace: WorkspaceModel) {
        guard let services, DesignSettings.shared.attention.movesToTop, !workspace.pinned,
              !preferences.mutedWorkspaces.contains(workspace.id),
              !services.windows.controllers.contains(where: { $0.state.workspaceID == workspace.id }),
              let owner = services.windows.registry.value.owner(of: workspace.id),
              let controller = services.windows.controller(for: owner) else { return }
        if WorkspaceVerbHandlers.place(workspace, .top(anchor: workspace.id), in: controller.sidebar, services: services) {
            note("moved \(workspace.id) to the top")
        }
    }

    /// Seeds the local daemon's notification texts from its ledger each time
    /// it connects, so rows show notifications posted before the app did. The texts show on rows
    /// no input of the person's changed: the read and its reply run in the visible class.
    func followNotificationLedger(_ daemon: DaemonService) -> AnyObject {
        let work = self.work
        return ServiceObservation(.visible, owner: "notifications.ledger", on: work) { () -> Bool in
            guard daemon.store.isLoaded, case .connected = daemon.store.connectionState else { return false }
            return true
        } apply: { connected in
            guard connected, daemon.supports(DaemonCapabilities.notificationAck) else { return }
            daemon.send("list-notifications") { connection in
                let entries = try await connection.notificationLedger()
                work.postFromAnyThread(.visible, owner: "notifications.ledger.seed") { daemon.store.seedNotificationTexts(entries) }
            }
        }
    }
}
