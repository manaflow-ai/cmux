enum SidebarWorkspaceSelectionReducer {
    struct Result<ID: Hashable>: Equatable {
        let selectedIds: Set<ID>
        let anchorIndex: Int?
    }

    static func select<ID: Hashable>(
        workspaceId: ID,
        index: Int,
        workspaceIds: [ID],
        selectedIds: Set<ID>,
        anchorIndex: Int?,
        isCommand: Bool,
        isShift: Bool
    ) -> Result<ID> {
        if isShift,
           let anchorIndex,
           workspaceIds.indices.contains(anchorIndex),
           workspaceIds.indices.contains(index) {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            let rangeIds = Set(workspaceIds[lower...upper])
            return Result(
                selectedIds: isCommand ? selectedIds.union(rangeIds) : rangeIds,
                anchorIndex: anchorIndex
            )
        }

        if isCommand {
            var nextSelectedIds = selectedIds
            if nextSelectedIds.contains(workspaceId) {
                nextSelectedIds.remove(workspaceId)
            } else {
                nextSelectedIds.insert(workspaceId)
            }
            return Result(selectedIds: nextSelectedIds, anchorIndex: index)
        }

        return Result(selectedIds: [workspaceId], anchorIndex: index)
    }
}
