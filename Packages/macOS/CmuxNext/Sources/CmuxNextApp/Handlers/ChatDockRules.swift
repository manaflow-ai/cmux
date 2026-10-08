import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// What the chat dock refuses (lawrence-call-1006 D): it is a docked
/// region, not a split that happens to sit on the left. It never splits
/// (every split, auto layout and split drop goes through `splitRoom`) and
/// holds only agent chats, so tools dropped or moved into it are refused.
enum ChatDockRules {
    static func refusesSplit(of pane: LayoutPaneID, columns: [LayoutColumn]) -> Bool {
        isChatDock(pane, columns)
    }

    static func refusesTab(isChat: Bool, into pane: LayoutPaneID, columns: [LayoutColumn]) -> Bool {
        !isChat && isChatDock(pane, columns)
    }

    private static func isChatDock(_ pane: LayoutPaneID, _ columns: [LayoutColumn]) -> Bool {
        columns.first { $0.root.contains(pane) }?.dock?.role == .agentChat
    }

    /// Whether `pane` is a shown pane in the chat dock.
    @MainActor static func isChatDock(_ pane: PaneModel, services: AppServices) -> Bool {
        guard let controller = services.paneController(for: pane), let content = controller.workspace,
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return false }
        let layoutPane = controller.layoutPaneID
        return isChatDock(layoutPane, ChatColumnPlacement.columns(of: screen, containing: layoutPane))
    }

    /// Refuses (and reports) a non-chat tab moving into the chat dock. A
    /// reorder inside the dock is not a move into it.
    @MainActor static func refusesMove(_ tab: TabModel, to pane: PaneModel, services: AppServices) -> Bool {
        guard services.locateTab(tab.id)?.1 !== pane, !ChatColumnPlacement.isChat(tab, services: services),
              isChatDock(pane, services: services) else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }

    /// Refuses (and reports) a tab group moving into the chat dock: a group
    /// is a set of tools, never a chat.
    @MainActor static func refusesGroupMove(to pane: PaneModel, services: AppServices) -> Bool {
        guard isChatDock(pane, services: services) else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }
}

extension ChatDockRules {
    /// The split decision of a drop on `pane`'s edge. A drag's preview has
    /// already measured the room (`roomDecided`); otherwise `measure` does.
    static func dropSplit(roomDecided: Bool, intoChatDock: Bool,
                          measure: () -> SplitRoomDecision) -> SplitRoomDecision {
        roomDecided ? .split : measure()
    }

    /// The pane a drop on a workspace (the sidebar) lands in: its first screen's first pane.
    static func workspaceDropPane<Pane>(_ panes: [Pane], isChatDock: (Pane) -> Bool) -> Pane? {
        panes.first
    }

    @MainActor static func workspaceDropPane(_ screen: ScreenModel?, services: AppServices) -> PaneModel? {
        workspaceDropPane(screen?.panes ?? []) { isChatDock($0, services: services) }
    }
}
