import Foundation

extension SidebarModel {
    // MARK: Selection (UI-local)

    /// A placeholder row (a machine still connecting) is never selected,
    /// renamed, dragged or shown.
    public func isPlaceholder(_ id: WorkspaceID) -> Bool { workspace(id)?.rowState.isPending == true }

    /// Plain click: select only `id` and activate it.
    public func click(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        selection = [id]
        send(.select(id))
    }

    /// Cmd-click: toggle `id` in the selection without changing the active
    /// workspace, unless it is the only selected item.
    public func toggleSelection(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        if selection.contains(id) {
            guard selection.count > 1 else { return }
            selection.remove(id)
            if activeWorkspaceID == id, let next = orderedSelection.first { send(.select(next)) }
        } else {
            selection.insert(id)
        }
    }

    /// Shift-click: select the visual range from the active workspace to `id`.
    public func extendSelection(to id: WorkspaceID, visibleOrder: [WorkspaceID]) {
        guard !isPlaceholder(id) else { return }
        guard let anchor = activeWorkspaceID,
              let a = visibleOrder.firstIndex(of: anchor),
              let b = visibleOrder.firstIndex(of: id) else {
            click(id)
            return
        }
        selection = Set(visibleOrder[min(a, b)...max(a, b)])
    }

    /// Arrow-key navigation over the visible rows.
    public func moveActive(by delta: Int, extending: Bool, visibleOrder: [WorkspaceID]) {
        guard !visibleOrder.isEmpty else { return }
        let current = activeWorkspaceID.flatMap { visibleOrder.firstIndex(of: $0) }
        let next = current.map { max(0, min(visibleOrder.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : visibleOrder.count - 1)
        let id = visibleOrder[next]
        guard !isPlaceholder(id) else { return }
        if extending {
            selection.insert(id)
            activeWorkspaceID = id
            send(.select(id))
        } else {
            click(id)
        }
    }
}
