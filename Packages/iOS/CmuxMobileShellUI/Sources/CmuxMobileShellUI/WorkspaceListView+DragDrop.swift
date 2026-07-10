import CmuxMobileShellModel
import Foundation
import SwiftUI

extension WorkspaceListView {
    /// Pipelining bound: with reorder enabled during pending moves, a slow or
    /// offline Mac must not let the send chain grow without limit. Normal
    /// round-trips never approach this, so drags are unaffected until the
    /// host is genuinely unresponsive.
    static let maxPipelinedWorkspaceMoves = 8

    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
            && pendingWorkspaceMoveCount < Self.maxPipelinedWorkspaceMoves
            && canRenderGroupsForSelection
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
            && reorderableWorkspaces.hasSingleKnownWindow
            && (rendersGroupedSections || !filteredWorkspaces.contains(where: \.isPinned))
    }

    var reorderableWorkspaces: [MobileWorkspacePreview] {
        rendersGroupedSections ? groupedWorkspaces : filteredWorkspaces
    }

    var filteredWorkspaceOrderKey: [WorkspaceListStableOrderKey] {
        filteredWorkspaces.map { WorkspaceListStableOrderKey(workspace: $0) }
    }

    var groupedWorkspaceOrderKey: [WorkspaceListStableOrderKey] {
        groupedListItems.map { WorkspaceListStableOrderKey(item: $0) }
    }

    var canCreateWorkspaceInGroups: Bool {
        createWorkspaceInGroup != nil
            && canCreateWorkspaceForMacSelection
            && canRenderGroupsForSelection
    }

    func syncOptimisticWorkspaceOrder(moveDidFail: Bool = false) {
        optimisticFlatState = optimisticFlatState.reconciling(
            authoritative: filteredWorkspaces,
            moveDidFail: moveDidFail
        )
        optimisticGroupedState = optimisticGroupedState.reconciling(
            authoritative: groupedWorkspaces,
            groups: groups,
            moveDidFail: moveDidFail
        )
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
        pendingWorkspaceMoveCount += 1
        let previousMove = pendingWorkspaceMoveTask
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Chain on the prior send: the intent was computed against the
            // prior move's predicted order, so the host must apply them in
            // the same order or the snapshot diverges and drops optimism.
            // A rejected predecessor already rolled the list back to the
            // authoritative order, so an intent based on its prediction must
            // not be sent at all.
            if let previousMove, await previousMove.value == false {
                // A dependent of a failed chain: the failure already rolled
                // the list back, so this stale intent must not be sent. The
                // failure handler reset the chain tail, so drags started
                // after the failure never see this branch.
                pendingWorkspaceMoveCount -= 1
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
            return accepted
        }
    }

    func moveGroupedRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceItems = displayedGroupedListItems
        let sourceWorkspaces = displayedGroupedWorkspaces
        guard let intent = sourceItems.moveIntent(
            workspaces: sourceWorkspaces,
            groups: groups,
            sourceOffsets: sourceOffsets,
            destination: destination
        ) else {
            return
        }
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
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Same ordering and predecessor-failure contract as moveFlatRows.
            if let previousMove, await previousMove.value == false {
                // Same dependent-abort contract as moveFlatRows.
                pendingWorkspaceMoveCount -= 1
                return false
            }
            let accepted = await moveWorkspace?(movedWorkspaceID, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup) ?? false
            pendingWorkspaceMoveCount -= 1
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
                pendingWorkspaceMoveTask = nil
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
