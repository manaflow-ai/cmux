import Foundation

extension TerminalNotificationStore {
    /// Both notification effect lanes use the same organization path. The caller
    /// already applied mute, cooldown, effect policy, and reorder-on-notification.
    func reorderSidebars(for notification: TerminalNotification) {
        AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
            .moveTabToTopForNotification(notification.tabId)
        guard let key = notification.correlationKey,
              let source = CloudNotificationCorrelation.parse(key),
              let row = CloudNotificationSyncHub.shared.sync(machineID: source.machineID)?.rows
                .first(where: { $0.id == source.notificationID }),
              let terminalID = row.terminalID else { return }
        SurfaceCatalog.shared.raiseCloudSidebarNotification(machineID: source.machineID, terminalID: terminalID)
    }
}
