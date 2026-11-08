import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWindowRules

/// What the chat dock refuses (lawrence-call-1006 D): it is a docked
/// region, not a split that happens to sit on the left. It never splits
/// (every split, auto layout and split drop goes through `splitRoom`) and
/// holds only agent chats, so tools dropped or moved into it are refused.
enum ChatDockRules {

    /// The chat rules' read of `pane`'s column on its screen (zoomed as the screen shows it); nil for a pane no window shows.
    @MainActor private static func read(_ pane: PaneModel, services: AppServices, moving: WindowRules.ChatMoving? = nil) -> WindowRules.ChatColumnRead? {
        guard let controller = services.paneController(for: pane), let content = controller.workspace,
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return nil }
        return ChatColumnPlacement.read(controller, services: services, zoomed: screen.zoomed, moving: moving)
    }

    /// Whether `pane` is a shown pane in the chat dock.
    @MainActor static func isChatDock(_ pane: PaneModel, services: AppServices) -> Bool {
        read(pane, services: services)?.chatDock ?? false
    }

    /// Whether Split Down of `pane` grows its chat dock (`chat::Dock::splits_down`, #29848) on a daemon that takes it.
    /// The rule reads topology only; a daemon without `dock-column-split-down-v1` never asks it.
    @MainActor static func splitsDownInDock(_ pane: PaneModel, services: AppServices) -> Bool {
        guard services.daemon(for: pane).supports(DaemonCapability.dockColumnSplitDown.rawValue) else { return false }
        return read(pane, services: services)?.splitsDown == true
    }

    /// Refuses (and reports) a non-chat tab moving into a chat dock that takes only chats. A
    /// reorder inside the dock is not a move into it.
    @MainActor static func refusesMove(_ tab: TabModel, to pane: PaneModel, services: AppServices) -> Bool {
        let moving = WindowRules.ChatMoving(samePane: services.locateTab(model: tab)?.1 === pane,
                                            chat: ChatColumnPlacement.isChat(tab, services: services))
        guard read(pane, services: services, moving: moving)?.refusesMove == true else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }

    /// Refuses (and reports) a tab group moving into a chat dock that takes only chats: a group
    /// is a set of tools, never a chat.
    @MainActor static func refusesGroupMove(to pane: PaneModel, services: AppServices) -> Bool {
        guard read(pane, services: services, moving: .init(samePane: false, chat: false))?.refusesMove == true else { return false }
        services.registry.refuse(RefusalStrings.chatDockTakesOnlyChats)
        return true
    }
}

extension ChatDockRules {
    /// The split decision of a drop on `pane`'s edge. A drag's preview has
    /// already measured the room (`roomDecided`); otherwise `measure` does.
    /// The rule is Rust's (`chat::drop_split`); with no answer the room is measured.
    static func dropSplit(roomDecided: Bool, intoChatDock: Bool,
                          measure: () -> SplitRoomDecision) -> SplitRoomDecision {
        switch WindowRules().dropSplit(roomDecided: roomDecided, intoChatDock: intoChatDock) {
        case .refusedChatDock?: .refused(RefusalStrings.chatDockCannotSplit)
        case .split?: .split
        case .measure?, nil: measure()
        }
    }

    /// The pane a drop on a workspace (the sidebar) lands in: its first
    /// screen's first pane outside the chat dock (`chat::drop_pane`); with no answer its first pane.
    @MainActor static func workspaceDropPane(_ screen: ScreenModel?, services: AppServices) -> PaneModel? {
        let panes = screen?.panes ?? []
        guard !panes.isEmpty else { return nil }
        let index = WindowRules().dropPane(chatDocks: panes.map { isChatDock($0, services: services) }) ?? 0
        return panes.indices.contains(index) ? panes[index] : panes.first
    }
}
