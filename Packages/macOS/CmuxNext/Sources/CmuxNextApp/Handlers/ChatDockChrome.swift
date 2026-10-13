import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// The agent chat's pane chrome (lawrence-call-1006 D): the chat dock (the
/// dock column with the agent chat role) shows no tab strip by default,
/// and neither does a chat alone on its screen, which docks when the first
/// tool opens (``ChatColumnPlacement``). The strip comes back once the pane
/// holds two tabs.
enum ChatDockChrome {
    /// `columns` are the pane's screen's; `isLoneChat` says the pane's column
    /// is one pane holding one agent chat.
    static func hidesStrip(pane: LayoutPaneID, columns: [LayoutColumn], tabCount: Int, isLoneChat: Bool) -> Bool {
        guard tabCount < 2, let column = columns.first(where: { $0.root.contains(pane) }) else { return false }
        if column.dock?.role == .agentChat { return true }
        // Beside a chat dock a chat in the strip is an ordinary tab: it docks nothing.
        return column.dock == nil && isLoneChat && columns.filter { $0.dock == nil }.count == 1
            && !columns.contains { $0.dock?.role == .agentChat }
    }
}

extension ChatDockChrome {
    /// Whether `controller`'s pane, holding `tabCount` tabs, hides its strip.
    @MainActor static func hidesStrip(_ controller: PaneController, tabCount: Int) -> Bool {
        guard tabCount < 2, let content = controller.workspace,
              content.daemon.supports(DaemonCapabilities.shared.dockColumnRole),
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return false }
        let pane = controller.layoutPaneID
        let columns = ChatColumnPlacement.columns(of: screen, containing: pane)
        // A lone New Tab page set to an agent chat hides the strip like the chat it becomes, so the
        // first send never drops the strip and moves the page up (cx-ncc.58). A page set to a
        // terminal or browser keeps the strip its replacement tab shows.
        let agentTabs = controller.services.agentTabs
        // A tab closing now is gone already: the strip hides with the close, not a snapshot later.
        let tabs = controller.pane.tabs.filter { !controller.pendingClosed.contains($0.id) }
        let lone = columns.first { $0.root.contains(pane) }?.root.panes.count == 1
            && tabs.count == 1
            && (ChatColumnPlacement.isChat(tabs[0], services: controller.services)
                || agentTabs.isAgentNewTabPage(tabs[0].id))
        return hidesStrip(pane: pane, columns: columns, tabCount: tabCount, isLoneChat: lone)
    }
}
