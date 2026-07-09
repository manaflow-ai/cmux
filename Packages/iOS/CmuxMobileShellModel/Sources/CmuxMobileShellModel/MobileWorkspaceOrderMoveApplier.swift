/// Applies pending workspace move intents to a local workspace snapshot.
struct MobileWorkspaceOrderMoveApplier {
    let workspaces: [MobileWorkspacePreview]

    func applying(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        if intent.movesGroup,
           let movedGroupID = workspaces.first(where: { $0.id == movedWorkspaceID })?.groupID {
            return applyingGroupMove(
                movedGroupID: movedGroupID,
                beforeWorkspaceID: intent.beforeWorkspaceID
            )
        }
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return workspaces
        }
        var moved = workspaces[currentIndex]
        moved.groupID = intent.groupID
        var remaining = workspaces
        remaining.remove(at: currentIndex)
        let insertionIndex: Int
        if let beforeWorkspaceID = intent.beforeWorkspaceID,
           let targetIndex = remaining.firstIndex(where: { $0.id == beforeWorkspaceID }) {
            insertionIndex = targetIndex
        } else if let groupID = intent.groupID,
                  let lastMemberIndex = remaining.lastIndex(where: { $0.groupID == groupID }) {
            insertionIndex = remaining.index(after: lastMemberIndex)
        } else {
            insertionIndex = remaining.endIndex
        }
        remaining.insert(moved, at: insertionIndex)
        return remaining
    }

    func applyingGroupMove(
        movedGroupID: MobileWorkspaceGroupPreview.ID,
        beforeWorkspaceID: MobileWorkspacePreview.ID?
    ) -> [MobileWorkspacePreview] {
        let movedGroup = workspaces.filter { $0.groupID == movedGroupID }
        guard !movedGroup.isEmpty else { return workspaces }
        var remaining = workspaces.filter { $0.groupID != movedGroupID }
        let insertionIndex: Int
        if let beforeWorkspaceID,
           let beforeWorkspace = remaining.first(where: { $0.id == beforeWorkspaceID }) {
            let beforeGroupID = beforeWorkspace.groupID
            insertionIndex = remaining.firstIndex {
                if let beforeGroupID {
                    $0.groupID == beforeGroupID
                } else {
                    $0.id == beforeWorkspaceID
                }
            } ?? remaining.endIndex
        } else {
            insertionIndex = remaining.endIndex
        }
        remaining.insert(contentsOf: movedGroup, at: insertionIndex)
        return remaining
    }
}
