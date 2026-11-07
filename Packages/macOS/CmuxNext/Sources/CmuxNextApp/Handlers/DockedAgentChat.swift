import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWindowRules

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
    /// The decision is Rust's (cmux-window-rules `chat::docked_open`); with no answer the caller opens the tab.
    static func open(from pane: PaneController, invocation: ActionInvocation, services: AppServices) -> Bool {
        let content = pane.workspace
        // The chat rules read topology only: a daemon without dock roles is never asked for a dock read.
        let dockRoles = content?.daemon.supports(DaemonCapability.dockColumnRole.rawValue) ?? false
        let facts = WindowRules.DockedOpen(
            user: invocation.origin == .user, targeted: invocation.target != nil, hasArguments: !invocation.arguments.isEmpty,
            canHost: services.agentTabs.canHost(on: pane.daemon), dockRoles: dockRoles,
            pane: pane.layoutPaneID.rawValue, read: dockRoles ? ChatColumnPlacement.read(pane, services: services) : nil,
            pendingDock: !pane.pendingDock.isEmpty)
        switch WindowRules().dockedOpen(facts) {
        case .notHandled?, nil:
            return false
        case .focus(let target)?:
            if let content { PaneHandlers.focus(LayoutPaneID(rawValue: target), in: content) }
            return true
        case .handled?:
            return true
        case .open?:
            let source = pane.agentSeedFromSelectedTab() ?? AgentPaneSeedSource(AgentPaneSeed(cwd: pane.selectedTab?.cwd))
            source.workspaceContext = true
            return pane.openAgentTab(seed: source)
        }
    }
}
