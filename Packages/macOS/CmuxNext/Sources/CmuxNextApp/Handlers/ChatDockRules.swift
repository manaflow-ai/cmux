import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// What the chat dock refuses (lawrence-call-1006 D): it is a docked
/// region, not a split that happens to sit on the left. It never splits
/// (every split, auto layout and split drop goes through `splitRoom`) and
/// holds only agent chats, so tools dropped or moved into it are refused.
enum ChatDockRules {

    /// The dock flag of `pane`'s column and whether its screen is zoomed; nil for a pane no window shows.
    @MainActor private static func column(of pane: PaneModel, services: AppServices) -> (dock: DockColumn?, zoomed: Bool)? {
        guard let controller = services.paneController(for: pane), let content = controller.workspace,
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return nil }
        let layoutPane = controller.layoutPaneID
        return (ChatColumnPlacement.columns(of: screen, containing: layoutPane).first { $0.root.contains(layoutPane) }?.dock, screen.zoomed)
    }

    /// Whether `pane` is a shown pane of a chat dock that takes only agent chats (``DockColumn/takesOnlyChats``).
    @MainActor private static func takesOnlyChats(_ pane: PaneModel, services: AppServices) -> Bool {
        column(of: pane, services: services)?.dock?.takesOnlyChats ?? false
    }

    /// Whether `pane` is a shown pane in the chat dock.
    @MainActor static func isChatDock(_ pane: PaneModel, services: AppServices) -> Bool {
        column(of: pane, services: services)?.dock?.role == .agentChat
    }

    /// Whether Split Down of `pane` grows its chat dock (``DockColumn/splitsDown(zoomed:)``, #29848) on a daemon that takes it.
    @MainActor static func splitsDownInDock(_ pane: PaneModel, services: AppServices) -> Bool {
        guard let column = column(of: pane, services: services), column.dock?.splitsDown(zoomed: column.zoomed) == true else { return false }
        return services.daemon(for: pane).supports(DaemonCapability.dockColumnSplitDown.rawValue)
    }

    /// Refuses (and reports) a non-chat tab moving into a chat dock that takes only chats. A
    /// reorder inside the dock is not a move into it.
    @MainActor static func refusesMove(_ tab: TabModel, to pane: PaneModel, services: AppServices) -> Bool {
        guard services.locateTab(model: tab)?.1 !== pane, !ChatColumnPlacement.isChat(tab, services: services),
              takesOnlyChats(pane, services: services) else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }

    /// Refuses (and reports) a tab group moving into a chat dock that takes only chats: a group
    /// is a set of tools, never a chat.
    @MainActor static func refusesGroupMove(to pane: PaneModel, services: AppServices) -> Bool {
        guard takesOnlyChats(pane, services: services) else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }
}

extension ChatDockRules {
    /// The split decision of a drop on `pane`'s edge. A drag's preview has
    /// already measured the room (`roomDecided`); otherwise `measure` does.
    static func dropSplit(roomDecided: Bool, intoChatDock: Bool,
                          measure: () -> SplitRoomDecision) -> SplitRoomDecision {
        if intoChatDock { return .refused(RefusalStrings.chatDockCannotSplit) }
        return roomDecided ? .split : measure()
    }

    /// The pane a drop on a workspace (the sidebar) lands in: its first
    /// screen's first pane outside the chat dock (which takes only chats).
    static func workspaceDropPane<Pane>(_ panes: [Pane], isChatDock: (Pane) -> Bool) -> Pane? {
        panes.first { !isChatDock($0) } ?? panes.first
    }

    @MainActor static func workspaceDropPane(_ screen: ScreenModel?, services: AppServices) -> PaneModel? {
        workspaceDropPane(screen?.panes ?? []) { isChatDock($0, services: services) }
    }
}
