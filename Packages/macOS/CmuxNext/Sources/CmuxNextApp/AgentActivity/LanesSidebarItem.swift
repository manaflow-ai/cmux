import CmuxNextAgentActivity
import CmuxNextSidebar
import Foundation

/// The client-only Lanes item at the top of the sidebar (cx-v9k2f), shown while Labs preview
/// features are on: a quiet count of the acpmux sessions a person should look at (waiting on
/// them, failed or lost). A click opens the Agent Activity page with its lanes view.
@MainActor
enum LanesSidebarItem {
    static let id = LayoutItemID(LayoutItemID.transientPrefix + "lanes")

    static func item(lanes: AgentLaneStore) -> SidebarTransientItem {
        var info = SidebarItemInfo(title: LanesSidebarStrings.title, symbol: "list.bullet.rectangle")
        let count = lanes.attentionCount
        info.badge = count > 0 ? count : nil
        return SidebarTransientItem(id: id, info: info)
    }
}

nonisolated enum LanesSidebarStrings {
    static var title: String { String(localized: "lanes.sidebar.title", defaultValue: "Lanes", table: "SidebarSections", bundle: .module) }
}
