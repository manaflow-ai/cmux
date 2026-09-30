import CmuxNextBridge

// Tab drag -> focus events (plans/cmux-next/focus.md, R7). The dropped tab
// ends selected and focused in its new pane (possibly in another window);
// a cancel restores the focus the source window had; focus never targets a
// pane the move removed.
extension TabDragSession {
    func focusDragBegan(_ item: Item, from pane: PaneController) {
        services.windowController(showing: pane)?.focus.send(.dragBegan(tabs: Self.focusTabs(item, pane: pane), pane: pane.paneKey))
    }

    /// Call once per drag end, before the outcome's daemon command runs.
    func focusDragEnded(_ drag: Drag, outcome: TabDragOutcome) {
        let source = drag.source.window
        let sourcePane = drag.source.pane
        let tabs = sourcePane.map { Self.focusTabs(drag.source.item, pane: $0) } ?? []
        let drop = drag.winner?.window ?? source
        switch outcome {
        case .cancel, .moveWindow:
            source?.focus.send(.dragEnded(.cancelled))
        case .workspace:
            // Into a workspace this window does not show: focus stays here.
            source?.focus.send(.dragEnded(.movedAway))
        case .tearOff:
            // The new window focuses it once it opens (`focusTornOff`).
            source?.focus.send(.dragEnded(.movedAway))
        case .strip(let stripID, _, _):
            let inPlace = sourcePane?.stripModel.stripID == stripID
            if drop !== source { source?.focus.send(.dragEnded(.movedAway)) }
            drop?.focus.send(.dragEnded(.dropped(tabs: tabs, awayFrom: inPlace ? nil : sourcePane?.paneKey)))
        case .newSplit, .newColumn, .newWorkspace:
            if drop !== source { source?.focus.send(.dragEnded(.movedAway)) }
            drop?.focus.send(.dragEnded(.dropped(tabs: tabs, awayFrom: sourcePane?.paneKey)))
        }
    }

    /// A torn-off window focuses the dragged tab once its workspace loads.
    func focusTornOff(_ controller: WindowController, drag: Drag) {
        guard let pane = drag.source.pane else { return }
        controller.focus.send(.dragEnded(.dropped(tabs: Self.focusTabs(drag.source.item, pane: pane))))
    }

    /// The dragged tabs, the one to focus first: a group's selected member
    /// when the selection is in the group.
    private static func focusTabs(_ item: Item, pane: PaneController) -> [String] {
        switch item {
        case .tab(let id):
            return [id]
        case .group(_, let members):
            guard let selected = pane.stripModel.selectedID?.rawValue, members.contains(selected) else { return members }
            return [selected] + members.filter { $0 != selected }
        }
    }
}
