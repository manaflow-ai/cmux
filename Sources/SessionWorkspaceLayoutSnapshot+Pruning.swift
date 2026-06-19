import CmuxWorkspaces
import Foundation

/// Conforms the app-owned persisted layout enum to the package prune seam so
/// the recursive prune algorithm lives in `CmuxWorkspaces` while the wire
/// format and concrete pane/split DTOs stay in the app target.
extension SessionWorkspaceLayoutSnapshot: SessionLayoutPruning {
    var sessionLayoutPruneCase: SessionLayoutPruneCase<SessionWorkspaceLayoutSnapshot> {
        switch self {
        case .pane(let pane):
            return .pane(panelIds: pane.panelIds, selectedPanelId: pane.selectedPanelId)
        case .split(let split):
            return .split(
                dividerPosition: split.dividerPosition,
                first: split.first,
                second: split.second
            )
        }
    }

    static func sessionLayoutPrunedPane(
        panelIds: [UUID],
        selectedPanelId: UUID?
    ) -> SessionWorkspaceLayoutSnapshot {
        .pane(SessionPaneLayoutSnapshot(panelIds: panelIds, selectedPanelId: selectedPanelId))
    }

    func sessionLayoutPrunedSplit(
        dividerPosition: Double,
        first: SessionWorkspaceLayoutSnapshot,
        second: SessionWorkspaceLayoutSnapshot
    ) -> SessionWorkspaceLayoutSnapshot {
        guard case .split(let split) = self else {
            // The prune algorithm only rebuilds splits from split nodes, so
            // this branch is unreachable; preserve the children with a
            // horizontal default to keep the method total.
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: .horizontal,
                    dividerPosition: dividerPosition,
                    first: first,
                    second: second
                )
            )
        }
        return .split(
            SessionSplitLayoutSnapshot(
                orientation: split.orientation,
                dividerPosition: dividerPosition,
                first: first,
                second: second
            )
        )
    }
}
