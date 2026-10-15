public import CmuxNextAgentActivity
public import CmuxNextSidebar
import Foundation

/// The client-only Lanes item at the top of the sidebar (cx-v9k2f), shown while Labs preview
/// features are on: a quiet count of the shown acpmux sessions a person should look at (waiting
/// on them, failed or lost), and none while no lane shows (`AgentLaneStore.shown`: this Mac's own
/// sessions unless the fleet Debug toggle is on). A click opens the Agent Activity page with its
/// lanes view.
extension SidebarTransientItem {
    public static let lanesID = LayoutItemID(LayoutItemID.transientPrefix + "lanes")

    @MainActor
    public static func lanes(_ store: AgentLaneStore) -> SidebarTransientItem? {
        guard !store.shown.isEmpty else { return nil }
        var info = SidebarItemInfo(title: AgentActivityLane.lanesTitle, symbol: "list.bullet.rectangle")
        let count = store.attentionCount
        info.badge = count > 0 ? count : nil
        return SidebarTransientItem(id: lanesID, info: info)
    }
}
