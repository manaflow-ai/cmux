public import Foundation

/// Keeps sidebar multi-selection homogeneous between workspaces and group anchors.
public struct SidebarSelectionKindPolicy: Sendable {
    /// Creates a sidebar selection-kind policy.
    public init() {}

    /// Produces a workspace command-click selection after removing group anchors.
    ///
    /// - Parameters:
    ///   - current: The current sidebar selection.
    ///   - clickedId: The workspace id being toggled.
    ///   - anchorIds: The workspace ids serving as group anchors.
    /// - Returns: A workspace-only selection with `clickedId` toggled.
    public func workspaceCmdClickSelection(
        current: Set<UUID>,
        clickedId: UUID,
        anchorIds: Set<UUID>
    ) -> Set<UUID> {
        var selectedIds = current.subtracting(anchorIds)
        if selectedIds.contains(clickedId) {
            selectedIds.remove(clickedId)
        } else {
            selectedIds.insert(clickedId)
        }
        return selectedIds
    }

    /// Produces a group-anchor command-click selection after removing workspaces.
    ///
    /// - Parameters:
    ///   - current: The current sidebar selection.
    ///   - clickedAnchorId: The group-anchor id being toggled.
    ///   - anchorIds: All live group-anchor workspace ids.
    /// - Returns: An anchor-only selection with `clickedAnchorId` toggled.
    public func anchorCmdClickSelection(
        current: Set<UUID>,
        clickedAnchorId: UUID,
        anchorIds: Set<UUID>
    ) -> Set<UUID> {
        var selectedIds = current.intersection(anchorIds)
        if selectedIds.contains(clickedAnchorId) {
            selectedIds.remove(clickedAnchorId)
        } else {
            selectedIds.insert(clickedAnchorId)
        }
        return selectedIds
    }

    /// Removes group-anchor ids from a workspace shift-click range.
    ///
    /// - Parameters:
    ///   - rangeIds: Workspace ids in range order.
    ///   - anchorIds: All live group-anchor workspace ids.
    /// - Returns: The range ids that are not group anchors.
    public func workspaceShiftRangeIds(
        rangeIds: [UUID],
        anchorIds: Set<UUID>
    ) -> [UUID] {
        rangeIds.filter { !anchorIds.contains($0) }
    }
}
