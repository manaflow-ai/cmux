import CmuxNextBridge

// Tab drag -> focus events (plans/cmux-next/focus.md, R7). The dropped tab
// ends selected and focused in its new pane (possibly in another window);
// a cancel restores the focus the source window had; focus never targets a
// pane the move removed.
extension TabDragSession {
    /// Workspace drags (no source pane) change window membership, which
    /// reaches focus as an ordinary topology change.
    func focusDragBegan(_ item: Item, from pane: PaneController?) {
        guard let pane else { return }
        services.windowController(showing: pane)?.focus.send(.dragBegan(tabs: Self.focusTabs(item, pane: pane), pane: pane.paneKey))
    }

    /// Call once per drag end, before the outcome's daemon command runs.
    func focusDragEnded(_ drag: Drag, outcome: TabDragOutcome) {
        let source = drag.source.window
        let sourcePane = drag.source.pane
        let tabs = sourcePane.map { Self.focusTabs(drag.source.item, pane: $0) } ?? []
        drag.revealTabs = tabs
        let drop = drag.winner?.window ?? source
        // Option files the tabs away: focus stays where it was.
        if drag.filesAway {
            source?.focus.send(.dragEnded(.cancelled))
            return
        }
        switch outcome {
        case .cancel, .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace:
            source?.focus.send(.dragEnded(.cancelled))
        case .workspace(let id):
            // Into another workspace: its window shows it once the move
            // lands (`revealLanded`) and focus follows the tab there.
            source?.focus.send(.dragEnded(.movedAway))
            let landing = services.landingWindow(tab: tabs.first ?? "", workspaceID: id) ?? drop
            landing?.focus.send(.dragEnded(.dropped(tabs: tabs, awayFrom: sourcePane?.paneKey)))
        case .tearOff:
            // The new window focuses it once it opens (`focusTornOff`).
            source?.focus.send(.dragEnded(.movedAway))
        case .strip(let stripID, _, _):
            let inPlace = sourcePane?.stripModel.stripID == stripID
            if drop !== source { source?.focus.send(.dragEnded(.movedAway)) }
            drop?.focus.send(.dragEnded(.dropped(tabs: tabs, awayFrom: inPlace ? nil : sourcePane?.paneKey)))
        case .newSplit, .newColumn, .newDock, .newWorkspace:
            if drop !== source { source?.focus.send(.dragEnded(.movedAway)) }
            drop?.focus.send(.dragEnded(.dropped(tabs: tabs, awayFrom: sourcePane?.paneKey)))
        }
    }

    /// A torn-off window focuses the dragged tab once its workspace loads.
    func focusTornOff(_ controller: WindowController?, drag: Drag) {
        guard !drag.filesAway, let controller, let pane = drag.source.pane else { return }
        controller.focus.send(.dragEnded(.dropped(tabs: Self.focusTabs(drag.source.item, pane: pane))))
    }

    /// The dragged tabs, the one to focus first: a group's selected member
    /// when the selection is in the group.
    private static func focusTabs(_ item: Item, pane: PaneController) -> [String] {
        switch item {
        case .tab(let id):
            return [id]
        case .workspaces:
            return []
        case .group(_, let members):
            guard let selected = pane.stripModel.selectedID?.rawValue, members.contains(selected) else { return members }
            return [selected] + members.filter { $0 != selected }
        }
    }
}
