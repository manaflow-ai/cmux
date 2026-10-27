import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs

extension TabItemMapping {
    /// The tab chip's presence dot (cx-gg84), only with the agent presence
    /// toggle on: the agent's color key and its spoken summary.
    func presence(_ tab: TabModel) -> TabPresence? {
        guard SidebarTunables.presenceDots.value,
              let sidebar = SidebarMapping.shared.presence([tab]).first else { return nil }
        return TabPresence(colorKey: sidebar.id, summary: sidebar.summary)
    }
}
