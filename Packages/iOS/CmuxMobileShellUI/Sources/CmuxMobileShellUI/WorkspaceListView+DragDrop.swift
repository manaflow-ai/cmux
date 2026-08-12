import CmuxMobileDiagnostics
import CmuxMobileShellModel
import Foundation
import SwiftUI

extension WorkspaceListView {
    /// Pipelining bound: with reorder enabled during pending moves, a slow or
    /// offline Mac must not let the send chain grow without limit, and every
    /// queued move currently costs a full workspace refresh on reply. Normal
    /// round-trips resolve between drags, so this only bites when the host is
    /// genuinely unresponsive.
    static let maxPipelinedWorkspaceMoves = 3

    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
            && pendingWorkspaceMoveCount < Self.maxPipelinedWorkspaceMoves
            && canMutateForegroundGroupsForSelection
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
            // The recency order is derived from timestamps, so a drag has no
            // spatial position to send to the Mac.
            && !appliesRecencySort
            && reorderableWorkspaces.hasSingleKnownWindow
            && (rendersGroupedSections || !filteredWorkspaces.contains(where: \.isPinned))
    }

    var reorderableWorkspaces: [MobileWorkspacePreview] {
        rendersGroupedSections ? groupedWorkspaces : filteredWorkspaces
    }

    var filteredWorkspaceOrderKey: [WorkspaceListStableOrderKey] {
        filteredWorkspaces.map { WorkspaceListStableOrderKey(workspace: $0) }
    }

    var canCreateWorkspaceInGroups: Bool {
        createWorkspaceInGroup != nil
            && canCreateWorkspaceForMacSelection
            && canMutateForegroundGroupsForSelection
    }

    func syncOptimisticWorkspaceOrder(moveDidFail: Bool = false) {
        let hadPendingOptimism = optimisticFlatState.optimisticOrder != nil
            || optimisticGroupedState.optimisticOrder != nil
        optimisticFlatState = optimisticFlatState.reconciling(
            authoritative: filteredWorkspaces,
            moveDidFail: moveDidFail
        )
        optimisticGroupedState = optimisticGroupedState.reconciling(
            authoritative: groupedWorkspaces,
            groups: groups,
            moveDidFail: moveDidFail
        )
        let cleared = optimisticFlatState.optimisticOrder == nil
            && optimisticGroupedState.optimisticOrder == nil
        // A supersede (or failure) invalidates every queued dependent: their
        // intents were computed against predictions the host has overruled.
        // Bumping the epoch makes not-yet-sent moves abort, and detaching the
        // tail lets fresh drags start a clean chain.
        if hadPendingOptimism, cleared, pendingWorkspaceMoveCount > 0 {
            workspaceMoveEpoch &+= 1
            pendingWorkspaceMoveTask = nil
        }
    }

    func moveFlatRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceWorkspaces = displayedFlatWorkspaces
        let items = sourceWorkspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        guard let intent = items.moveIntent(
            workspaces: sourceWorkspaces,
            groups: [],
            sourceOffsets: sourceOffsets,
            destination: destination
        ) else {
            return
        }
        var movedWorkspaces = sourceWorkspaces
        movedWorkspaces.move(fromOffsets: sourceOffsets, toOffset: destination)
        optimisticFlatState = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: movedWorkspaces),
            pendingBases: optimisticFlatState.pendingBases
                + [MobileWorkspaceOptimisticOrder(workspaces: sourceWorkspaces)]
        )
        guard let sourceIndex = sourceOffsets.first,
              case .workspace(let workspace, _) = items[sourceIndex] else {
            return
        }
        store?.recordAppEvent(.workspaceDragDropStarted, correlationID: workspace.id.rawValue)
        pendingWorkspaceMoveCount += 1
        let previousMove = pendingWorkspaceMoveTask
        let epoch = workspaceMoveEpoch
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Chain on the prior send: the intent was computed against the
            // prior move's predicted order, so the host must apply them in
            // the same order or the snapshot diverges and drops optimism.
            // A rejected predecessor rolled the list back, and a supersede
            // bumped the epoch; either way this stale intent must not be
            // sent. The handlers reset the chain tail, so drags started
            // afterwards never see these branches.
            if let previousMove, await previousMove.value == false {
                pendingWorkspaceMoveCount -= 1
                store?.recordAppEvent(
                    .workspaceDragDropFailed,
                    correlationID: workspace.id.rawValue,
                    failure: .superseded
                )
                store?.recordAppEvent(
                    .workspaceMutationCancelled,
                    correlationID: workspace.id.rawValue,
                    failure: .superseded
                )
                return false
            }
            guard epoch == workspaceMoveEpoch else {
                pendingWorkspaceMoveCount -= 1
                store?.recordAppEvent(
                    .workspaceDragDropFailed,
                    correlationID: workspace.id.rawValue,
                    failure: .superseded
                )
                store?.recordAppEvent(
                    .workspaceMutationCancelled,
                    correlationID: workspace.id.rawValue,
                    failure: .superseded
                )
                return false
            }
            let accepted = await moveWorkspace?(workspace.id, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup) ?? false
            pendingWorkspaceMoveCount -= 1
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
                // Detach the chain so the completed failed task cannot poison
                // future drags; queued dependents still hold their captured
                // reference and drain by aborting above.
                pendingWorkspaceMoveTask = nil
            }
            store?.recordAppEvent(
                accepted ? .workspaceDragDropSucceeded : .workspaceDragDropFailed,
                correlationID: workspace.id.rawValue,
                failure: accepted ? nil : .protocolViolation
            )
            return accepted
        }
    }

    func moveGroupedRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else {
            MobileDebugLog.anchormux("move.drop grouped BLOCKED enablesWorkspaceReorder=false")
            return
        }
        let sourceItems = displayedGroupedListItems
        let sourceWorkspaces = displayedGroupedWorkspaces
        guard let intent = sourceItems.moveIntent(
            workspaces: sourceWorkspaces,
            groups: groups,
            sourceOffsets: sourceOffsets,
            destination: destination
        ) else {
            MobileDebugLog.anchormux(
                "move.drop grouped NO-INTENT source=\(sourceOffsets.first ?? -1) dest=\(destination) items=\(sourceItems.count)"
            )
            return
        }
        MobileDebugLog.anchormux(
            "move.drop grouped source=\(sourceOffsets.first ?? -1) dest=\(destination) -> group=\(intent.groupID?.rawValue.suffix(6) ?? "root") before=\(intent.beforeWorkspaceID?.rawValue.suffix(6) ?? "end") movesGroup=\(intent.movesGroup)"
        )
        guard let sourceIndex = sourceOffsets.first else {
            return
        }
        let movedWorkspaceID: MobileWorkspacePreview.ID
        switch sourceItems[sourceIndex] {
        case .workspace(let workspace, _):
            movedWorkspaceID = workspace.id
        case .groupHeader(let group, _):
            movedWorkspaceID = group.anchorWorkspaceID
        case .groupFooter:
            return
        }
        store?.recordAppEvent(.workspaceDragDropStarted, correlationID: movedWorkspaceID.rawValue)
        applyGroupedWorkspaceMove(
            intent,
            movedWorkspaceID: movedWorkspaceID,
            sourceWorkspaces: sourceWorkspaces,
            isDragDrop: true
        )
    }

    func canJoinGroupAtEnd(
        workspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID
    ) -> Bool {
        guard enablesWorkspaceReorder, rendersGroupedSections else { return false }
        let sourceWorkspaces = displayedGroupedWorkspaces
        return MobileWorkspaceMovePolicy(workspaces: sourceWorkspaces, groups: groups)
            .normalizedIntent(
                MobileWorkspaceMoveIntent(
                    groupID: groupID,
                    beforeWorkspaceID: nil,
                    movesGroup: false
                ),
                movedWorkspaceID: workspaceID
            ) != nil
    }

    /// The context-menu "Move to Group" picker for one workspace row, or `nil`
    /// when moves are unavailable (drag gating applies identically) or the
    /// picker would be empty.
    func groupMoveMenu(for workspaceID: MobileWorkspacePreview.ID) -> MobileWorkspaceGroupMoveMenu? {
        guard enablesWorkspaceReorder, rendersGroupedSections else { return nil }
        let menu = MobileWorkspaceGroupMoveMenu(
            workspaces: displayedGroupedWorkspaces,
            groups: groups,
            movedWorkspaceID: workspaceID
        )
        return menu.isEmpty ? nil : menu
    }

    /// Joins a group at its end, or leaves the current group when `groupID` is
    /// `nil`. Shared by the drop-into-group path and the context-menu picker.
    func joinGroupAtEnd(
        workspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID?
    ) {
        guard enablesWorkspaceReorder, rendersGroupedSections else { return }
        let sourceWorkspaces = displayedGroupedWorkspaces
        let policy = MobileWorkspaceMovePolicy(workspaces: sourceWorkspaces, groups: groups)
        guard let intent = policy.normalizedIntent(
            MobileWorkspaceMoveIntent(
                groupID: groupID,
                beforeWorkspaceID: nil,
                movesGroup: false
            ),
            movedWorkspaceID: workspaceID
        ) else {
            return
        }
        applyGroupedWorkspaceMove(
            intent,
            movedWorkspaceID: workspaceID,
            sourceWorkspaces: sourceWorkspaces,
            isDragDrop: false
        )
    }

    private func applyGroupedWorkspaceMove(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID,
        sourceWorkspaces: [MobileWorkspacePreview],
        isDragDrop: Bool
    ) {
        let movedWorkspaces = sourceWorkspaces.applyingWorkspaceMoveIntent(
            intent,
            movedWorkspaceID: movedWorkspaceID,
            groups: groups
        )
        optimisticGroupedState = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: movedWorkspaces, groups: groups),
            pendingBases: optimisticGroupedState.pendingBases
                + [MobileWorkspaceOptimisticOrder(workspaces: sourceWorkspaces, groups: groups)]
        )
        pendingWorkspaceMoveCount += 1
        let previousMove = pendingWorkspaceMoveTask
        let epoch = workspaceMoveEpoch
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Same ordering, predecessor-failure, and epoch contract as
            // moveFlatRows.
            if let previousMove, await previousMove.value == false {
                MobileDebugLog.anchormux("move.chain ABORT predecessor-failed id=\(movedWorkspaceID.rawValue.suffix(6))")
                pendingWorkspaceMoveCount -= 1
                if isDragDrop {
                    store?.recordAppEvent(
                        .workspaceDragDropFailed,
                        correlationID: movedWorkspaceID.rawValue,
                        failure: .superseded
                    )
                }
                store?.recordAppEvent(
                    .workspaceMutationCancelled,
                    correlationID: movedWorkspaceID.rawValue,
                    failure: .superseded
                )
                return false
            }
            guard epoch == workspaceMoveEpoch else {
                MobileDebugLog.anchormux("move.chain ABORT epoch-superseded id=\(movedWorkspaceID.rawValue.suffix(6))")
                pendingWorkspaceMoveCount -= 1
                if isDragDrop {
                    store?.recordAppEvent(
                        .workspaceDragDropFailed,
                        correlationID: movedWorkspaceID.rawValue,
                        failure: .superseded
                    )
                }
                store?.recordAppEvent(
                    .workspaceMutationCancelled,
                    correlationID: movedWorkspaceID.rawValue,
                    failure: .superseded
                )
                return false
            }
            let accepted = await moveWorkspace?(movedWorkspaceID, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup) ?? false
            pendingWorkspaceMoveCount -= 1
            MobileDebugLog.anchormux("move.chain accepted=\(accepted) id=\(movedWorkspaceID.rawValue.suffix(6))")
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
                pendingWorkspaceMoveTask = nil
            }
            if isDragDrop {
                store?.recordAppEvent(
                    accepted ? .workspaceDragDropSucceeded : .workspaceDragDropFailed,
                    correlationID: movedWorkspaceID.rawValue,
                    failure: accepted ? nil : .protocolViolation
                )
            }
            return accepted
        }
    }
}

