import CmuxFoundation
import Foundation

/// Maps the live reorder indicator onto per-row drop-line flags for the
/// AppKit sidebar table. Wraps the shared `SidebarTabDropIndicatorPredicate`
/// (identical gap semantics to the SwiftUI sidebar) and additionally
/// suppresses lines on the row being dragged: AppKit snapshots that row as
/// the drag image lazily, so any line painted there gets baked into the
/// ghost and travels with the pointer for the rest of the drag.
struct SidebarWorkspaceTableReorderIndicatorPainter {
    let indicator: SidebarDropIndicator?
    let scope: SidebarWorkspaceReorderDropIndicatorScope
    let draggedWorkspaceId: UUID
    /// Scope-filtered row ids in display order, from the same
    /// `sidebarDropIndicatorRowIds` computation the SwiftUI sidebar feeds the
    /// predicate, so adjacency and end-of-scope answers cannot diverge.
    let indicatorRowIds: [UUID]

    func paint(forRowWorkspaceId rowWorkspaceId: UUID) -> (top: Bool, bottom: Bool) {
        guard indicator != nil else { return (false, false) }
        guard rowWorkspaceId != draggedWorkspaceId else { return (false, false) }
        let predicate = SidebarTabDropIndicatorPredicate()
        return (
            top: predicate.topVisible(
                forTabId: rowWorkspaceId,
                draggedTabId: draggedWorkspaceId,
                dropIndicator: indicator,
                tabIds: indicatorRowIds
            ),
            bottom: predicate.bottomVisible(
                forTabId: rowWorkspaceId,
                draggedTabId: draggedWorkspaceId,
                dropIndicator: indicator,
                tabIds: indicatorRowIds,
                indicatorScope: scope
            )
        )
    }
}
