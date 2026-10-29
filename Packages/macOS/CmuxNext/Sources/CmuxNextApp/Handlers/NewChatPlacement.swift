import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWakeups
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
        // The wait reads the tab index again only when it moves; the move starts in one task of the run's completion.
        services.registry.trackWork(owner: "NewChatPlacement.dock", on: services.mainWork) {
            // view-observation-allow: one MachineTabIndex lookup per read
            await listed("NewChatPlacement.dock", on: services.mainWork, deadlines: services.mainDeadlines) { services.locateTab(key) }
        } then: { [weak controller] result in
            guard case let .success((tab, pane)?) = result else {
                // Never listed within the bound: the strip lists the chat where it is if it ever shows.
                controller?.dockFinished(key)
                return nil
            }
            TabMoves.toNewDockColumn(tab, anchor: pane, edge: .left, role: .agentChat, services: services) { moved in
                guard let controller else { return }
                controller.dockFinished(key)
                guard moved, let content = controller.workspace else { return }
                focusWhenShown(key, in: content, leaving: controller.layoutPaneID, services: services)
            }
            return nil
        }
    }

    /// Focuses the pane that shows tab `key` once the layout has it outside
    /// `source`, the pane it moved from (the store may still list it there).
    @MainActor static func focusWhenShown(_ key: String, in content: WorkspaceContentController,
                                                  leaving source: LayoutPaneID, services: AppServices) {
        services.registry.trackWork(owner: "NewChatPlacement.focusWhenShown", on: services.mainWork) {
            await listed("NewChatPlacement.focusWhenShown", on: services.mainWork, deadlines: services.mainDeadlines) { () -> LayoutPaneID? in
                // view-observation-allow: one MachineTabIndex lookup per read
                guard let model = services.locateTab(key)?.1,
                      let id = services.paneController(for: model)?.layoutPaneID, id != source else { return nil }
                return id
            }
        } then: { result in
            if case .success(let pane?) = result { PaneHandlers.focus(pane, in: content) }
            return nil
        }
    }

    /// `read` once it is non-nil (at once when it is now), else nil after ``MainPaneLayout/listLimit`` on `deadlines`:
    /// one `ObservedCondition` (a `ServiceObservation`) reads it again only when something it read changed.
    @MainActor static func listed<Value: Sendable>(_ owner: String, on work: MainWorkScheduler, deadlines: MainDeadlineScheduler,
                                                   _ read: @escaping @MainActor () -> Value?) async -> Value? {
        await ObservedCondition(owner: owner, .visible, on: work)
            .until(timeout: MainPaneLayout.listLimit, deadlines: deadlines) { read() != nil }
        return read()
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
