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

    /// How `controller`'s new chat opens: the pane it opens in, and for a new
    /// dock hidden and unselected, docked by `then` (shown once, in its dock).
    /// `placed` false (a New Tab page becoming a chat) keeps it in `controller`.
    struct Opening {
        var target: PaneController
        var select: Bool
        var hidden = false
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
                for await located in Observations({ services.locateTab(key) != nil }) where located {
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
                focusWhenShown(key, in: content, services: services)
            }
            return nil
        })
    }

    /// Focuses the pane that shows tab `key` once the layout has it.
    @MainActor private static func focusWhenShown(_ key: String, in content: WorkspaceContentController, services: AppServices) {
        func pane() -> LayoutPaneID? {
            guard let model = services.locateTab(key)?.1 else { return nil }
            return services.paneController(for: model)?.layoutPaneID
        }
        services.registry.track(Task { @MainActor in
            if pane() == nil {
                for await shown in Observations({ pane() != nil }) where shown { break }
            }
            if let pane = pane() { PaneHandlers.focus(pane, in: content) }
            return nil
        })
    }
}

extension PaneController {
    /// Chat `key` reached its dock (or the move failed): the strip may list it again.
    func dockFinished(_ key: String) {
        pendingDock.removeAll()
        apply(snapshot())
    }
}
