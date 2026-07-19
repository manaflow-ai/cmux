/// Deterministic visit counts for planner complexity assertions.
nonisolated struct BackendOnlyProjectionPlannerMetrics: Equatable, Sendable {
    let visibleLeafCount: Int
    let topologyWorkspaceIndexVisits: Int
    let navigationWorkspaceIndexVisits: Int
    let selectedWorkspaceScreenIndexVisits: Int
    let selectedNavigationScreenIndexVisits: Int
    let selectedScreenPaneIndexVisits: Int
    let selectedNavigationPaneIndexVisits: Int
    let visibleLeafCountNodeVisits: Int
    let materializedLayoutNodeVisits: Int
    let tabMetadataVisits: Int
}
