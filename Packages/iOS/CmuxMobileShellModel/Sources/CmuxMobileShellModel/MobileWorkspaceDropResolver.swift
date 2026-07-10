import CoreGraphics
import Foundation

/// Resolves point-aware mobile workspace drags into normalized host intents.
///
/// Policy table, ported from `SidebarWorkspaceReorderDropResolver` and
/// `SidebarDropPlanner` in `CmuxFoundation/SidebarDrop`:
/// - Workspace-row top/bottom halves select the preceding/following slot.
///   Header top is root above the group; header bottom enters at the group's
///   first member slot. See the Mac resolver's `groupScopeCandidate` and
///   `groupScopedIndicator` paths (resolver lines 126-190 and 256-261).
/// - A header's middle 50% highlights that group and appends there, including
///   anchor-only groups. This is the touch-only drop-on-row capability that an
///   index-only `onMove` cannot represent.
/// - The boundary after a group's last member is ambiguous. Points left of
///   `listMidlineX` land at root after the group; points on or right of it join
///   the group at its end, matching the Mac horizontal hierarchy lane.
/// - Group drags offer only root-level positions. Any row inside a group maps
///   to the whole group's leading or trailing boundary.
/// - Every proposal is normalized by ``MobileWorkspaceMovePolicy``. Indicator
///   geometry is derived from that normalized intent, so pinned-tier clamps and
///   whole-group normalization are visible before commit.
/// - Unknown drag identities, groups, rows, and before-workspace identities do
///   not produce targets. Identity landings return a target marked `isNoOp`.
public struct MobileWorkspaceDropResolver: Sendable {
    /// Creates a point-aware workspace drop resolver.
    public init() {}

