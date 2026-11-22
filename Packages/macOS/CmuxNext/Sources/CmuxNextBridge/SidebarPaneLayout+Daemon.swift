public import CmuxNextDaemon
public import CmuxNextSidebar

extension SidebarPaneLayout {
    /// The shaped preview's layout for `workspace`: its shown screen's split tree and each pane's tabs; nil when it has
    /// no screen or the tree holds a node this app does not know.
    @MainActor
    public static func make(_ workspace: WorkspaceModel) -> SidebarPaneLayout? {
        guard let screen = workspace.screens.first(where: \.isActive) ?? workspace.screens.first,
              let root = node(screen.layout) else { return nil }
        var panes: [Pane] = []
        var focused: (id: String, at: UInt64)?
        for handle in screen.layout.paneIDs {
            guard let pane = screen.pane(handle) else { continue }
            let id = handle.description
            panes.append(Pane(id: id, tabs: pane.tabs.map { TabID($0.id) },
                              active: min(max(0, pane.defaultTabIndex), max(0, pane.tabs.count - 1))))
            if pane.focusedAt > (focused?.at ?? 0) { focused = (id, pane.focusedAt) }
        }
        return SidebarPaneLayout(root: root, panes: panes, focused: focused?.id)
    }

    private static func node(_ layout: LayoutNode) -> Node? {
        switch layout {
        case let .leaf(pane):
            return .leaf(pane.description)
        case let .split(_, _, direction, ratio, a, b):
            guard let a = node(a), let b = node(b) else { return nil }
            return .split(right: direction == .right, ratio: ratio, a: a, b: b)
        case let .stack(panes, expanded):
            return .stack(panes: panes.map(\.description), expanded: expanded.description)
        case .unknown:
            return nil
        }
    }
}
