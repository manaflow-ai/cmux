public import CmuxNextAgentActivity
public import CmuxNextSidebar
import Foundation

/// The client-only Lanes item at the top of the sidebar (cx-v9k2f), shown while Labs preview
/// features are on: a quiet count of the acpmux sessions a person should look at (waiting on
/// them, failed or lost). A click opens the Agent Activity page with its lanes view.
@MainActor
public enum LanesSidebarItem {
    public static let id = LayoutItemID(LayoutItemID.transientPrefix + "lanes")

    public static func item(lanes: AgentLaneStore) -> SidebarTransientItem {
        var info = SidebarItemInfo(title: AgentActivityLane.lanesTitle, symbol: "list.bullet.rectangle")
        let count = lanes.attentionCount
        info.badge = count > 0 ? count : nil
        return SidebarTransientItem(id: id, info: info)
    }
}
