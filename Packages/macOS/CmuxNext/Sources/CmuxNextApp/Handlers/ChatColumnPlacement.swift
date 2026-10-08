import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// Where a person's new tab goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app). The chat dock is
/// the left dock column with the agent chat role: it never gets tabs of
/// its own, so tools opened from it are tabs in the scrolling strip.
enum ChatColumnPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane of the scrolling strip.
    case tab(in: LayoutPaneID)
    /// The chat is alone on its screen: it moves into a new left dock with
    /// the agent chat role, and the new tab stays in its pane.
    case dockChat

    /// `columns` are the screen's, in strip order; `recent` orders panes by
    /// last focus, newest first; `isLoneChat` says whether a column is one
    /// pane holding one agent chat. Only the role makes a chat dock: chats
    /// in a plain dock or beside other columns are normal panes. A `zoomed`
    /// screen shows only its zoomed pane, so nothing docks or moves. The
    /// daemon never keeps a dock without a scrolling column (an all-docked
    /// screen undocks), so a chat dock always has a strip to send tabs to.
    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], recent: [LayoutPaneID] = [],
                        zoomed: Bool = false, isLoneChat: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        guard !zoomed, let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return .here }
        let column = columns[index]
        let strip = columns.filter { $0.dock == nil }
        if column.dock?.role == .agentChat {
            guard let target = strip.first else { return .here }
            return .tab(in: recent.first { id in strip.contains { $0.root.contains(id) } } ?? target.root.panes[0])
        }
        guard column.dock == nil, strip.count == 1, !columns.contains(where: { $0.dock?.role == .agentChat }),
              isLoneChat(column) else { return .here }
        return .dockChat
    }
}

extension ChatColumnPlacement {
    /// `screen`'s columns in strip order. A screen stored as one split tree
    /// is one implicit column.
    static func columns(of screen: LayoutScreen, containing pane: LayoutPaneID) -> [LayoutColumn] {
        screen.layout.columns.isEmpty
            ? screen.column(containing: pane).map { [$0] } ?? [] : screen.layout.columns
    }

    /// What a person's new tab from `controller`'s pane becomes.
    @MainActor static func resolve(from controller: PaneController, services: AppServices) -> ChatColumnPlacement {
        guard let content = controller.workspace,
              content.daemon.supports(DaemonCapabilities.shared.dockColumnRole),
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return .here }
        let columns = columns(of: screen, containing: controller.layoutPaneID)
        let agentTabs = services.agentTabs
        // A zoomed screen maps to its zoomed pane alone (LayoutMapping).
        let zoomed = content.workspace.screens.contains { screen in
            screen.zoomedPane != nil && screen.panes.contains { $0 === controller.pane }
        }
        return resolve(from: controller.layoutPaneID, columns: columns, recent: content.recentPanes, zoomed: zoomed) { column in
            guard column.root.panes.count == 1, let tabs = content.panes[column.root.panes[0]]?.pane.tabs,
                  tabs.count == 1 else { return false }
            // The New Tab page is an agent tab too, but not a chat.
            return agentTabs.isAgentTab(tabs[0].id) && !agentTabs.isNewTabPage(tabs[0].id)
        }
    }

    /// Where a person's new tab from `controller`'s pane opens: the pane
    /// to open it in (`controller` itself, or the strip pane, focused), or
    /// nil when it is already open. A lone chat moves into a new left dock
    /// with the agent chat role, leaving `respawn` in its pane, in one daemon
    /// commit. Without `respawn` (a New Tab page, which is not a daemon tab)
    /// it stays in `controller`.
    @MainActor static func route(from controller: PaneController, respawn: SplitRespawn?,
                                 services: AppServices) -> PaneController? {
        guard let content = controller.workspace else { return controller }
        switch resolve(from: controller, services: services) {
        case .here:
            return controller
        case .tab(let target):
            guard let strip = content.panes[target] else { return controller }
            PaneHandlers.focus(target, in: content)
            return strip
        case .dockChat:
            guard let respawn, controller.daemon.supports(DaemonCapabilities.shared.tabColumnRespawn),
                  let chat = controller.pane.tabs.first else { return controller }
            // The new tab left in the pane takes focus, not the docked chat.
            let pane = controller.layoutPaneID
            TabMoves.toNewDockColumn(chat, anchor: controller.pane, edge: .left, role: .agentChat,
                                     respawn: respawn, services: services) { [weak content] moved in
                if moved, let content { PaneHandlers.focus(pane, in: content) }
            }
            return nil
        }
    }
}
