import AppKit

/// The sidebar's half of hover prefetch (HQ#5914, finding 2): which chat the person is likely to
/// open next, as the tab its row stands for. The pointer resting on a workspace row, or an arrow key
/// step heading for the row after the one it just showed. The app forwards it to the agent chat on
/// screen, whose page decides whether and when to read it (hoverPrefetch.ts); nothing here waits,
/// times or counts. O(1) per hovered row: the row's workspace comes from `workspaces`.
extension SidebarListView {
    func forwardHover(_ key: SidebarRowKey?) {
        guard let onHoverTab else { return }
        guard case let .workspace(id)? = key else { return onHoverTab(nil) }
        onHoverTab(workspaces[id]?.focusedTab)
    }

    /// An Up or Down step shows the row it lands on at once, so the row one further in its direction
    /// is the likely next one (a held arrow key reads ahead of itself).
    func forwardStepAhead(_ delta: Int, in order: [WorkspaceID]) {
        guard let onHoverTab, let active = model.activeWorkspaceID, let at = order.firstIndex(of: active) else { return }
        let next = at + delta
        onHoverTab(order.indices.contains(next) ? workspaces[order[next]]?.focusedTab : nil)
    }
}

extension SidebarViewComponents {
    /// The tab of the row the person is likely to open next (``SidebarListView/onHoverTab``).
    public var onHoverTab: ((TabID?) -> Void)? {
        get { list.onHoverTab }
        set { list.onHoverTab = newValue }
    }
}
