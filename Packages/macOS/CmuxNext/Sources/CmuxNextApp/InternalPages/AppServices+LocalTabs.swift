import CmuxNextBridge
import CmuxNextDaemon

/// Session-local tabs a pane lists after its daemon and browser tabs: agent
/// chats (`AgentTabStore`) and internal pages (`InternalPageTabStore`).
extension AppServices {
    /// Strip items of `paneKey`'s agent and page tabs, in that order.
    func localTabItems(in paneKey: String, hiding closed: Set<String>) -> [StripTabItem] {
        agentTabs.tabIDs(in: paneKey).filter { !closed.contains($0) }.map(agentTabs.stripItem)
            + pages.tabIDs(in: paneKey).filter { !closed.contains($0) }.map(pages.stripItem)
    }

    /// Closes an agent or page tab. False for any other tab.
    func closeLocalTab(_ key: String) -> Bool {
        if key.hasPrefix(LocalAgentTab.prefix) {
            agentTabs.close(key)
        } else if key.hasPrefix(LocalPageTab.prefix) {
            pages.close(key)
        } else {
            return false
        }
        cache.release(key)
        return true
    }

    /// Closes the agent and page tabs of panes `store` no longer lists.
    func closeGoneLocalTabs(in store: DaemonStore) {
        agentTabs.closeGonePanes(in: store)
        pages.closeGonePanes(in: store)
    }
}
