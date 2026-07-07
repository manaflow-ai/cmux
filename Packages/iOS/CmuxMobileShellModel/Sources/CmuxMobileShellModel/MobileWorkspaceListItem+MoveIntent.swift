public import Foundation

extension Array where Element == MobileWorkspaceListItem {
    /// Resolves a SwiftUI `List` move into a Mac-facing workspace move intent.
    ///
    /// The `destination` index is the pre-removal index space reported by
    /// `ForEach.onMove`. Group headers move their anchor workspace, synthetic
    /// footers are never movable, and identity/no-op landings resolve to `nil`.
    ///
    /// - Parameters:
    ///   - workspaces: The full workspace order from the Mac.
    ///   - groups: The group snapshots from the Mac.
    ///   - sourceOffsets: The moved row offsets from SwiftUI.
    ///   - destination: The destination offset from SwiftUI, in pre-removal space.
    /// - Returns: A workspace move intent, or `nil` when the move should not fire.
    public func moveIntent(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceOffsets: IndexSet,
        destination: Int
    ) -> MobileWorkspaceMoveIntent? {
        guard sourceOffsets.count == 1,
              let sourceIndex = sourceOffsets.first,
              indices.contains(sourceIndex),
              let movedWorkspace = mobileWorkspaceMovedWorkspace(
                for: self[sourceIndex],
                workspaces: workspaces
              ) else {
            return nil
        }

        let rawDestination = Swift.min(Swift.max(destination, startIndex), endIndex)
        guard rawDestination != sourceIndex, rawDestination != sourceIndex + 1 else {
            return nil
        }
        let adjustedDestination = sourceIndex < rawDestination ? rawDestination - 1 : rawDestination
        var remainingItems = self
        remainingItems.remove(at: sourceIndex)
        let insertionIndex = Swift.min(
            Swift.max(adjustedDestination, remainingItems.startIndex),
            remainingItems.endIndex
        )

        let knownGroupIDs = Set(groups.map(\.id))
        let currentGroupID = mobileWorkspaceValidGroupID(movedWorkspace.groupID, knownGroupIDs: knownGroupIDs)
        let orderedWithoutMoved = workspaces.filter { $0.id != movedWorkspace.id }

        let previousItem = insertionIndex > remainingItems.startIndex
            ? remainingItems[remainingItems.index(before: insertionIndex)]
            : nil
        let nextItem = insertionIndex < remainingItems.endIndex
            ? remainingItems[insertionIndex]
            : nil

        let movesGroup = mobileWorkspaceListItemIsGroupHeader(self[sourceIndex])
        let proposed = movesGroup
            ? mobileWorkspaceRootLevelIntent(
                nextItem: nextItem,
                workspaces: orderedWithoutMoved,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )
            : mobileWorkspaceProposedIntent(
                previousItem: previousItem,
                nextItem: nextItem,
                workspaces: orderedWithoutMoved,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )

        guard let intent = proposed else { return nil }
        let changesWorkspaceOrder = if movesGroup {
            currentGroupID.map {
                mobileWorkspaceChangesGroupOrder(
                    movedGroupID: $0,
                    beforeWorkspaceID: intent.beforeWorkspaceID,
                    workspaces: workspaces
                )
            } ?? false
        } else {
            intent.groupID != currentGroupID || mobileWorkspaceChangesOrder(
                draggedWorkspaceID: movedWorkspace.id,
                beforeWorkspaceID: intent.beforeWorkspaceID,
                workspaces: workspaces
            )
        }
        guard changesWorkspaceOrder else {
            return nil
        }
        return MobileWorkspaceMoveIntent(
            groupID: intent.groupID,
            beforeWorkspaceID: intent.beforeWorkspaceID,
            movesGroup: movesGroup
        )
    }
}

