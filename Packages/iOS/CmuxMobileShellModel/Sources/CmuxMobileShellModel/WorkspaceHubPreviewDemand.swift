/// The preview surfaces demanded by the currently visible hub panes.
public struct WorkspaceHubPreviewDemand: Equatable, Sendable {
    /// Active-tab surface identifiers for visible panes only.
    public let surfaceIDs: Set<String>

    /// Derives preview demand from immutable pane snapshots and visibility.
    /// - Parameters:
    ///   - panes: All panes in the current authoritative hub projection.
    ///   - visiblePaneIDs: Pane identifiers currently intersecting the scroll viewport.
    public init(panes: [WorkspaceHubPaneSnapshot], visiblePaneIDs: Set<String>) {
        surfaceIDs = Set(panes.compactMap { pane in
            guard visiblePaneIDs.contains(pane.id) else { return nil }
            return pane.activeSurfaceID
        })
    }
}
