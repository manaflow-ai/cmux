/// Resolves mobile workspace drag/drop targets into Mac mutation intents.
public enum MobileWorkspaceDropIntentResolver {
    /// Returns the Mac-facing move intent for a drop, or `nil` for no-op/invalid drops.
    /// - Parameters:
    ///   - workspaces: The full workspace order from the Mac.
    ///   - groups: The group snapshots from the Mac.
    ///   - draggedWorkspaceID: The workspace being dragged.
    ///   - target: The drop landing target.
    /// - Returns: A move intent carrying the target group and insertion anchor.
    public static func intent(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        draggedWorkspaceID: MobileWorkspacePreview.ID,
        target: MobileWorkspaceDropTarget
    ) -> MobileWorkspaceMoveIntent? {
        guard let draggedWorkspace = workspaces.first(where: { $0.id == draggedWorkspaceID }) else {
            return nil
        }
        let knownGroupIDs = Set(groups.map(\.id))
        let currentGroupID = validGroupID(draggedWorkspace.groupID, knownGroupIDs: knownGroupIDs)
        let orderedWithoutDragged = workspaces.filter { $0.id != draggedWorkspaceID }

        let proposed: MobileWorkspaceMoveIntent?
        switch target {
        case .groupHeader(let groupID):
            guard knownGroupIDs.contains(groupID) else { return nil }
            proposed = MobileWorkspaceMoveIntent(
                groupID: groupID,
                beforeWorkspaceID: workspaceAfterGroup(
                    groupID,
                    workspaces: orderedWithoutDragged,
                    knownGroupIDs: knownGroupIDs
                )
            )
        case .beforeWorkspace(let targetID):
            guard targetID != draggedWorkspaceID,
                  let targetWorkspace = workspaces.first(where: { $0.id == targetID }) else {
                return nil
            }
            proposed = MobileWorkspaceMoveIntent(
                groupID: validGroupID(targetWorkspace.groupID, knownGroupIDs: knownGroupIDs),
                beforeWorkspaceID: targetID
            )
        case .afterWorkspace(let targetID):
            guard targetID != draggedWorkspaceID,
                  let targetWorkspace = workspaces.first(where: { $0.id == targetID }),
                  let targetIndex = orderedWithoutDragged.firstIndex(where: { $0.id == targetID }) else {
                return nil
            }
            let nextIndex = orderedWithoutDragged.index(after: targetIndex)
            proposed = MobileWorkspaceMoveIntent(
                groupID: validGroupID(targetWorkspace.groupID, knownGroupIDs: knownGroupIDs),
                beforeWorkspaceID: nextIndex < orderedWithoutDragged.endIndex
                    ? orderedWithoutDragged[nextIndex].id
                    : nil
            )
        }

        guard let intent = proposed else { return nil }
        guard intent.groupID != currentGroupID || changesOrder(
            draggedWorkspaceID: draggedWorkspaceID,
            beforeWorkspaceID: intent.beforeWorkspaceID,
            workspaces: workspaces
        ) else {
            return nil
        }
        return intent
    }

    private static func validGroupID(
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, knownGroupIDs.contains(groupID) else { return nil }
        return groupID
    }

    private static func workspaceAfterGroup(
        _ groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview],
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspacePreview.ID? {
        guard let lastMemberIndex = workspaces.lastIndex(where: {
            validGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID
        }) else {
            return nil
        }
        let nextIndex = workspaces.index(after: lastMemberIndex)
        guard nextIndex < workspaces.endIndex else { return nil }
        return workspaces[nextIndex].id
    }

    private static func changesOrder(
        draggedWorkspaceID: MobileWorkspacePreview.ID,
        beforeWorkspaceID: MobileWorkspacePreview.ID?,
        workspaces: [MobileWorkspacePreview]
    ) -> Bool {
        var ids = workspaces.map(\.id)
        guard let currentIndex = ids.firstIndex(of: draggedWorkspaceID) else { return false }
        ids.remove(at: currentIndex)
        let targetIndex = beforeWorkspaceID.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex
        ids.insert(draggedWorkspaceID, at: targetIndex)
        return ids != workspaces.map(\.id)
    }
}