extension Array where Element == MobileWorkspacePreview {
    /// Returns the workspace order after optimistically applying a move intent.
    ///
    /// The returned order is used as the authoritative-order stand-in while the
    /// Mac move RPC is pending.
    ///
    /// - Parameters:
    ///   - intent: The move intent derived from the rendered list snapshot.
    ///   - movedWorkspaceID: The dragged workspace, or a moved group's anchor workspace.
    /// - Returns: A workspace snapshot with the move applied.
    public func applyingWorkspaceMoveIntent(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        if intent.movesGroup,
           let movedGroupID = first(where: { $0.id == movedWorkspaceID })?.groupID {
            return mobileWorkspaceWorkspacesApplyingGroupMove(
                movedGroupID: movedGroupID,
                beforeWorkspaceID: intent.beforeWorkspaceID,
                workspaces: self
            )
        }
        guard let currentIndex = firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return self
        }
        var moved = self[currentIndex]
        moved.groupID = intent.groupID
        var remaining = self
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
}

private func mobileWorkspaceMovedWorkspace(
    for item: MobileWorkspaceListItem,
    workspaces: [MobileWorkspacePreview]
) -> MobileWorkspacePreview? {
    switch item {
    case .workspace(let workspace, _):
        return workspace
    case .groupHeader(let group, _):
        return workspaces.first { $0.id == group.anchorWorkspaceID }
    case .groupFooter:
        return nil
    }
}

private func mobileWorkspaceListItemIsGroupHeader(_ item: MobileWorkspaceListItem) -> Bool {
    if case .groupHeader = item {
        return true
    }
    return false
}

