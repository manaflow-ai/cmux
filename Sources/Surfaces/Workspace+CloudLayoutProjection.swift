import Bonsplit
import CmuxSurfaceCatalogModel
import CmuxPanes
import Foundation

@MainActor
extension Workspace {
    /// Reuses native panels and their byte attachments while applying daemon
    /// geometry. Workspaces containing local views retain their own split layout.
    @MainActor
    func applyCloudWorkspaceLayout(_ layout: SurfaceProjectionLayout, projections: [SurfaceProjection]) {
        // Local Desktop/port views can belong to this Cloud workspace without a
        // daemon tab. Membership does not give the daemon geometry ownership:
        // flattening those extra views into its first leaf collapses local splits.
        guard !isRemoteTmuxMirror,
              projections.allSatisfy({ $0.remoteTabID != nil }),
              Set(projections.map(\.panelID)) == Set(panels.keys) else { return }
        var tabs: [SurfaceResourcePlacement: TabID] = [:]
        var panelIDs: [SurfaceResourcePlacement: UUID] = [:]
        for projection in projections {
            guard let tab = surfaceIdFromPanelId(projection.panelID) else { return }
            let placement = SurfaceResourcePlacement(
                resource: projection.resource,
                remoteWorkspaceID: projection.remoteWorkspaceID,
                remoteTabID: projection.remoteTabID
            )
            tabs[placement] = tab
            panelIDs[placement] = projection.panelID
        }
        guard tabs.count == projections.count else { return }
        // A layout document is lossy when the daemon has published a tab before
        // its resource inventory (or while a delta is still being assembled). Do
        // not let that partial document turn a valid local split into a flat pane.
        // The next complete graph will retry the same projection. A complete
        // one-pane document remains valid and is allowed to represent a real
        // remote collapse.
        let expectedPlacements = Set(projections.map {
            SurfaceResourcePlacement(
                resource: $0.resource,
                remoteWorkspaceID: $0.remoteWorkspaceID,
                remoteTabID: $0.remoteTabID
            )
        })
        guard expectedPlacements.isSubset(of: Set(layout.placements)) else { return }
        guard layout.placements.allSatisfy({ tabs[$0] != nil }) else { return }
        guard let sessionLayout = sessionLayout(for: layout, panelIDs: panelIDs) else { return }
        if cloudLayoutMatches(layout, live: bonsplitController.treeSnapshot(), tabs: tabs) {
            // External ratios suppress Bonsplit's geometry callback. Reconcile
            // AppKit and Ghostty even when the terminal membership is unchanged.
            if applyCloudDividerRatios(layout, live: bonsplitController.treeSnapshot()) {
                scheduleTerminalGeometryReconcile()
            }
            recordCloudLayoutBaseline(projections)
            return
        }
        // Selecting a tab also focuses its pane. Without a focused panel, the focused
        // pane's visible tab is what the user was looking at and must end focused.
        let focused = focusedPanelId.flatMap { surfaceIdFromPanelId($0) }
            ?? bonsplitController.focusedPaneId.flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
        // The codec regroups tabs by moving them, which changes each pane's selection.
        // Every pane keeps the tab the user was looking at, not only the focused one.
        let selected = Set(bonsplitController.allPaneIds.compactMap { bonsplitController.selectedTab(inPane: $0)?.id })
        // The existing remote-projection transaction preserves window/workspace
        // focus and suppresses activation while tabs move. It is shared with SSH.
        performRemoteTmuxMirrorMutation {
            withSplitSpaceAdmissionBypass {
                let wasProgrammatic = isProgrammaticSplit
                isProgrammaticSplit = true
                defer { isProgrammaticSplit = wasProgrammatic }
                _ = SessionSplitContainerLayoutCodec(controller: bonsplitController).restoreExistingLayout(
                    sessionLayout,
                    panelIDMap: [:],
                    tabIDForPanelID: surfaceIdFromPanelId
                )
                for pane in bonsplitController.allPaneIds {
                    if let tab = bonsplitController.tabs(inPane: pane).first(where: { selected.contains($0.id) }) {
                        bonsplitController.selectTab(tab.id)
                    }
                }
                if let focused, bonsplitController.tab(focused) != nil { bonsplitController.selectTab(focused) }
            }
        }
        recordCloudLayoutBaseline(projections)
        scheduleTerminalGeometryReconcile()
    }

    /// The machine's arrangement now shows natively; later native edits are measured from it.
    private func recordCloudLayoutBaseline(_ projections: [SurfaceProjection]) {
        guard let machine = projections.first?.resource.machine else { return }
        SurfaceCatalog.shared.cloudWorkspaceLayoutSyncCoordinator.machineLayoutApplied(
            workspaceID: id, tree: cloudLayoutSyncTree(projections: projections, machine: machine)
        )
    }

    private func sessionLayout(
        for layout: SurfaceProjectionLayout,
        panelIDs: [SurfaceResourcePlacement: UUID]
    ) -> SessionWorkspaceLayoutSnapshot? {
        switch layout {
        case .leaf(let placements):
            let ids = placements.compactMap { panelIDs[$0] }
            guard ids.count == placements.count else { return nil }
            let fullWidth = placements.first
                .flatMap { panelIDs[$0] }
                .flatMap { paneId(forPanelId: $0) }
                .map { bonsplitController.isFullWidthTabMode(inPane: $0) }
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: ids,
                selectedPanelId: nil,
                isFullWidthTabMode: fullWidth
            ))
        case .split(let direction, let ratio, let first, let second):
            guard let first = sessionLayout(for: first, panelIDs: panelIDs),
                  let second = sessionLayout(for: second, panelIDs: panelIDs) else { return nil }
            return .split(SessionSplitLayoutSnapshot(
                orientation: direction == .right || direction == .left ? .horizontal : .vertical,
                dividerPosition: ratio,
                first: first,
                second: second
            ))
        }
    }

    private func cloudLayoutMatches(_ layout: SurfaceProjectionLayout, live: ExternalTreeNode,
                                    tabs: [SurfaceResourcePlacement: TabID]) -> Bool {
        switch (layout, live) {
        case (.leaf(let placements), .pane(let pane)):
            return placements.compactMap { tabs[$0]?.uuid.uuidString } == pane.tabs.map(\.id)
        case (.split(let direction, _, let first, let second), .split(let split)):
            let orientation = direction == .right || direction == .left ? "horizontal" : "vertical"
            return split.orientation == orientation && cloudLayoutMatches(first, live: split.first, tabs: tabs)
                && cloudLayoutMatches(second, live: split.second, tabs: tabs)
        default: return false
        }
    }

    @discardableResult
    private func applyCloudDividerRatios(_ layout: SurfaceProjectionLayout, live: ExternalTreeNode) -> Bool {
        guard case .split(_, let ratio, let first, let second) = layout, case .split(let split) = live else { return false }
        var changed = false
        if let id = UUID(uuidString: split.id), abs(split.dividerPosition - ratio) > 0.0001 {
            changed = bonsplitController.setDividerPosition(CGFloat(ratio), forSplit: id, fromExternal: true)
        }
        let firstChanged = applyCloudDividerRatios(first, live: split.first)
        let secondChanged = applyCloudDividerRatios(second, live: split.second)
        return changed || firstChanged || secondChanged
    }
}
