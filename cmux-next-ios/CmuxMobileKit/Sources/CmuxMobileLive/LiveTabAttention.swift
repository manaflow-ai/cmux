#if os(iOS)
import CmuxMobileModel
import Foundation

/// Jump to Latest Unread and Jump to Last Prompt from what each Mac's daemon tree and agent
/// reports already say (`list-workspaces` markers, `list-agents`, `agent-changed`): the
/// phone reads; it sends nothing new to the Mac.
extension LiveWorkspaceCreationBackend {
    /// The tab with the newest unread notification marker in this Mac's tree.
    func latestUnreadTab() -> TabAttentionPlace? {
        guard let tree = sync.tree else { return nil }
        return Self.latestUnread(in: tree)
    }

    /// The tab whose agent started a prompted turn last on this Mac.
    func lastPromptedTab() -> TabAttentionPlace? {
        guard let tree = sync.tree else { return nil }
        return Self.lastPrompted(in: tree, prompts: sync.lastPromptAt)
    }

    nonisolated static func latestUnread(in tree: DaemonTree) -> TabAttentionPlace? {
        TabAttentionPlace.newest(places(in: tree) { surface in
            guard let marker = tree.notificationMarkers[surface], marker.unread else { return nil }
            return (marker.createdAt, marker.notification)
        })
    }

    nonisolated static func lastPrompted(in tree: DaemonTree, prompts: [Int: Date]) -> TabAttentionPlace? {
        TabAttentionPlace.newest(places(in: tree) { surface in prompts[surface].map { ($0, 0) } })
    }

    /// Every tab of a Workspaces row `stamp` gives a time for, as a place. The Mac's Home
    /// workspace is not a row on the phone (its Home tab is its own), so its tabs are left out.
    private nonisolated static func places(in tree: DaemonTree, _ stamp: (Int) -> (Date?, Int)?) -> [TabAttentionPlace] {
        tree.workspaces.flatMap { workspace in
            workspace.tabs.compactMap { tab -> TabAttentionPlace? in
                guard let surface = tree.surfaces[tab.id], let stamped = stamp(surface) else { return nil }
                return TabAttentionPlace(workspaceID: workspace.id, tabID: tab.id, at: stamped.0, order: stamped.1)
            }
        }
    }
}

extension MultiMacWorkspaceBackend: TabAttentionBackend {
    public func latestUnreadTab(on macIDs: [String]) -> TabAttentionPlace? {
        TabAttentionPlace.newest(macIDs.compactMap { linked($0)?.latestUnreadTab() })
    }

    public func lastPromptedTab(on macIDs: [String]) -> TabAttentionPlace? {
        TabAttentionPlace.newest(macIDs.compactMap { linked($0)?.lastPromptedTab() })
    }
}
#endif

#if os(iOS)
extension MultiMacWorkspaceBackend: ChatSessionNaming {
    public func agentSessionID(of tab: WorkspaceTab, in workspace: Workspace) -> String? {
        linked(workspace.macID)?.sync.tree?.agentTabs[tab.id]?.session
    }
}
#endif
