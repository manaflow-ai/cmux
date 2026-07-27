import Foundation

@MainActor
extension TerminalNotificationStore {
    private static let workspaceContextMenuNotificationLimit = 50

    func notifications(forTabIds tabIds: [UUID]) -> [TerminalNotification] {
        guard !tabIds.isEmpty else { return [] }
        let targetIds = Set(tabIds)
        let sorted = notifications
            .filter { targetIds.contains($0.tabId) }
            .sorted(by: Self.notificationSortPrecedes)
        return Array(sorted.prefix(Self.workspaceContextMenuNotificationLimit))
    }
}
