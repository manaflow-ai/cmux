public import Foundation

/// Resolves the ordered workspace block represented by a sidebar drag.
public struct SidebarWorkspaceDragBlockResolver: Sendable {
    /// Creates a sidebar workspace drag-block resolver.
    public init() {}

    /// Returns the workspaces that move with the dragged row, in sidebar order.
    ///
    /// A multi-selection expands only when it contains the dragged workspace.
    /// Workspace drags exclude group anchors. A selected anchor expands to the
    /// other selected anchors when at least two anchors are selected, while an
    /// unselected or singly selected anchor moves alone.
    ///
    /// - Parameters:
    ///   - orderedWorkspaceIds: Live workspace ids in sidebar order.
    ///   - selectedIds: The current sidebar multi-selection.
    ///   - draggedId: The workspace whose row started the drag.
    ///   - anchorIds: Workspace ids that anchor groups.
    /// - Returns: The ordered workspace ids represented by the drag.
    public func movingWorkspaceIds(
        orderedWorkspaceIds: [UUID],
        selectedIds: Set<UUID>,
        draggedId: UUID,
        anchorIds: Set<UUID>
    ) -> [UUID] {
        if anchorIds.contains(draggedId) {
            let selectedAnchorIds = selectedIds.intersection(anchorIds)
            guard selectedIds.contains(draggedId),
                  selectedAnchorIds.count > 1 else {
                return [draggedId]
            }
            return orderedWorkspaceIds.filter {
                selectedIds.contains($0) && anchorIds.contains($0)
            }
        }
        guard selectedIds.count > 1,
              selectedIds.contains(draggedId) else {
            return [draggedId]
        }
        return orderedWorkspaceIds.filter {
            selectedIds.contains($0) && !anchorIds.contains($0)
        }
    }
}
