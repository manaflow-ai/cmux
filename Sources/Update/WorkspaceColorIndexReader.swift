import SwiftUI

/// Hands its content the sidebar color of each workspace in `tabIds` (see
/// ``AppDelegate/workspaceColorHexByTabId(for:)``) and rebuilds that index when one of those
/// workspaces changes color, so an open notifications popover recolors its rows.
struct WorkspaceColorIndexReader<Content: View>: View {
    let tabIds: Set<UUID>
    @ViewBuilder let content: ([UUID: String]) -> Content

    @State private var colors: [UUID: String]?

    var body: some View {
        content(colors ?? Self.lookup(tabIds))
            .onAppear { refresh() }
            .onChange(of: tabIds) { _, _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceColorDidChange)) { notification in
                guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabIds.contains(workspaceId) else { return }
                refresh()
            }
    }

    private static func lookup(_ tabIds: Set<UUID>) -> [UUID: String] {
        AppDelegate.shared?.workspaceColorHexByTabId(for: tabIds) ?? [:]
    }

    private func refresh() {
        let next = Self.lookup(tabIds)
        if colors != next { colors = next }
    }
}
