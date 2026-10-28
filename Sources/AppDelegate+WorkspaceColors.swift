import Foundation

extension Notification.Name {
    /// Posted by a workspace whose color changed; `userInfo[GhosttyNotificationKey.tabId]` is its id.
    static let workspaceColorDidChange = Notification.Name("cmux.workspaceColorDidChange")
}

extension AppDelegate {
    /// The color each of `tabIds` shows in the sidebar, as a hex string; workspaces without a
    /// color, and ids no window holds, are left out.
    ///
    /// One pass over each window's workspaces, so a render with many notifications costs the
    /// same as one with a single notification.
    func workspaceColorHexByTabId(for tabIds: Set<UUID>) -> [UUID: String] {
        guard !tabIds.isEmpty else { return [:] }
        var colors: [UUID: String] = [:]
        var found: Set<UUID> = []

        func collect(from manager: TabManager) {
            for tab in manager.tabs where tabIds.contains(tab.id) && found.insert(tab.id).inserted {
                if let hex = tab.customColor { colors[tab.id] = hex }
            }
        }

        for snapshot in mainWindowRouteSnapshots() {
            collect(from: snapshot.tabManager)
            if found.count == tabIds.count { return colors }
        }
        if let tabManager { collect(from: tabManager) }
        return colors
    }
}