struct WorkspaceListStableOrderKey: Equatable {
    let rowID: String
    let workspaceID: MobileWorkspacePreview.ID?
    let groupID: MobileWorkspaceGroupPreview.ID?
    let windowID: String?
    let macDeviceID: String?
    let isPinned: Bool?
    let isGroupCollapsed: Bool?

    init(workspace: MobileWorkspacePreview) {
        rowID = "workspace.\(workspace.id.rawValue)"
        workspaceID = workspace.id
        groupID = workspace.groupID
        windowID = workspace.windowID
        macDeviceID = workspace.macDeviceID
        isPinned = workspace.isPinned
        isGroupCollapsed = nil
    }

    init(item: MobileWorkspaceListItem) {
        rowID = item.id
        switch item {
        case .workspace(let workspace, _):
            workspaceID = workspace.id
            groupID = workspace.groupID
            windowID = workspace.windowID
            macDeviceID = workspace.macDeviceID
            isPinned = workspace.isPinned
            isGroupCollapsed = nil
        case .groupHeader(let group, _):
            workspaceID = group.anchorWorkspaceID
            groupID = group.id
            windowID = nil
            macDeviceID = nil
            isPinned = group.isPinned
            isGroupCollapsed = group.isCollapsed
        case .groupFooter(let footerGroupID):
            workspaceID = nil
            groupID = footerGroupID
            windowID = nil
            macDeviceID = nil
            isPinned = nil
            isGroupCollapsed = nil
        }
    }
}
