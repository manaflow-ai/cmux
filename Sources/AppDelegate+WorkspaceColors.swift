import Foundation

extension AppDelegate {
    /// The color each of `tabIds` shows in the sidebar, as a hex string; workspaces without a
    /// color, and ids no window holds, are left out.
    func workspaceColorHexByTabId(for tabIds: Set<UUID>) -> [UUID: String] {
        var colors: [UUID: String] = [:]
        for tabId in tabIds {
            guard let hex = tabManagerFor(tabId: tabId)?.tabs.first(where: { $0.id == tabId })?.customColor else {
                continue
            }
            colors[tabId] = hex
        }
        return colors
    }
}