private func mobileWorkspaceProposedIntent(
    previousItem: MobileWorkspaceListItem?,
    nextItem: MobileWorkspaceListItem?,
    workspaces: [MobileWorkspacePreview],
    groups: [MobileWorkspaceGroupPreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspaceMoveIntent? {
    switch previousItem {
    case .groupHeader(let group, _):
        guard knownGroupIDs.contains(group.id) else { return nil }
        if group.isCollapsed {
            return mobileWorkspaceRootLevelIntent(
                nextItem: nextItem,
                workspaces: workspaces,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )
        }
        return MobileWorkspaceMoveIntent(
            groupID: group.id,
            beforeWorkspaceID: mobileWorkspaceFirstNonAnchorWorkspace(
                in: group.id,
                groups: groups,
                workspaces: workspaces,
                knownGroupIDs: knownGroupIDs
            ) ?? mobileWorkspaceWorkspaceAfterGroup(
                group.id,
                workspaces: workspaces,
                knownGroupIDs: knownGroupIDs
            )
        )

    case .groupFooter:
        return mobileWorkspaceRootLevelIntent(
            nextItem: nextItem,
            workspaces: workspaces,
            groups: groups,
            knownGroupIDs: knownGroupIDs
        )

    case .workspace(let previousWorkspace, _):
        let previousGroupID = mobileWorkspaceValidGroupID(previousWorkspace.groupID, knownGroupIDs: knownGroupIDs)
        guard let previousGroupID else {
            return mobileWorkspaceRootLevelIntent(
                nextItem: nextItem,
                workspaces: workspaces,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )
        }

        switch nextItem {
        case .workspace(let nextWorkspace, _):
            if mobileWorkspaceValidGroupID(nextWorkspace.groupID, knownGroupIDs: knownGroupIDs) == previousGroupID {
                return MobileWorkspaceMoveIntent(
                    groupID: previousGroupID,
                    beforeWorkspaceID: nextWorkspace.id
                )
            }
            return mobileWorkspaceRootLevelIntent(
                nextItem: nextItem,
                workspaces: workspaces,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )

        case .groupFooter(let footerGroupID):
            guard footerGroupID == previousGroupID else {
                return mobileWorkspaceRootLevelIntent(
                    nextItem: nextItem,
                    workspaces: workspaces,
                    groups: groups,
                    knownGroupIDs: knownGroupIDs
                )
            }
            return MobileWorkspaceMoveIntent(
                groupID: previousGroupID,
                beforeWorkspaceID: mobileWorkspaceWorkspaceAfterGroup(
                    previousGroupID,
                    workspaces: workspaces,
                    knownGroupIDs: knownGroupIDs
                )
            )

        case .groupHeader, nil:
            return mobileWorkspaceRootLevelIntent(
                nextItem: nextItem,
                workspaces: workspaces,
                groups: groups,
                knownGroupIDs: knownGroupIDs
            )
        }

    case nil:
        return mobileWorkspaceRootLevelIntent(
            nextItem: nextItem,
            workspaces: workspaces,
            groups: groups,
            knownGroupIDs: knownGroupIDs
        )
    }
}

private func mobileWorkspaceWorkspacesApplyingGroupMove(
    movedGroupID: MobileWorkspaceGroupPreview.ID,
    beforeWorkspaceID: MobileWorkspacePreview.ID?,
    workspaces: [MobileWorkspacePreview]
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

private func mobileWorkspaceRootLevelIntent(
    nextItem: MobileWorkspaceListItem?,
    workspaces: [MobileWorkspacePreview],
    groups: [MobileWorkspaceGroupPreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspaceMoveIntent {
    MobileWorkspaceMoveIntent(
        groupID: nil,
        beforeWorkspaceID: mobileWorkspaceRootLevelBeforeWorkspaceID(
            nextItem: nextItem,
            workspaces: workspaces,
            groups: groups,
            knownGroupIDs: knownGroupIDs
        )
    )
}

private func mobileWorkspaceRootLevelBeforeWorkspaceID(
    nextItem: MobileWorkspaceListItem?,
    workspaces: [MobileWorkspacePreview],
    groups: [MobileWorkspaceGroupPreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspacePreview.ID? {
    switch nextItem {
    case .workspace(let nextWorkspace, _):
        return nextWorkspace.id
    case .groupHeader(let nextGroup, _):
        return mobileWorkspaceFirstWorkspace(
            in: nextGroup.id,
            workspaces: workspaces,
            knownGroupIDs: knownGroupIDs
        )
    case .groupFooter(let groupID):
        return mobileWorkspaceWorkspaceAfterGroup(
            groupID,
            workspaces: workspaces,
            knownGroupIDs: knownGroupIDs
        ) ?? mobileWorkspaceFirstWorkspace(
            in: groupID,
            workspaces: workspaces,
            knownGroupIDs: knownGroupIDs
        ) ?? groups.first(where: { $0.id == groupID })?.anchorWorkspaceID
    case nil:
        return nil
    }
}

private func mobileWorkspaceValidGroupID(
    _ groupID: MobileWorkspaceGroupPreview.ID?,
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspaceGroupPreview.ID? {
    guard let groupID, knownGroupIDs.contains(groupID) else { return nil }
    return groupID
}

private func mobileWorkspaceFirstWorkspace(
    in groupID: MobileWorkspaceGroupPreview.ID,
    workspaces: [MobileWorkspacePreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspacePreview.ID? {
    workspaces.first(where: {
        mobileWorkspaceValidGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID
    })?.id
}

private func mobileWorkspaceFirstNonAnchorWorkspace(
    in groupID: MobileWorkspaceGroupPreview.ID,
    groups: [MobileWorkspaceGroupPreview],
    workspaces: [MobileWorkspacePreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspacePreview.ID? {
    guard let anchorWorkspaceID = groups.first(where: { $0.id == groupID })?.anchorWorkspaceID else {
        return nil
    }
    return workspaces.first(where: {
        mobileWorkspaceValidGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID && $0.id != anchorWorkspaceID
    })?.id
}

private func mobileWorkspaceWorkspaceAfterGroup(
    _ groupID: MobileWorkspaceGroupPreview.ID,
    workspaces: [MobileWorkspacePreview],
    knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>
) -> MobileWorkspacePreview.ID? {
    guard let lastMemberIndex = workspaces.lastIndex(where: {
        mobileWorkspaceValidGroupID($0.groupID, knownGroupIDs: knownGroupIDs) == groupID
    }) else {
        return nil
    }
    let nextIndex = workspaces.index(after: lastMemberIndex)
    guard nextIndex < workspaces.endIndex else { return nil }
    return workspaces[nextIndex].id
}

private func mobileWorkspaceChangesOrder(
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

private func mobileWorkspaceChangesGroupOrder(
    movedGroupID: MobileWorkspaceGroupPreview.ID,
    beforeWorkspaceID: MobileWorkspacePreview.ID?,
    workspaces: [MobileWorkspacePreview]
) -> Bool {
    mobileWorkspaceWorkspacesApplyingGroupMove(
        movedGroupID: movedGroupID,
        beforeWorkspaceID: beforeWorkspaceID,
        workspaces: workspaces
    ).map(\.id) != workspaces.map(\.id)
}
