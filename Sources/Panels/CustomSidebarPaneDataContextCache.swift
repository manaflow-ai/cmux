import CmuxSidebar
import CmuxNotifications
import CmuxSwiftRender
import Foundation

@MainActor
final class CustomSidebarPaneDataContextCache {
    static let shared = CustomSidebarPaneDataContextCache()

    private var cachedKey: String?
    private var cachedContext: [String: SwiftValue]?
    private var cachedUnreadSnapshot: SidebarUnreadSnapshot?

    func dataContext(
        now: Date,
        refreshDate: Date,
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        build: () -> [String: SwiftValue]
    ) -> [String: SwiftValue] {
        let key = [
            // `now` feeds `clock`; `refreshDate` changes on every rebuild
            // request (a data change or the safety rebuild), so workspace
            // fields this key doesn't list still refresh.
            String(Int(now.timeIntervalSince1970)),
            String(refreshDate.timeIntervalSince1970),
            ObjectIdentifier(tabManager).debugDescription,
            tabManager.selectedTabId?.uuidString ?? "",
            tabManager.tabs.map { $0.id.uuidString }.joined(separator: ","),
            tabManager.tabs.map { $0.groupId?.uuidString ?? "-" }.joined(separator: ","),
            tabManager.workspaceGroups.map { "\($0.id.uuidString):\($0.name):\($0.isCollapsed)" }.joined(separator: ","),
            String(sidebarUnread.totalUnreadCount)
        ].joined(separator: "|")
        // Per-workspace and per-surface unread state is part of the context;
        // the total alone misses an unread moving between workspaces.
        let unreadSnapshot = sidebarUnread.snapshot
        if key == cachedKey, unreadSnapshot == cachedUnreadSnapshot, let cachedContext {
            return cachedContext
        }
        let context = build()
        cachedKey = key
        cachedUnreadSnapshot = unreadSnapshot
        cachedContext = context
        return context
    }
}
