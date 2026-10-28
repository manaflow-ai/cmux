import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextLayout

/// A person's New Agent Chat (Cmd-I, the menu, the palette) in a workspace (cx-ihyx2,
/// Lawrence 2026-10-14: "cmd i opens left docked chat in current workspace, seeded with
/// prompt such that the AI will work"): the agent chat docked left on the focused pane's
/// screen. The chat dock is the workspace's one chat (``ChatColumnPlacement``), so a second
/// Cmd-I focuses it and never opens a second dock or hides it: the chat is where the person
/// types, and a key that sometimes hides it would take the keyboard away. A screen that is
/// one lone chat (it docks when the first tool opens) is that chat: Cmd-I focuses it too.
/// Home's pinned chat dock (the Chief) is not that chat: from Home a new chat opens beside it.
/// A new chat starts with the selected tab's folder and selection (`agentSeedFromSelectedTab`)
/// and with the workspace context the page adds to its first prompt (`workspaceContext`).
@MainActor
enum DockedAgentChat {
    /// True when Cmd-I was handled here; false for scripts, explicit targets and daemons
    /// that cannot hold a chat or a chat dock (the caller opens a chat tab in the pane).
    static func open(from pane: PaneController, invocation: ActionInvocation, services: AppServices) -> Bool {
        guard invocation.origin == .user, invocation.target == nil, services.agentTabs.canHost(on: pane.daemon),
              let content = pane.workspace, content.daemon.supports(DaemonCapability.dockColumnRole.rawValue),
              let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return false }
        let columns = ChatColumnPlacement.columns(of: screen, containing: pane.layoutPaneID)
        // Home's pinned dock holds the Chief, not this workspace's chat: a new chat opens beside it
        // (`NewChatPlacement.besideDock`, 7b5ae883a3b), never a focus of the Chief.
        if let dock = columns.first(where: { $0.dock?.role == .agentChat && $0.dock?.isPinned != true }), let target = dock.root.panes.first {
            PaneHandlers.focus(target, in: content)
            return true
        }
        if ChatColumnPlacement.resolve(from: pane, services: services) == .dockChat {
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            return true
        }
        // A chat from an earlier Cmd-I is still on its way to its dock: that one is the chat.
        if !pane.pendingDock.isEmpty { return true }
        let source = pane.agentSeedFromSelectedTab() ?? AgentPaneSeedSource(AgentPaneSeed(cwd: pane.selectedTab?.cwd))
        source.workspaceContext = true
        return pane.openAgentTab(seed: source)
    }
}
