public import Foundation

/// Resolves the ordered workspace block represented by a sidebar drag.
public struct SidebarWorkspaceDragBlockResolver: Sendable {
    /// Creates a sidebar workspace drag-block resolver.
    public init() {}

    /// Returns the workspaces that move with the dragged row, in sidebar order.
    ///
    /// A multi-selection expands only when it contains the dragged workspace.
    /// Group anchors are excluded from expanded selections, while dragging an
    /// anchor itself preserves the existing single-anchor behavior.
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
        guard !anchorIds.contains(draggedId),
              selectedIds.count > 1,
              selectedIds.contains(draggedId) else {
            return [draggedId]
        }
        return orderedWorkspaceIds.filter {
            selectedIds.contains($0) && !anchorIds.contains($0)
        }
    }
}
