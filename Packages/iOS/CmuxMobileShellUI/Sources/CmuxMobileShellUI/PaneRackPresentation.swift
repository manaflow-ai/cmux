import CmuxMobileShell

/// Pure visibility and ordering policy for one Pane Rack snapshot.
struct PaneRackPresentation: Equatable {
    let stagedPane: PaneRackPaneSnapshot?
    let strips: [PaneRackPaneSnapshot]
    let showsHeader: Bool

    init(snapshot: PaneRackSnapshot) {
        let resolvedStagedPane = snapshot.panes.first { $0.id == snapshot.stagedPaneID }
            ?? snapshot.panes.first
        stagedPane = resolvedStagedPane
        strips = snapshot.panes.filter { $0.id != resolvedStagedPane?.id }
        showsHeader = snapshot.panes.count > 1 || (resolvedStagedPane?.tabs.count ?? 0) > 1
    }

    func interestedSurfaceIDs(isUnfolded: Bool) -> Set<String> {
        var surfaceIDs = Set(strips.compactMap { $0.selectedTab?.id.rawValue })
        if isUnfolded, let stagedPane {
            surfaceIDs.formUnion(stagedPane.tabs.map { $0.id.rawValue })
        }
        return surfaceIDs
    }
}

extension PaneRackPaneSnapshot {
    /// Effective selected tab, with a first-tab fallback for transient snapshots.
    var selectedTab: PaneRackTabSnapshot? {
        if let selectedTabID,
           let selected = tabs.first(where: { $0.id == selectedTabID }) {
            return selected
        }
        return tabs.first
    }
}
