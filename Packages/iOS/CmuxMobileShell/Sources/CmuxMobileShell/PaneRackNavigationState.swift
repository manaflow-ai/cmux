import CmuxMobileShellModel

/// Phone-local pane staging and per-pane tab selection state.
struct PaneRackNavigationState: Equatable, Sendable {
    private(set) var stagedPaneIDsByWorkspaceID: [String: String] = [:]
    private(set) var selectedTabIDsByWorkspaceID: [String: [String: String]] = [:]

    mutating func reconcile(
        workspace: MobileWorkspacePreview,
        supportsNativePanes: Bool
    ) -> MobileTerminalPreview.ID? {
        let panes = projectedPanes(workspace: workspace, supportsNativePanes: supportsNativePanes)
        let workspaceID = workspace.id.rawValue
        let paneIDs = Set(panes.map(\.id))
        var selectedByPane = selectedTabIDsByWorkspaceID[workspaceID] ?? [:]
        selectedByPane = selectedByPane.filter { paneIDs.contains($0.key) }

        for pane in panes {
            if let selected = selectedByPane[pane.id], pane.tabIDs.contains(selected) {
                continue
            }
            if let selected = initialSelectedTabID(in: pane, workspace: workspace) {
                selectedByPane[pane.id] = selected
            } else {
                selectedByPane.removeValue(forKey: pane.id)
            }
        }
        selectedTabIDsByWorkspaceID[workspaceID] = selectedByPane

        let currentStaged = stagedPaneIDsByWorkspaceID[workspaceID]
        let staged = currentStaged.flatMap { paneIDs.contains($0) ? $0 : nil }
            ?? panes.first(where: \.isFocused)?.id
            ?? panes.first?.id
        if let staged {
            stagedPaneIDsByWorkspaceID[workspaceID] = staged
            return selectedByPane[staged].map(MobileTerminalPreview.ID.init(rawValue:))
        }
        stagedPaneIDsByWorkspaceID.removeValue(forKey: workspaceID)
        return nil
    }

    mutating func stagePane(
        _ paneID: String,
        workspace: MobileWorkspacePreview,
        supportsNativePanes: Bool
    ) -> MobileTerminalPreview.ID? {
        let panes = projectedPanes(workspace: workspace, supportsNativePanes: supportsNativePanes)
        guard panes.contains(where: { $0.id == paneID }) else {
            return reconcile(workspace: workspace, supportsNativePanes: supportsNativePanes)
        }
        _ = reconcile(workspace: workspace, supportsNativePanes: supportsNativePanes)
        stagedPaneIDsByWorkspaceID[workspace.id.rawValue] = paneID
        return selectedTabIDsByWorkspaceID[workspace.id.rawValue]?[paneID]
            .map(MobileTerminalPreview.ID.init(rawValue:))
    }

    mutating func selectTab(
        _ surfaceID: String,
        inPane paneID: String,
        workspace: MobileWorkspacePreview,
        supportsNativePanes: Bool
    ) -> MobileTerminalPreview.ID? {
        let panes = projectedPanes(workspace: workspace, supportsNativePanes: supportsNativePanes)
        guard panes.first(where: { $0.id == paneID })?.tabIDs.contains(surfaceID) == true else {
            return reconcile(workspace: workspace, supportsNativePanes: supportsNativePanes)
        }
        _ = reconcile(workspace: workspace, supportsNativePanes: supportsNativePanes)
        selectedTabIDsByWorkspaceID[workspace.id.rawValue, default: [:]][paneID] = surfaceID
        stagedPaneIDsByWorkspaceID[workspace.id.rawValue] = paneID
        return MobileTerminalPreview.ID(rawValue: surfaceID)
    }

    func projectedPanes(
        workspace: MobileWorkspacePreview,
        supportsNativePanes: Bool
    ) -> [MobilePanePreview] {
        let terminalIDs = Set(workspace.terminals.map { $0.id.rawValue })
        if supportsNativePanes, !workspace.panes.isEmpty {
            return workspace.panes.compactMap { pane in
                var filtered = pane
                filtered.tabIDs = pane.tabIDs.filter { terminalIDs.contains($0) }
                guard !filtered.tabIDs.isEmpty else { return nil }
                if let selected = filtered.selectedTabID, !filtered.tabIDs.contains(selected) {
                    filtered.selectedTabID = nil
                }
                return filtered
            }
        }
        guard !workspace.terminals.isEmpty else { return [] }
        let selected = workspace.terminals.first(where: \.isFocused)
            ?? workspace.terminals.first(where: \.isReady)
            ?? workspace.terminals.first
        return [MobilePanePreview(
            id: implicitPaneID(workspaceID: workspace.id),
            tabIDs: workspace.terminals.map { $0.id.rawValue },
            selectedTabID: selected?.id.rawValue,
            isFocused: true,
            rect: MobilePaneNormalizedRect(x: 0, y: 0, w: 1, h: 1)
        )]
    }

    func effectiveSelectedTabID(workspaceID: MobileWorkspacePreview.ID, paneID: String) -> String? {
        selectedTabIDsByWorkspaceID[workspaceID.rawValue]?[paneID]
    }

    func stagedPaneID(workspaceID: MobileWorkspacePreview.ID) -> String? {
        stagedPaneIDsByWorkspaceID[workspaceID.rawValue]
    }

    func implicitPaneID(workspaceID: MobileWorkspacePreview.ID) -> String {
        "__cmux_implicit_pane__:\(workspaceID.rawValue)"
    }

    private func initialSelectedTabID(
        in pane: MobilePanePreview,
        workspace: MobileWorkspacePreview
    ) -> String? {
        if let selectedTabID = pane.selectedTabID, pane.tabIDs.contains(selectedTabID) {
            return selectedTabID
        }
        let terminalsByID = Dictionary(uniqueKeysWithValues: workspace.terminals.map { ($0.id.rawValue, $0) })
        return pane.tabIDs.first(where: { terminalsByID[$0]?.isFocused == true })
            ?? pane.tabIDs.first(where: { terminalsByID[$0]?.isReady == true })
            ?? pane.tabIDs.first
    }
}
