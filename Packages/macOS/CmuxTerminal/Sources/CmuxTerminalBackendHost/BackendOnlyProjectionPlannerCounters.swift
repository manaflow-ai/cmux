/// Mutable counters confined to one synchronous planner invocation.
nonisolated struct BackendOnlyProjectionPlannerCounters {
    var topologyWorkspaceIndexVisits = 0
    var navigationWorkspaceIndexVisits = 0
    var selectedWorkspaceScreenIndexVisits = 0
    var selectedNavigationScreenIndexVisits = 0
    var selectedScreenPaneIndexVisits = 0
    var selectedNavigationPaneIndexVisits = 0
    var visibleLeafCountNodeVisits = 0
    var materializedLayoutNodeVisits = 0
    var tabMetadataVisits = 0

    func snapshot(visibleLeafCount: Int) -> BackendOnlyProjectionPlannerMetrics {
        BackendOnlyProjectionPlannerMetrics(
            visibleLeafCount: visibleLeafCount,
            topologyWorkspaceIndexVisits: topologyWorkspaceIndexVisits,
            navigationWorkspaceIndexVisits: navigationWorkspaceIndexVisits,
            selectedWorkspaceScreenIndexVisits: selectedWorkspaceScreenIndexVisits,
            selectedNavigationScreenIndexVisits: selectedNavigationScreenIndexVisits,
            selectedScreenPaneIndexVisits: selectedScreenPaneIndexVisits,
            selectedNavigationPaneIndexVisits: selectedNavigationPaneIndexVisits,
            visibleLeafCountNodeVisits: visibleLeafCountNodeVisits,
            materializedLayoutNodeVisits: materializedLayoutNodeVisits,
            tabMetadataVisits: tabMetadataVisits
        )
    }
}
