import Foundation

extension SidebarModel {
    // MARK: Selection (UI-local)

    /// The bridge's `.select` echo is singular, but these two local gestures have already
    /// established an intentional multi-selection that must survive the activation.
    private func select(_ id: WorkspaceID, preserving selection: Set<WorkspaceID>) {
        send(.select(id))
        if self.selection == [id] { self.selection = selection }
    }

    /// A placeholder row (a machine still connecting) is never selected,
    /// renamed, dragged or shown.
    public func isPlaceholder(_ id: WorkspaceID) -> Bool { workspace(id)?.rowState.isPending == true }

    /// Plain click: select only `id` and activate it.
    public func click(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        selection = [id]
        selectionAnchor = id
        selectionExtent = nil
        send(.select(id))
    }

    /// Cmd-click: toggle `id` in the selection without changing the active
    /// workspace, unless it is the only selected item.
    public func toggleSelection(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        if selection.contains(id) {
            guard selection.count > 1 else { return }
            selection.remove(id)
            if activeWorkspaceID == id, let next = orderedSelection.first { select(next, preserving: selection) }
        } else {
            selection.insert(id)
            selectionAnchor = id
        }
        selectionExtent = nil
    }

    /// The row a Shift range starts from: the anchor while it is still
    /// selected (the App may have replaced the selection since), else the
    /// active workspace.
    private var rangeAnchor: WorkspaceID? {
        selectionAnchor.flatMap { selection.contains($0) ? $0 : nil } ?? activeWorkspaceID
    }

    /// Shift-click: select the visual range from the anchor to `id`.
    public func extendSelection(to id: WorkspaceID, visibleOrder: [WorkspaceID]) {
        guard !isPlaceholder(id) else { return }
        let visibleOrder = visibleOrder.filter { !isPlaceholder($0) }
        guard let anchor = rangeAnchor,
              let a = visibleOrder.firstIndex(of: anchor),
              let b = visibleOrder.firstIndex(of: id) else {
            click(id)
            return
        }
        selection = Set(visibleOrder[min(a, b)...max(a, b)])
        selectionAnchor = anchor
        selectionExtent = id
    }

    /// Arrow-key navigation over the visible rows; a row still being made
    /// (placeholder or creating) is stepped over. With Shift the selection is
    /// the range from the anchor to the new row, so going back shrinks it.
    public func moveActive(by delta: Int, extending: Bool, visibleOrder: [WorkspaceID]) {
        let visibleOrder = visibleOrder.filter { !isPlaceholder($0) }
        guard !visibleOrder.isEmpty else { return }
        // A Shift step continues from the range's moving end, which a Shift-click leaves off the active row.
        let from = extending ? selectionExtent.flatMap { selection.contains($0) ? $0 : nil } ?? activeWorkspaceID : activeWorkspaceID
        let current = from.flatMap { visibleOrder.firstIndex(of: $0) }
        let next = current.map { max(0, min(visibleOrder.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : visibleOrder.count - 1)
        let id = visibleOrder[next]
        if extending {
            let anchor = rangeAnchor ?? id
            let a = visibleOrder.firstIndex(of: anchor) ?? next
            selection = Set(visibleOrder[min(a, next)...max(a, next)])
            selectionAnchor = anchor
            selectionExtent = id
            activeWorkspaceID = id
            select(id, preserving: selection)
        } else {
            click(id)
        }
    }
}
