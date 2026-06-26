import CmuxWorkspaces
import Foundation

/// Conforms the app-owned persisted layout enum to the package node-build seam
/// so `SessionRestoreCoordinator.sessionLayoutSnapshot(from:)` can mint the
/// persisted layout tree while the wire format and concrete pane/split DTOs
/// stay owned by the app target. Counterpart to the
/// `SessionWorkspaceLayoutSnapshot: SessionLayoutPruning` conformance.
extension SessionWorkspaceLayoutSnapshot: SessionLayoutNodeBuilding {
    static func sessionLayoutBuiltPane(
        panelIds: [UUID],
        selectedPanelId: UUID?
    ) -> SessionWorkspaceLayoutSnapshot {
        .pane(SessionPaneLayoutSnapshot(panelIds: panelIds, selectedPanelId: selectedPanelId))
    }

    static func sessionLayoutBuiltSplit(
        isVertical: Bool,
        dividerPosition: Double,
        first: SessionWorkspaceLayoutSnapshot,
        second: SessionWorkspaceLayoutSnapshot
    ) -> SessionWorkspaceLayoutSnapshot {
        .split(
            SessionSplitLayoutSnapshot(
                orientation: isVertical ? .vertical : .horizontal,
                dividerPosition: dividerPosition,
                first: first,
                second: second
            )
        )
    }
}
