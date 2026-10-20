import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation

/// Where a person's new tab goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app). The chat dock is
/// the left dock column with the agent chat role: tools opened from it are
/// tabs in the scrolling strip. It shows its tab bar like every pane
/// (cx-v4dmy).
enum ChatColumnPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane of the scrolling strip.
    case tab(in: LayoutPaneID)
    /// The chat is alone on its screen: it moves into a new left dock with
    /// the agent chat role, and the new tab stays in its pane.
    case dockChat
    /// The chat dock is a pinned column that takes no tabs and is alone on
    /// its screen (Home with nothing beside it, `pinned-dock-alone-v1`): the
    /// new tab opens in a new column right of it.
    case besideDock

    /// `columns` are the screen's, in strip order; `recent` orders panes by
    /// last focus, newest first; `isLoneChat` says whether a column is one
    /// pane holding one agent chat. Only the role makes a chat dock: chats
    /// in a plain dock or beside other columns are normal panes. A `zoomed`
    /// screen shows only its zoomed pane, so nothing docks or moves. The
    /// daemon keeps a dock without a scrolling column only when it is pinned
    /// (Home's dock alone); its new tabs open in a new column beside it.
    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], recent: [LayoutPaneID] = [],
                        zoomed: Bool = false, isLoneChat: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        guard !zoomed, let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return .here }
        let column = columns[index]
        let strip = columns.filter { $0.dock == nil }
        if column.dock?.role == .agentChat {
            guard let target = strip.first else { return column.dock?.takesTabs == false ? .besideDock : .here }
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
        // A zoomed screen maps to its zoomed pane alone (LayoutMapping).
        let zoomed = content.workspace.screens.contains { screen in
            screen.zoomedPane != nil && screen.panes.contains { $0 === controller.pane }
        }
        return resolve(from: controller.layoutPaneID, columns: columns, recent: content.recentPanes, zoomed: zoomed) { column in
            guard column.root.panes.count == 1, let tabs = content.panes[column.root.panes[0]]?.pane.tabs,
                  tabs.count == 1 else { return false }
            return isChat(tabs[0], services: services)
        }
    }

    /// Whether `tab` is an agent chat. The New Tab page is an agent tab too, but not a chat.
    /// Reads `tab` itself: finding it again by id walks every workspace's tabs, once per
    /// tab of a pane whose tab bar is drawn (cx-6so.21).
    @MainActor static func isChat(_ tab: TabModel, services: AppServices) -> Bool {
        tab.agentSession != nil && !services.agentTabs.isNewTabPage(tab.id)
    }

    /// Where a person's new tab from `controller`'s pane opens: the pane
    /// to open it in (`controller` itself, or the strip pane, focused), or
    /// nil when it is already open. A lone chat moves into a new left dock
    /// with the agent chat role, leaving `respawn` in its pane, in one daemon
    /// commit, whether or not it shows its tab bar (cx-v4dmy: every chat shows
    /// it by default). Without `respawn` (a New Tab page, which is not a daemon
    /// tab) it stays in `controller`.
    @MainActor static func route(from controller: PaneController, respawn: SplitRespawn?,
                                 services: AppServices) -> PaneController? {
        guard let content = controller.workspace else { return controller }
        let placement = resolve(from: controller, services: services)
        switch placement {
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
                                     respawn: respawn, services: services) { [weak content, weak controller] moved in
                if moved, let content { PaneHandlers.focus(pane, in: content) }
                // A hidden tab bar was the chat's choice: the tab left in the pane shows its tab bar again.
                if moved, let controller, services.paneTabBars.choice(for: controller.paneKey) == false {
                    services.paneTabBars.set(nil, for: controller.paneKey)
                    controller.apply(controller.snapshot())
                }
            }
            return nil
        case .besideDock:
            openBesideDock(controller, respawn: respawn, services: services)
            return nil
        }
    }

    /// A person's new tab from Home's pinned dock alone (`pinned-dock-alone-v1`): a new column
    /// right of the dock holds it, made in one daemon commit. A terminal is a new column with its
    /// shell; a web page opens the way Home's links do (`workspace.open_url`, which makes the
    /// column right of a lone dock); anything else is the New Tab page in a split to the right,
    /// which the daemon makes a column beside a pinned dock.
    @MainActor static func openBesideDock(_ controller: PaneController, respawn: SplitRespawn?, services: AppServices) {
        switch respawn {
        case .terminal?:
            controller.workspace?.layoutModel.newColumn(after: controller.layoutPaneID)
        case .browser(let url, _, _)? where URL(string: url).map(isWebPage) == true:
            let daemon = controller.daemon
            services.registry.track(Task { @MainActor in
                _ = await daemon.request("workspace.open_url") { try await WorkspaceOpenURLClient($0).openOnHome(url) }
                return nil
            })
        case .browser?, nil:
            NewTabPage.split(controller, edge: .right)
        }
    }

    private static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
