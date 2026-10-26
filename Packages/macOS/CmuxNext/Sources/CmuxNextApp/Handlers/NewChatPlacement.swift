import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import Observation

extension NewChatPlacement {
    /// Where a new chat from `controller`'s pane opens; `.here` on a daemon
    /// without dock roles.
    @MainActor static func resolve(from controller: PaneController) -> NewChatPlacement {
        guard let content = controller.workspace,
              content.daemon.supports(DaemonCapability.dockColumnRole.rawValue),
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return .here }
        let pane = controller.layoutPaneID
        return resolve(from: pane, columns: ChatColumnPlacement.columns(of: screen, containing: pane),
                       isLoneChat: ChatColumnPlacement.resolve(from: controller, services: controller.services) == .dockChat)
    }

    /// How `controller`'s new chat opens: the pane it opens in, and for a new
    /// dock hidden and unselected, docked by `then` (shown once, in its dock).
    /// `placed` false (a New Tab page becoming a chat) keeps it in `controller`.
    struct Opening {
        var target: PaneController
        var select: Bool
        var hidden = false
        /// The chat opens in a new pane on this side of `target` (a new column beside Home's lone dock).
        var split: SplitDirection?
        var then: (@MainActor (String) -> Void)?
    }

    @MainActor static func opening(from controller: PaneController, placed: Bool, select: Bool,
                                   then: (@MainActor (String) -> Void)?) -> Opening {
        var opening = Opening(target: controller, select: select, then: then)
        guard placed else { return opening }
        switch resolve(from: controller) {
        case .here:
            break
        case .dock(let pane):
            guard let content = controller.workspace, let dock = content.panes[pane] else { break }
            opening.target = dock
            if select { PaneHandlers.focus(pane, in: content) }
        case .besideDock:
            // One daemon commit: the conversation tab in a split right of the pinned dock, which the
            // daemon makes a column beside it (`conversation-tab-split-v1`). Without that the chat
            // opens in the dock, which takes tabs while it is alone (`pinned-dock-alone-v1`).
            guard controller.daemon.supports(DaemonCapability.conversationTabSplit.rawValue) else { break }
            opening.split = .right
        case .newDock:
            opening.hidden = true
            opening.select = false
            opening.then = { [weak controller] key in
                if let controller { NewChatPlacement.dock(key, from: controller) }
                then?(key)
            }
        }
        return opening
    }

    /// Moves new chat `key`, opened hidden in `controller`'s pane, into a new
    /// left chat dock once the store shows it, then focuses it there. A
    /// failed move shows it where it is.
    @MainActor static func dock(_ key: String, from controller: PaneController) {
        let services = controller.services
        services.registry.track(Task { @MainActor [weak controller] in
            var found = services.locateTab(key)
            if found == nil {
                for await located in ObservationStream({ services.locateTab(key) != nil }) where located {
                    found = services.locateTab(key)
                    break
                }
            }
            guard let found else { return nil }
            let (tab, pane) = found
            TabMoves.toNewDockColumn(tab, anchor: pane, edge: .left, role: .agentChat, services: services) { moved in
                guard let controller else { return }
                controller.dockFinished(key)
                guard moved, let content = controller.workspace else { return }
                focusWhenShown(key, in: content, leaving: controller.layoutPaneID, services: services)
            }
            return nil
        })
    }

    /// Focuses the pane that shows tab `key` once the layout has it outside
    /// `source`, the pane it moved from (the store may still list it there).
    @MainActor static func focusWhenShown(_ key: String, in content: WorkspaceContentController,
                                                  leaving source: LayoutPaneID, services: AppServices) {
        func pane() -> LayoutPaneID? {
            guard let model = services.locateTab(key)?.1,
                  let id = services.paneController(for: model)?.layoutPaneID, id != source else { return nil }
            return id
        }
        services.registry.track(Task { @MainActor in
            if pane() == nil {
                for await shown in ObservationStream({ pane() != nil }) where shown { break }
            }
            if let pane = pane() { PaneHandlers.focus(pane, in: content) }
            return nil
        })
    }
}

extension PaneController {
    /// The tab ids `pendingDock` hides: a provisional id also hides the tab
    /// the store replaced it with, from the store's first snapshot on.
    var dockBound: Set<String> {
        pendingDock.hidden(aliases: services.agentTabs.aliases)
    }

    /// Chat `key` reached its dock (or the move failed): the strip may list
    /// it again. Other chats still on their way stay hidden.
    func dockFinished(_ key: String) {
        pendingDock.finished(key, aliases: services.agentTabs.aliases)
        apply(snapshot())
    }
}
