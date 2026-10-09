import CmuxNextSidebar

/// Previous / Next (Leo 2026-10-09, rapid switching): what the
/// browser-style keys step from the window's keyboard focus. A focused pane
/// with 2+ tabs steps its tabs, wrapping inside the pane; a pane with one
/// tab has nothing to switch to, so it, the sidebar, a field or nothing
/// steps the sidebar rows (wrapping per `sidebar.steppingWraps`). The
/// explicit commands skip the rule: Next/Previous Tab in Pane
/// (`nextSurface`) and Next/Previous Sidebar Item (`nextSidebarTab`).
enum PreviousNext {
    nonisolated enum Scope: Equatable, Sendable {
        /// The focused pane's tabs, wrapping inside the pane.
        case paneTabs
        /// The sidebar rows, in sidebar order.
        case sidebarRows
    }

    /// `focus` is what has the keyboard below any overlay (the palette runs
    /// these for the view under it); `paneTabs` counts the focused pane's tabs.
    nonisolated static func scope(for focus: FocusState.Resolved, paneTabs: Int) -> Scope {
        switch focus {
        case .terminal, .browserPage, .addressBar, .findBar, .devTools, .agentPage, .page, .conversation:
            paneTabs >= 2 ? .paneTabs : .sidebarRows
        case .emptyPane, .sidebar, .sidebarField, .textField, .overlay, .none:
            .sidebarRows
        }
    }

    /// Next (+1) or Previous (-1) in the active window.
    @MainActor static func step(by offset: Int, _ services: AppServices) {
        guard let window = services.windows.active else { return }
        let pane = window.focusedPane
        switch scope(for: window.focus.state.underlying, paneTabs: pane?.orderedIDs.count ?? 0) {
        case .paneTabs: pane?.selectAdjacent(offset)
        case .sidebarRows: SidebarNavigation.step(by: offset, services)
        }
    }
}

// MARK: Sidebar rows

extension PreviousNext {
    /// One step of the sidebar walk: a sidebar item, or a tab row listed
    /// beneath its workspace (Show Tabs Under Workspaces).
    nonisolated enum RowStop: Hashable, Sendable {
        case item(SidebarItem)
        case tab(WorkspaceID, TabID)
    }

    nonisolated static func rowStops(_ items: [SidebarItem], tabs: (WorkspaceID) -> [TabID]) -> [RowStop] {
        items.map(RowStop.item)
    }

    nonisolated static func current(_ item: SidebarItem?, focusedTab: TabID?, in stops: [RowStop]) -> RowStop? {
        item.map(RowStop.item)
    }

    nonisolated static func stop(from current: RowStop?, in stops: [RowStop], by offset: Int, wraps: Bool) -> RowStop? {
        nil
    }
}
