import CmuxMobileShellModel

/// Immutable workspace and status state rendered by ``PaneMapOverlay``.
struct PaneMapValue: Equatable {
    let workspaceName: String
    let layout: MobilePaneLayout
    let phoneSelectedSurfaceID: String?
    let agentStateKindsBySurfaceID: [String: ChatAgentStateKind]

    var panes: [MobilePaneNode] { layout.orderedPanes }

    var tabCount: Int {
        panes.reduce(into: 0) { count, pane in
            count += pane.surfaces.count
        }
    }

    var initialSurfaceIDsByPaneID: [String: String] {
        reconciledSurfaceIDs(current: [:])
    }

    /// Keeps valid in-map selections and replaces entries removed by a newer
    /// layout snapshot with that pane's authoritative fallback selection.
    func reconciledSurfaceIDs(current: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for pane in panes {
            if let currentSurfaceID = current[pane.id],
               pane.surfaces.contains(where: { $0.id == currentSurfaceID }) {
                result[pane.id] = currentSurfaceID
                continue
            }

            let phoneSurfaceID = phoneSelectedSurfaceID.flatMap { candidate in
                pane.surfaces.contains { $0.id == candidate } ? candidate : nil
            }
            let paneSurfaceID = pane.selectedSurfaceID.flatMap { candidate in
                pane.surfaces.contains { $0.id == candidate } ? candidate : nil
            }
            if let surfaceID = phoneSurfaceID ?? paneSurfaceID ?? pane.surfaces.first?.id {
                result[pane.id] = surfaceID
            }
        }
        return result
    }
}
