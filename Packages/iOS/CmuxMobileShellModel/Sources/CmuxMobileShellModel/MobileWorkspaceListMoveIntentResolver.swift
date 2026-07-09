import Foundation

/// Resolves rendered iOS workspace list drags into Mac-facing move intents.
///
/// Policy table, mirroring the Mac sidebar/host write path:
/// - Group headers move the whole group as a top-level row only; drops that
///   visually land inside another group normalize to that group's anchor
///   boundary. See `SidebarWorkspaceReorderDropResolver` group-header routing
///   and `TerminalController.mobileWorkspaceMoveTopLevelBeforeID`.
/// - Group anchors are rendered only as headers. Dragging the header moves the
///   group; workspace-row drags never change an anchor's membership.
/// - Workspace rows join a group only from the explicit in-group slots:
///   header/member gaps, mid-group gaps, and the synthetic footer-before gap.
///   The footer-after gap is the touch equivalent of the Mac root lane.
/// - Collapsed group headers expose only a top-level root slot.
/// - Pinned top-level rows form a leading tier. A moved workspace uses its own
///   pin state; a moved group uses the group's pin state. In-group member order
///   is anchor first, pinned members, then unpinned members.
/// - Unknown groups or before-workspace IDs are rejected before an RPC can be
///   emitted, matching the host's `not_found`/invalid-request behavior without
///   producing a doomed optimistic order.
struct MobileWorkspaceListMoveIntentResolver {
    let items: [MobileWorkspaceListItem]
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]
    private let knownGroupIDs: Set<MobileWorkspaceGroupPreview.ID>

    init(
        items: [MobileWorkspaceListItem],
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview]
    ) {
        self.items = items
        self.workspaces = workspaces
        self.groups = groups
        self.knownGroupIDs = Set(groups.map(\.id))
    }

    func moveIntent(sourceOffsets: IndexSet, destination: Int) -> MobileWorkspaceMoveIntent? {
        guard sourceOffsets.count == 1,
              let sourceIndex = sourceOffsets.first,
              items.indices.contains(sourceIndex),
              let movedWorkspace = movedWorkspace(for: items[sourceIndex]) else {
            return nil
        }

        let rawDestination = Swift.min(Swift.max(destination, items.startIndex), items.endIndex)
        guard rawDestination != sourceIndex, rawDestination != sourceIndex + 1 else {
            return nil
        }
        let adjustedDestination = sourceIndex < rawDestination ? rawDestination - 1 : rawDestination
        var remainingItems = items
        remainingItems.remove(at: sourceIndex)
        let insertionIndex = Swift.min(
            Swift.max(adjustedDestination, remainingItems.startIndex),
            remainingItems.endIndex
        )

        let orderedWithoutMoved = workspaces.filter { $0.id != movedWorkspace.id }
        let previousItem = insertionIndex > remainingItems.startIndex
            ? remainingItems[remainingItems.index(before: insertionIndex)]
            : nil
        let nextItem = insertionIndex < remainingItems.endIndex
            ? remainingItems[insertionIndex]
            : nil

        let movesGroup = isGroupHeader(items[sourceIndex])
        let proposed = movesGroup
            ? rootLevelIntent(nextItem: nextItem, workspaces: orderedWithoutMoved)
            : proposedIntent(
                previousItem: previousItem,
                nextItem: nextItem,
                workspaces: orderedWithoutMoved
            )

        guard var proposed else { return nil }
        proposed.movesGroup = movesGroup
        return MobileWorkspaceMovePolicy(workspaces: workspaces, groups: groups)
            .normalizedIntent(proposed, movedWorkspaceID: movedWorkspace.id)
    }

    private func movedWorkspace(for item: MobileWorkspaceListItem) -> MobileWorkspacePreview? {
        switch item {
        case .workspace(let workspace, _):
            return workspace
        case .groupHeader(let group, _):
            return workspaces.first { $0.id == group.anchorWorkspaceID }
        case .groupFooter:
            return nil
        }
    }

    private func isGroupHeader(_ item: MobileWorkspaceListItem) -> Bool {
        if case .groupHeader = item {
            return true
        }
        return false
    }

    private func proposedIntent(
        previousItem: MobileWorkspaceListItem?,
        nextItem: MobileWorkspaceListItem?,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspaceMoveIntent? {
        switch previousItem {
        case .groupHeader(let group, _):
            guard knownGroupIDs.contains(group.id) else { return nil }
            if group.isCollapsed {
                return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)
            }
            return MobileWorkspaceMoveIntent(
                groupID: group.id,
                beforeWorkspaceID: firstNonAnchorWorkspace(in: group.id, workspaces: workspaces)
                    ?? workspaceAfterGroup(group.id, workspaces: workspaces)
            )

        case .groupFooter:
            return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)

        case .workspace(let previousWorkspace, _):
            let previousGroupID = validGroupID(previousWorkspace.groupID)
            guard let previousGroupID else {
                return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)
            }

            switch nextItem {
            case .workspace(let nextWorkspace, _):
                if validGroupID(nextWorkspace.groupID) == previousGroupID {
                    return MobileWorkspaceMoveIntent(
                        groupID: previousGroupID,
                        beforeWorkspaceID: nextWorkspace.id
                    )
                }
                return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)

            case .groupFooter(let footerGroupID):
                guard footerGroupID == previousGroupID else {
                    return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)
                }
                return MobileWorkspaceMoveIntent(
                    groupID: previousGroupID,
                    beforeWorkspaceID: workspaceAfterGroup(previousGroupID, workspaces: workspaces)
                )

            case .groupHeader, nil:
                return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)
            }

        case nil:
            return rootLevelIntent(nextItem: nextItem, workspaces: workspaces)
        }
    }

    private func rootLevelIntent(
        nextItem: MobileWorkspaceListItem?,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspaceMoveIntent {
        MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: rootLevelBeforeWorkspaceID(nextItem: nextItem, workspaces: workspaces)
        )
    }

    private func rootLevelBeforeWorkspaceID(
        nextItem: MobileWorkspaceListItem?,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        switch nextItem {
        case .workspace(let nextWorkspace, _):
            return nextWorkspace.id
        case .groupHeader(let nextGroup, _):
            return firstWorkspace(in: nextGroup.id, workspaces: workspaces)
        case .groupFooter(let groupID):
            return workspaceAfterGroup(groupID, workspaces: workspaces)
                ?? firstWorkspace(in: groupID, workspaces: workspaces)
                ?? groups.first(where: { $0.id == groupID })?.anchorWorkspaceID
        case nil:
            return nil
        }
    }

    private func validGroupID(_ groupID: MobileWorkspaceGroupPreview.ID?) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, knownGroupIDs.contains(groupID) else { return nil }
        return groupID
    }

    private func firstWorkspace(
        in groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        workspaces.first(where: { validGroupID($0.groupID) == groupID })?.id
    }

    private func firstNonAnchorWorkspace(
        in groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let anchorWorkspaceID = groups.first(where: { $0.id == groupID })?.anchorWorkspaceID else {
            return nil
        }
        return workspaces.first(where: {
            validGroupID($0.groupID) == groupID && $0.id != anchorWorkspaceID
        })?.id
    }

    private func workspaceAfterGroup(
        _ groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let lastMemberIndex = workspaces.lastIndex(where: {
            validGroupID($0.groupID) == groupID
        }) else {
            return nil
        }
        let nextIndex = workspaces.index(after: lastMemberIndex)
        guard nextIndex < workspaces.endIndex else { return nil }
        return workspaces[nextIndex].id
    }
}
