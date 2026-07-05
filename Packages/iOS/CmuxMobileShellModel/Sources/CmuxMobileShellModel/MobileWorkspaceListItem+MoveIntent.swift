public import Foundation

/// List-move helpers derived from rendered list-item snapshots.
public extension MobileWorkspaceListItem {
    /// Resolves a SwiftUI `List` move into a Mac-facing workspace move intent.
    ///
    /// The `destination` index is the pre-removal index space reported by
    /// `ForEach.onMove`. Group headers are never movable, and ambiguous/no-op
    /// landings resolve to `nil`.
    ///
    /// - Parameters:
    ///   - items: The rendered workspace list snapshot backing the `List`.
    ///   - workspaces: The full workspace order from the Mac.
    ///   - groups: The group snapshots from the Mac.
    ///   - sourceOffsets: The moved row offsets from SwiftUI.
    ///   - destination: The destination offset from SwiftUI, in pre-removal space.
    /// - Returns: A workspace move intent, or `nil` when the move should not fire.
    static func moveIntent(
        items: [MobileWorkspaceListItem],
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceOffsets: IndexSet,
        destination: Int
    ) -> MobileWorkspaceMoveIntent? {
        guard sourceOffsets.count == 1,
              let sourceIndex = sourceOffsets.first,
              items.indices.contains(sourceIndex),
              case .workspace(let movedWorkspace, _) = items[sourceIndex] else {
            return nil
        }

        let rawDestination = min(max(destination, items.startIndex), items.endIndex)
        guard rawDestination != sourceIndex, rawDestination != sourceIndex + 1 else {
            return nil
        }
        let adjustedDestination = sourceIndex < rawDestination ? rawDestination - 1 : rawDestination
        var remainingItems = items
        remainingItems.remove(at: sourceIndex)
        let insertionIndex = min(max(adjustedDestination, remainingItems.startIndex), remainingItems.endIndex)

        let knownGroupIDs = Set(groups.map(\.id))
        let currentGroupID = validGroupID(movedWorkspace.groupID, knownGroupIDs: knownGroupIDs)
        let orderedWithoutMoved = workspaces.filter { $0.id != movedWorkspace.id }

        let previousItem = insertionIndex > remainingItems.startIndex
            ? remainingItems[remainingItems.index(before: insertionIndex)]
            : nil
        let nextItem = insertionIndex < remainingItems.endIndex
            ? remainingItems[insertionIndex]
            : nil

        let proposed: MobileWorkspaceMoveIntent?
        switch previousItem {
        case .groupHeader(let group, _):
            guard knownGroupIDs.contains(group.id) else { return nil }
            proposed = MobileWorkspaceMoveIntent(
                groupID: group.id,
                beforeWorkspaceID: firstNonAnchorWorkspace(
                    in: group.id,
                    groups: groups,
                    workspaces: orderedWithoutMoved,
                    knownGroupIDs: knownGroupIDs
                ) ?? workspaceAfterGroup(
                    group.id,
                    workspaces: orderedWithoutMoved,
                    knownGroupIDs: knownGroupIDs
                )
            )

        case .workspace(let previousWorkspace, _):
            let previousGroupID = validGroupID(previousWorkspace.groupID, knownGroupIDs: knownGroupIDs)
            if let previousGroupID {
                let beforeWorkspaceID: MobileWorkspacePreview.ID?
                if case .workspace(let nextWorkspace, _) = nextItem,
                   validGroupID(nextWorkspace.groupID, knownGroupIDs: knownGroupIDs) == previousGroupID {
                    beforeWorkspaceID = nextWorkspace.id
                } else {
                    beforeWorkspaceID = workspaceAfterGroup(
                        previousGroupID,
                        workspaces: orderedWithoutMoved,
                        knownGroupIDs: knownGroupIDs
                    )
                }
                proposed = MobileWorkspaceMoveIntent(
                    groupID: previousGroupID,
                    beforeWorkspaceID: beforeWorkspaceID
                )
            } else {
                proposed = MobileWorkspaceMoveIntent(
                    groupID: nil,
                    beforeWorkspaceID: ungroupedBeforeWorkspaceID(
                        nextItem: nextItem,
                        workspaces: orderedWithoutMoved,
                        knownGroupIDs: knownGroupIDs
                    )
                )
            }

        case nil:
            proposed = MobileWorkspaceMoveIntent(
                groupID: nil,
                beforeWorkspaceID: ungroupedBeforeWorkspaceID(
                    nextItem: nextItem,
                    workspaces: orderedWithoutMoved,
                    knownGroupIDs: knownGroupIDs
                )
            )
        }

        guard let intent = proposed else { return nil }
        guard intent.groupID != currentGroupID || changesOrder(
            draggedWorkspaceID: movedWorkspace.id,
            beforeWorkspaceID: intent.beforeWorkspaceID,
            workspaces: workspaces
        ) else {
            return nil
        }
        return intent
    }

    private static func ungroupedBeforeWorkspaceID(
        nextItem: MobileWorkspaceListItem?,
        workspaces: [MobileWorkspacePreview],
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspacePreview.ID? {
        switch nextItem {
        case .workspace(let nextWorkspace, _):
            return nextWorkspace.id
        case .groupHeader(let nextGroup, _):
            return firstWorkspace(
                in: nextGroup.id,
                workspaces: workspaces,
                knownGroupIDs: knownGroupIDs
            )
        case nil:
            return nil
        }
    }

    private static func validGroupID(
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, knownGroupIDs.contains(groupID) else { return nil }
        return groupID
    }

    private static func firstWorkspace(
        in groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview],
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspacePreview.ID? {
        workspaces.first(where: { validGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID })?.id
    }

    private static func firstNonAnchorWorkspace(
        in groupID: MobileWorkspaceGroupPreview.ID,
        groups: [MobileWorkspaceGroupPreview],
        workspaces: [MobileWorkspacePreview],
        knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
    ) -> MobileWorkspacePreview.ID? {
        guard let anchorWorkspaceID = groups.first(where: { $0.id == groupID })?.anchorWorkspaceID else {
            return nil
        }
        return workspaces.first(where: {
            validGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID && $0.id != anchorWorkspaceID
        })?.id
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
