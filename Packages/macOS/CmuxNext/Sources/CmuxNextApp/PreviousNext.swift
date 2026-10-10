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
        case .sidebarRows: stepRows(by: offset, in: window, services)
        }
    }
}

// MARK: Sidebar rows

extension PreviousNext {
    /// One step of the sidebar walk: a sidebar item, or a tab row listed
    /// beneath its workspace (Show Tabs Under Workspaces).
    nonisolated enum RowStop: Hashable, Sendable {
        case item(SidebarItem)
        case tab(WorkspaceID, CmuxNextSidebar.TabID)
    }

    /// The walk over `items` (the sidebar order): a workspace whose tabs are
    /// listed is its tab rows, in order; any other item is one step.
    nonisolated static func rowStops(_ items: [SidebarItem], tabs: (WorkspaceID) -> [CmuxNextSidebar.TabID]) -> [RowStop] {
        items.flatMap { item -> [RowStop] in
            guard case .workspace(let id) = item else { return [.item(item)] }
            let listed = tabs(id)
            return listed.isEmpty ? [.item(item)] : listed.map { .tab(id, $0) }
        }
    }

    /// Where the walk stands: the selected item, or, for a workspace whose
    /// tabs are listed, its focused tab's row (else its first).
    nonisolated static func current(_ item: SidebarItem?, focusedTab: CmuxNextSidebar.TabID?, in stops: [RowStop]) -> RowStop? {
        guard let item else { return nil }
        guard case .workspace(let id) = item else { return .item(item) }
        let rows = stops.filter { if case .tab(id, _) = $0 { true } else { false } }
        guard let first = rows.first else { return .item(item) }
        if let focusedTab, rows.contains(.tab(id, focusedTab)) { return .tab(id, focusedTab) }
        return first
    }

    /// The stop `offset` steps from `current`, as `SidebarItemOrder.step`:
    /// from outside the list +1 starts at the first and -1 at the last; past
    /// an end it wraps, or is nil when wrapping is off.
    nonisolated static func stop(from current: RowStop?, in stops: [RowStop], by offset: Int, wraps: Bool) -> RowStop? {
        guard !stops.isEmpty, offset != 0 else { return nil }
        guard let current, let index = stops.firstIndex(of: current) else { return offset > 0 ? stops.first : stops.last }
        let next = index + offset
        if stops.indices.contains(next) { return stops[next] }
        guard wraps else { return nil }
        return stops[((next % stops.count) + stops.count) % stops.count]
    }

    /// Next (+1) or Previous (-1) over the active window's sidebar rows,
    /// tab rows included while they are listed. The tab row runs as its
    /// click does (the tab shows, its pane takes the keyboard).
    @MainActor static func stepRows(by offset: Int, in window: WindowController, _ services: AppServices) {
        let model = window.sidebar.model
        guard model.showWorkspaceTabs else { return SidebarNavigation.step(by: offset, services) }
        let settings = SidebarNavigation.settings(services)
        let stops = rowStops(model.itemOrder.items(settings.stepping)) { id in
            model.collapsedWorkspaces.contains(id) ? [] : (model.workspace(id)?.tabs ?? []).map(\.id)
        }
        let selected = SidebarNavigation.selectedItem(page: window.state.page, workspace: window.state.workspaceID,
                                                      layout: model.layout, room: window.state.profileID.rawValue,
                                                      refs: WorkspaceLayoutRefs(machines: services.machines))
        let focusedTab = window.focusedPane?.stripModel.selectedID.map { CmuxNextSidebar.TabID($0.rawValue) }
        let from = current(selected, focusedTab: focusedTab, in: stops)
        switch stop(from: from, in: stops, by: offset, wraps: settings.steppingWraps) {
        case .item(let item)?: SidebarNavigation.activate(item, in: window, services)
        case .tab(_, let tab)?: _ = services.revealTab(tab.rawValue)
        case nil: break
        }
    }
}
