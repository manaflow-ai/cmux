import CmuxSidebar
import CmuxNotifications
import CmuxSwiftRender
import Foundation

@MainActor
final class CustomSidebarPaneDataContextCache {
    static let shared = CustomSidebarPaneDataContextCache()

    private var cachedKey: String?
    private var cachedContext: [String: SwiftValue]?

    func dataContext(
        now: Date,
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        build: () -> [String: SwiftValue]
    ) -> [String: SwiftValue] {
        let key = [
            String(Int(now.timeIntervalSince1970)),
            ObjectIdentifier(tabManager).debugDescription,
            tabManager.selectedTabId?.uuidString ?? "",
            tabManager.tabs.map { $0.id.uuidString }.joined(separator: ","),
            tabManager.tabs.map { $0.groupId?.uuidString ?? "-" }.joined(separator: ","),
            tabManager.workspaceGroups.map { "\($0.id.uuidString):\($0.name):\($0.isCollapsed)" }.joined(separator: ","),
            String(sidebarUnread.totalUnreadCount)
        ].joined(separator: "|")
        if key == cachedKey, let cachedContext {
            return cachedContext
        }
        let context = build()
        cachedKey = key
        cachedContext = context
        return context
    }
}