    /// Resolves a drag location into a normalized move and visual target.
    /// - Parameter request: The immutable drag, rows, model, and point snapshot.
    /// - Returns: A resolved target, or `nil` when the snapshot is invalid.
    public func resolve(_ request: MobileWorkspaceDropRequest) -> MobileWorkspaceDropTarget? {
        let rows = request.rows.sorted {
            $0.frame.minY == $1.frame.minY
                ? $0.frame.minX < $1.frame.minX
                : $0.frame.minY < $1.frame.minY
        }
        guard !rows.isEmpty,
              request.workspaces.contains(where: { $0.id == request.payload.workspaceID }),
              let hit = hitRow(pointY: request.point.y, rows: rows) else {
            return nil
        }

        let groupsByID = Dictionary(
            request.groups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let groupByAnchorID = Dictionary(
            request.groups.map { ($0.anchorWorkspaceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if request.payload.isGroupDrag {
            guard groupByAnchorID[request.payload.workspaceID] != nil else { return nil }
        } else if groupByAnchorID[request.payload.workspaceID] != nil {
            return nil
        }

        let proposal: MobileWorkspaceMoveIntent?
        let highlightedGroupID: MobileWorkspaceGroupPreview.ID?
        if request.payload.isGroupDrag {
            proposal = groupProposal(
                hitIndex: hit.index,
                hitsTop: hit.hitsTop,
                rows: rows,
                request: request,
                groupsByID: groupsByID
            )
            highlightedGroupID = nil
        } else {
            let result = workspaceProposal(
                hitIndex: hit.index,
                hitsTop: hit.hitsTop,
                hitsHeaderMiddle: hit.hitsHeaderMiddle,
                rows: rows,
                request: request,
                groupsByID: groupsByID
            )
            proposal = result.intent
            highlightedGroupID = result.highlightedGroupID
        }
        guard var proposal else { return nil }
        proposal.movesGroup = request.payload.isGroupDrag

        let policy = MobileWorkspaceMovePolicy(
            workspaces: request.workspaces,
            groups: request.groups
        )
        let normalized = policy.normalizedIntent(
            proposal,
            movedWorkspaceID: request.payload.workspaceID
        )
        let isNoOp = normalized == nil
        let effectiveIntent = normalized ?? proposal
        let predicted = policy.applyingHostMove(
            effectiveIntent,
            movedWorkspaceID: request.payload.workspaceID
        )
        guard let indicator = indicator(
            for: effectiveIntent,
            predicted: predicted,
            movedWorkspaceID: request.payload.workspaceID,
            requestedHighlightGroupID: highlightedGroupID,
            rows: rows,
            workspaces: request.workspaces,
            groupsByID: groupsByID
        ) else {
            return nil
        }
        return MobileWorkspaceDropTarget(
            intent: effectiveIntent,
            indicator: indicator,
            isNoOp: isNoOp
        )
    }

    private func hitRow(
        pointY: CGFloat,
        rows: [MobileWorkspaceDropRowFrame]
    ) -> (index: Int, hitsTop: Bool, hitsHeaderMiddle: Bool)? {
        if let index = rows.firstIndex(where: { pointY >= $0.frame.minY && pointY <= $0.frame.maxY }) {
            let row = rows[index]
            let height = max(row.frame.height, 1)
            let localY = min(max(pointY - row.frame.minY, 0), height)
            let isHeader: Bool
            if case .groupHeader = row.kind { isHeader = true } else { isHeader = false }
            return (
                index,
                localY < height / 2,
                isHeader && localY >= height / 4 && localY <= height * 3 / 4
            )
        }
        guard let nextIndex = rows.firstIndex(where: { pointY < $0.frame.minY }) else {
            return (rows.index(before: rows.endIndex), false, false)
        }
        guard nextIndex > rows.startIndex else { return (nextIndex, true, false) }
        let previousIndex = rows.index(before: nextIndex)
        let previousDistance = max(0, pointY - rows[previousIndex].frame.maxY)
        let nextDistance = max(0, rows[nextIndex].frame.minY - pointY)
        return previousDistance < nextDistance
            ? (previousIndex, false, false)
            : (nextIndex, true, false)
    }

    private func groupProposal(
        hitIndex: Int,
        hitsTop: Bool,
        rows: [MobileWorkspaceDropRowFrame],
        request: MobileWorkspaceDropRequest,
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspaceMoveIntent? {
        let row = rows[hitIndex]
        if let groupID = groupID(
            for: row.kind,
            workspaces: request.workspaces,
            groupsByID: groupsByID
        ) {
            guard let group = groupsByID[groupID] else { return nil }
            return MobileWorkspaceMoveIntent(
                groupID: nil,
                beforeWorkspaceID: hitsTop
                    ? group.anchorWorkspaceID
                    : workspaceAfterGroup(groupID, workspaces: request.workspaces, groupsByID: groupsByID),
                movesGroup: true
            )
        }
        guard case .workspace(let workspaceID) = row.kind else { return nil }
        return MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: hitsTop
                ? workspaceID
                : topLevelBeforeID(after: hitIndex, rows: rows, request: request, groupsByID: groupsByID),
            movesGroup: true
        )
    }

    private func workspaceProposal(
        hitIndex: Int,
        hitsTop: Bool,
        hitsHeaderMiddle: Bool,
        rows: [MobileWorkspaceDropRowFrame],
        request: MobileWorkspaceDropRequest,
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> (intent: MobileWorkspaceMoveIntent?, highlightedGroupID: MobileWorkspaceGroupPreview.ID?) {
        let row = rows[hitIndex]
        switch row.kind {
        case .groupHeader(let groupID):
            guard let group = groupsByID[groupID] else { return (nil, nil) }
            if hitsHeaderMiddle {
                return (
                    MobileWorkspaceMoveIntent(
                        groupID: groupID,
                        beforeWorkspaceID: workspaceAfterGroup(
                            groupID,
                            workspaces: request.workspaces,
                            groupsByID: groupsByID
                        )
                    ),
                    groupID
                )
            }
            if hitsTop {
                return (MobileWorkspaceMoveIntent(
                    groupID: nil,
                    beforeWorkspaceID: group.anchorWorkspaceID
                ), nil)
            }
            return (MobileWorkspaceMoveIntent(
                groupID: groupID,
                beforeWorkspaceID: firstNonAnchorWorkspace(
                    groupID,
                    workspaces: request.workspaces,
                    groupsByID: groupsByID
                ) ?? workspaceAfterGroup(groupID, workspaces: request.workspaces, groupsByID: groupsByID)
            ), nil)

        case .workspace(let workspaceID):
            guard let workspace = request.workspaces.first(where: { $0.id == workspaceID }) else {
                return (nil, nil)
            }
            if let groupID = validGroupID(workspace.groupID, groupsByID: groupsByID) {
                if hitsTop {
                    return (MobileWorkspaceMoveIntent(groupID: groupID, beforeWorkspaceID: workspaceID), nil)
                }
                if let nextWorkspaceID = nextVisibleWorkspaceID(after: hitIndex, rows: rows),
                   let nextWorkspace = request.workspaces.first(where: { $0.id == nextWorkspaceID }),
                   validGroupID(nextWorkspace.groupID, groupsByID: groupsByID) == groupID {
                    return (MobileWorkspaceMoveIntent(
                        groupID: groupID,
                        beforeWorkspaceID: nextWorkspaceID
                    ), nil)
                }
                let afterGroup = workspaceAfterGroup(
                    groupID,
                    workspaces: request.workspaces,
                    groupsByID: groupsByID
                )
                return request.point.x >= request.listMidlineX
                    ? (MobileWorkspaceMoveIntent(groupID: groupID, beforeWorkspaceID: afterGroup), nil)
                    : (MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: afterGroup), nil)
            }

            if hitsTop,
               hitIndex > rows.startIndex,
               let previousGroupID = groupID(
                   for: rows[rows.index(before: hitIndex)].kind,
                   workspaces: request.workspaces,
                   groupsByID: groupsByID
               ) {
                return request.point.x >= request.listMidlineX
                    ? (MobileWorkspaceMoveIntent(
                        groupID: previousGroupID,
                        beforeWorkspaceID: workspaceID
                    ), nil)
                    : (MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: workspaceID), nil)
            }
            return (MobileWorkspaceMoveIntent(
                groupID: nil,
                beforeWorkspaceID: hitsTop
                    ? workspaceID
                    : topLevelBeforeID(after: hitIndex, rows: rows, request: request, groupsByID: groupsByID)
            ), nil)
        }
    }

    private func indicator(
        for intent: MobileWorkspaceMoveIntent,
        predicted: [MobileWorkspacePreview],
        movedWorkspaceID: MobileWorkspacePreview.ID,
        requestedHighlightGroupID: MobileWorkspaceGroupPreview.ID?,
        rows: [MobileWorkspaceDropRowFrame],
        workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspaceDropIndicator? {
        if let groupID = requestedHighlightGroupID,
           intent.groupID == groupID,
           isLastMember(movedWorkspaceID, groupID: groupID, in: predicted, groupsByID: groupsByID),
           let header = rows.first(where: { $0.kind == .groupHeader(groupID) }) {
            return MobileWorkspaceDropIndicator(
                y: header.frame.midY,
                indented: true,
                kind: .highlightGroup(groupID)
            )
        }

        let y: CGFloat?
        if let groupID = intent.groupID {
            let beforeIsInGroup = intent.beforeWorkspaceID.flatMap { beforeID in
                predicted.first(where: { $0.id == beforeID })?.groupID
            }.flatMap { validGroupID($0, groupsByID: groupsByID) } == groupID
            if beforeIsInGroup, let beforeID = intent.beforeWorkspaceID {
                y = frame(forWorkspaceID: beforeID, rows: rows, groupsByID: groupsByID)?.minY
            } else {
                y = lastVisibleFrame(in: groupID, rows: rows, workspaces: workspaces, groupsByID: groupsByID)?.maxY
            }
        } else if let beforeID = intent.beforeWorkspaceID {
            y = frame(forWorkspaceID: beforeID, rows: rows, groupsByID: groupsByID)?.minY
        } else {
            y = rows.map(\.frame.maxY).max()
        }
        guard let y else { return nil }
        return MobileWorkspaceDropIndicator(y: y, indented: intent.groupID != nil, kind: .insertLine)
    }

    private func groupID(
        for kind: MobileWorkspaceDropRowKind,
        workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspaceGroupPreview.ID? {
        switch kind {
        case .groupHeader(let groupID):
            return groupsByID[groupID] == nil ? nil : groupID
        case .workspace(let workspaceID):
            return validGroupID(
                workspaces.first(where: { $0.id == workspaceID })?.groupID,
                groupsByID: groupsByID
            )
        }
    }

    private func validGroupID(
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, groupsByID[groupID] != nil else { return nil }
        return groupID
    }

    private func topLevelBeforeID(
        after rowIndex: Int,
        rows: [MobileWorkspaceDropRowFrame],
        request: MobileWorkspaceDropRequest,
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspacePreview.ID? {
        guard rowIndex + 1 < rows.count else { return nil }
        for row in rows[(rowIndex + 1)...] {
            switch row.kind {
            case .groupHeader(let groupID):
                return groupsByID[groupID]?.anchorWorkspaceID
            case .workspace(let workspaceID):
                guard let workspace = request.workspaces.first(where: { $0.id == workspaceID }) else {
                    return nil
                }
                if let groupID = validGroupID(workspace.groupID, groupsByID: groupsByID) {
                    return groupsByID[groupID]?.anchorWorkspaceID
                }
                return workspaceID
            }
        }
        return nil
    }

    private func nextVisibleWorkspaceID(
        after rowIndex: Int,
        rows: [MobileWorkspaceDropRowFrame]
    ) -> MobileWorkspacePreview.ID? {
        guard rowIndex + 1 < rows.count else { return nil }
        if case .workspace(let workspaceID) = rows[rowIndex + 1].kind {
            return workspaceID
        }
        return nil
    }

    private func firstNonAnchorWorkspace(
        _ groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let anchorID = groupsByID[groupID]?.anchorWorkspaceID else { return nil }
        return workspaces.first(where: {
            validGroupID($0.groupID, groupsByID: groupsByID) == groupID && $0.id != anchorID
        })?.id
    }

    private func workspaceAfterGroup(
        _ groupID: MobileWorkspaceGroupPreview.ID,
        workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let lastIndex = workspaces.lastIndex(where: {
            validGroupID($0.groupID, groupsByID: groupsByID) == groupID
        }) else { return nil }
        let nextIndex = workspaces.index(after: lastIndex)
        return nextIndex < workspaces.endIndex ? workspaces[nextIndex].id : nil
    }

    private func frame(
        forWorkspaceID workspaceID: MobileWorkspacePreview.ID,
        rows: [MobileWorkspaceDropRowFrame],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> CGRect? {
        if let frame = rows.first(where: { $0.kind == .workspace(workspaceID) })?.frame {
            return frame
        }
        let groupID = groupsByID.first(where: { $0.value.anchorWorkspaceID == workspaceID })?.key
        return groupID.flatMap { id in rows.first(where: { $0.kind == .groupHeader(id) })?.frame }
    }

    private func lastVisibleFrame(
        in targetGroupID: MobileWorkspaceGroupPreview.ID,
        rows: [MobileWorkspaceDropRowFrame],
        workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> CGRect? {
        rows.last(where: {
            groupID(for: $0.kind, workspaces: workspaces, groupsByID: groupsByID) == targetGroupID
        })?.frame
    }

    private func isLastMember(
        _ workspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in workspaces: [MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              validGroupID(workspaces[index].groupID, groupsByID: groupsByID) == groupID else {
            return false
        }
        let nextIndex = workspaces.index(after: index)
        guard nextIndex < workspaces.endIndex else { return true }
        return validGroupID(workspaces[nextIndex].groupID, groupsByID: groupsByID) != groupID
    }
}
