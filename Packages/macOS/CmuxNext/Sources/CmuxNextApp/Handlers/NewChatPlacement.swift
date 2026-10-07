import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Observation

/// Where a new agent chat opens (lawrence-call-1006 D): the agent chat is a
/// docked column on the left (the dock column with the agent chat role),
/// never a tab in the strip.
enum NewChatPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in the chat dock's pane.
    case dock(LayoutPaneID)
    /// A new left chat dock, made from the chat once it exists.
    case newDock

    /// `columns` are the pane's screen's; `isLoneChat` says the pane's column
    /// is one pane holding one agent chat, the only scrolling column. A lone
    /// chat docks when the first tool opens (``ChatColumnPlacement``), so a
    /// second chat joins its pane.
    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], isLoneChat: Bool) -> NewChatPlacement {
        guard columns.contains(where: { $0.root.contains(pane) }) else { return .here }
        if let dock = columns.first(where: { $0.dock?.role == .agentChat }) { return .dock(dock.root.panes[0]) }
        return isLoneChat ? .here : .newDock
    }
}

extension NewChatPlacement {
    /// Where a new chat from `controller`'s pane opens; `.here` on a daemon
    /// without dock roles.
    @MainActor static func resolve(from controller: PaneController) -> NewChatPlacement {
        guard let content = controller.workspace,
              content.daemon.supports(DaemonCapabilities.shared.dockColumnRole),
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return .here }
        let pane = controller.layoutPaneID
        return resolve(from: pane, columns: ChatColumnPlacement.columns(of: screen, containing: pane),
                       isLoneChat: ChatColumnPlacement.resolve(from: controller, services: controller.services) == .dockChat)
    }

    /// Moves new chat `key`, opened in `controller`'s pane, into a new left
    /// chat dock once the store shows it.
    @MainActor static func dock(_ key: String, from controller: PaneController) {
        let services = controller.services
        services.registry.track(Task { @MainActor in
            var found = services.locateTab(key)
            if found == nil {
                for await located in Observations({ services.locateTab(key) != nil }) where located {
                    found = services.locateTab(key)
                    break
                }
            }
            guard let found else { return nil }
            let (tab, pane) = found
            TabMoves.toNewDockColumn(tab, anchor: pane, edge: .left, role: .agentChat, services: services)
            return nil
        })
    }
}
