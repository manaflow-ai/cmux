public import CmuxNextDaemon
public import CmuxNextSidebar

/// The hover card's miniature of a workspace's splits (``SidebarPaneShape``), read from its shown screen's tree.
extension SidebarMapping {
    /// The shown screen's split layout; nil when it shows one pane (or is zoomed to one), so a one-pane card draws
    /// no miniature. Ratios are rounded to hundredths: a divider drag does not re-map the row each point.
    @MainActor
    public static func paneShape(_ workspace: WorkspaceModel) -> SidebarPaneShape? {
        guard let screen = workspace.screens.first(where: \.isActive) ?? workspace.screens.first,
              screen.zoomedPane == nil else { return nil }
        let focused = screen.panes.max(by: { $0.focusedAt < $1.focusedAt })?.handle
        func pane(_ handle: PaneID) -> SidebarPaneShape {
            let model = screen.pane(handle)
            let tab = model.flatMap { $0.tabs.indices.contains($0.defaultTabIndex) ? $0.tabs[$0.defaultTabIndex] : $0.tabs.first }
            return .pane(.init(kind: tab.map(kind), focused: handle == focused))
        }
        func shape(_ node: LayoutNode) -> SidebarPaneShape? {
            switch node {
            case .leaf(let handle): pane(handle)
            case let .split(_, _, direction, ratio, a, b):
                switch (shape(a), shape(b)) {
                case let (a?, b?): .split(axis: direction == .right ? .horizontal : .vertical, ratio: (ratio * 100).rounded() / 100, a, b)
                case let (one?, nil), let (nil, one?): one
                case (nil, nil): nil
                }
            case let .stack(_, expanded): pane(expanded)
            case .unknown: nil
            }
        }
        let made: SidebarPaneShape?
        if screen.columns.count > 1 {
            let columns = screen.columns.compactMap { column in
                shape(column.layout).map { SidebarPaneShape.Column(width: (column.width * 100).rounded() / 100, shape: $0) }
            }
            made = columns.count > 1 ? .row(columns) : columns.first?.shape
        } else {
            made = shape(screen.columns.first?.layout ?? screen.layout)
        }
        guard let made, made.paneCount > 1 else { return nil }
        return made
    }

    /// The miniature's kind for a pane's front tab: its agent, its page or its terminal.
    @MainActor
    static func kind(_ tab: TabModel) -> SidebarWorkspaceKind {
        if tab.kind == .conversation || tab.agentBrand != nil { return .harness }
        return tab.kind == .browser ? .browser : .terminal
    }
}
