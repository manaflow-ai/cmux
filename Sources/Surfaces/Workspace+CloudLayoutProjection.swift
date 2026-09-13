import Bonsplit
import Foundation

@MainActor
extension Workspace {
    /// Reuses native panels and their byte attachments while applying daemon
    /// geometry. Mixed local/SSH workspaces remain viewers and keep their layout.
    @MainActor
    func applyCloudWorkspaceLayout(_ layout: SurfaceProjectionLayout, projections: [SurfaceProjection]) {
        guard !isRemoteTmuxMirror, Set(projections.map(\.panelID)) == Set(panels.keys) else { return }
        var tabs: [SurfaceResourcePlacement: TabID] = [:]
        for projection in projections {
            guard let tab = surfaceIdFromPanelId(projection.panelID) else { return }
            tabs[SurfaceResourcePlacement(resource: projection.resource, remoteWorkspaceID: projection.remoteWorkspaceID,
                                          remoteTabID: projection.remoteTabID)] = tab
        }
        guard layout.placements.allSatisfy({ tabs[$0] != nil }) else { return }
        if cloudLayoutMatches(layout, live: bonsplitController.treeSnapshot(), tabs: tabs) {
            applyCloudDividerRatios(layout, live: bonsplitController.treeSnapshot())
            return
        }
        let focused = focusedPanelId.flatMap { surfaceIdFromPanelId($0) }
        // The existing remote-projection transaction preserves window/workspace
        // focus and suppresses activation while tabs move. It is shared with SSH.
        performRemoteTmuxMirrorMutation {
            let wasProgrammatic = isProgrammaticSplit
            isProgrammaticSplit = true
            defer { isProgrammaticSplit = wasProgrammatic }
            guard let root = bonsplitController.allPaneIds.first else { return }
            let originalRootTabs = Set(bonsplitController.tabs(inPane: root).map(\.id))
            for placement in layout.placements {
                guard let tab = tabs[placement] else { continue }
                if !originalRootTabs.contains(tab) {
                    _ = bonsplitController.moveTab(tab, toPane: root)
                }
            }
            buildCloudLayout(layout, in: root, tabs: tabs)
            applyCloudDividerRatios(layout, live: bonsplitController.treeSnapshot())
            if let focused, bonsplitController.tab(focused) != nil { bonsplitController.selectTab(focused) }
        }
        scheduleTerminalGeometryReconcile()
    }

    private func cloudLayoutMatches(_ layout: SurfaceProjectionLayout, live: ExternalTreeNode,
                                    tabs: [SurfaceResourcePlacement: TabID]) -> Bool {
        switch (layout, live) {
        case (.leaf(let placements), .pane(let pane)):
            return placements.compactMap { tabs[$0]?.id.uuidString } == pane.tabs.map(\.id)
        case (.split(let direction, _, let first, let second), .split(let split)):
            let orientation = direction == .right || direction == .left ? "horizontal" : "vertical"
            return split.orientation == orientation && cloudLayoutMatches(first, live: split.first, tabs: tabs)
                && cloudLayoutMatches(second, live: split.second, tabs: tabs)
        default: return false
        }
    }

    private func buildCloudLayout(_ layout: SurfaceProjectionLayout, in pane: PaneID,
                                  tabs: [SurfaceResourcePlacement: TabID]) {
        switch layout {
        case .leaf(let placements):
            for (index, placement) in placements.enumerated() {
                if let tab = tabs[placement] { _ = bonsplitController.moveTab(tab, toPane: pane, atIndex: index) }
            }
        case .split(let direction, _, let first, let second):
            guard let placement = second.placements.first, let tab = tabs[placement],
                  let next = bonsplitController.splitPane(pane, orientation: direction == .right || direction == .left ? .horizontal : .vertical,
                                                         movingTab: tab, insertFirst: false) else { return }
            for placement in second.placements.dropFirst() {
                if let tab = tabs[placement] { _ = bonsplitController.moveTab(tab, toPane: next) }
            }
            buildCloudLayout(first, in: pane, tabs: tabs)
            buildCloudLayout(second, in: next, tabs: tabs)
        }
    }

    private func applyCloudDividerRatios(_ layout: SurfaceProjectionLayout, live: ExternalTreeNode) {
        guard case .split(_, let ratio, let first, let second) = layout, case .split(let split) = live else { return }
        if let id = UUID(uuidString: split.id), abs(split.dividerPosition - ratio) > 0.0001 {
            _ = bonsplitController.setDividerPosition(CGFloat(ratio), forSplit: id, fromExternal: true)
        }
        applyCloudDividerRatios(first, live: split.first)
        applyCloudDividerRatios(second, live: split.second)
    }
}
