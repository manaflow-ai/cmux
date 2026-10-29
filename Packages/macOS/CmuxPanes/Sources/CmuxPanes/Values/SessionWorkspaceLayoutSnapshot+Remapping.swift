public import Foundation

extension SessionWorkspaceLayoutSnapshot {
    /// Replaces panel identities in every leaf while preserving topology and selection.
    ///
    /// - Parameter panelIDMap: Old-to-new identities; missing keys remain unchanged.
    /// - Returns: A value snapshot suitable for history migration or session restore.
    public func remappingPanelIDs(_ panelIDMap: [UUID: UUID]) -> Self {
        switch self {
        case .pane(let pane):
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: pane.panelIds.map { panelIDMap[$0] ?? $0 },
                selectedPanelId: pane.selectedPanelId.map { panelIDMap[$0] ?? $0 },
                isFullWidthTabMode: pane.isFullWidthTabMode
            ))
        case .split(let split):
            return .split(SessionSplitLayoutSnapshot(
                orientation: split.orientation,
                dividerPosition: split.dividerPosition,
                first: split.first.remappingPanelIDs(panelIDMap),
                second: split.second.remappingPanelIDs(panelIDMap)
            ))
        }
    }
}
