import CmuxWorkspaces
import Foundation

/// Conforms the persisted layout enum (now owned by `CmuxWorkspaces`) to the
/// package node-build seam so `SessionRestoreCoordinator.sessionLayoutSnapshot(from:)`
/// can mint the persisted layout tree. The concrete pane/split DTOs live in
/// `CmuxWorkspaces`; this bridge stays in the app target, so the conformance is
/// `@retroactive`. Counterpart to the
/// `SessionWorkspaceLayoutSnapshot: SessionLayoutPruning` conformance.
extension SessionWorkspaceLayoutSnapshot: @retroactive SessionLayoutNodeBuilding {
    public static func sessionLayoutBuiltPane(
        panelIds: [UUID],
        selectedPanelId: UUID?
    ) -> SessionWorkspaceLayoutSnapshot {
        .pane(SessionPaneLayoutSnapshot(panelIds: panelIds, selectedPanelId: selectedPanelId))
    }

    public static func sessionLayoutBuiltSplit(
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
