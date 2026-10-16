import CmuxCloud
import Foundation

extension TerminalNotificationStore {
    /// Both notification effect lanes use the same organization path. The caller
    /// already applied mute, cooldown, effect policy, and the reorder setting.
    func applySidebarOrdering(for notification: TerminalNotification, effects: TerminalNotificationPolicyEffects) {
        effects.applySidebarOrdering(
            defaults: .standard,
            workspaceId: notification.tabId,
            raiseCloudRow: { raiseCloudSidebarRow(for: notification) },
            moveLocalWorkspace: {
                AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                    .moveTabToTopForNotification(notification.tabId)
            }
        )
    }

    private func raiseCloudSidebarRow(for notification: TerminalNotification) {
        guard let key = notification.correlationKey,
              let source = CloudNotificationCorrelation.parse(key),
              let row = CloudNotificationSyncHub.shared.sync(machineID: source.machineID)?.rows
                .first(where: { $0.id == source.notificationID }),
              let terminalID = row.terminalID else { return }
        SurfaceCatalog.shared.raiseCloudSidebarNotification(machineID: source.machineID, terminalID: terminalID)
    }
}
