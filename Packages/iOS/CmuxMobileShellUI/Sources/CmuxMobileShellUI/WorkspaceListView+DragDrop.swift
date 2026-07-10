import CmuxMobileShellModel
import Foundation
import SwiftUI

extension WorkspaceListView {
    var hasPendingWorkspaceMove: Bool {
        pendingWorkspaceMoveCount > 0
    }

    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
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
        if !MobileWorkspaceOptimisticOrderReconciler(
            optimistic: optimisticFlatWorkspaces,
            authoritative: filteredWorkspaces,
            previousAuthoritative: optimisticFlatBaseWorkspaces,
            moveIsPending: hasPendingWorkspaceMove,
            moveDidFail: moveDidFail
        ).shouldKeepOptimisticOrder() {
            optimisticFlatWorkspaces = nil
            optimisticFlatBaseWorkspaces = nil
        }
        if !MobileWorkspaceOptimisticOrderReconciler(
            optimistic: optimisticGroupedWorkspaces,
            authoritative: groupedWorkspaces,
            previousAuthoritative: optimisticGroupedBaseWorkspaces,
            moveIsPending: hasPendingWorkspaceMove,
            moveDidFail: moveDidFail
        ).shouldKeepOptimisticOrder() {
            optimisticGroupedItems = nil
            optimisticGroupedWorkspaces = nil
            optimisticGroupedBaseWorkspaces = nil
        }
    }

    func moveFlatRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceWorkspaces = optimisticFlatWorkspaces ?? filteredWorkspaces
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
        optimisticFlatBaseWorkspaces = sourceWorkspaces
        optimisticFlatWorkspaces = movedWorkspaces
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
            await previousMove?.value
            let accepted = await moveWorkspace?(workspace.id, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup) ?? false
            pendingWorkspaceMoveCount -= 1
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
            }
        }
    }

    func moveGroupedRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceItems = optimisticGroupedItems ?? groupedListItems
        let sourceWorkspaces = optimisticGroupedWorkspaces ?? groupedWorkspaces
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
        optimisticGroupedBaseWorkspaces = sourceWorkspaces
        optimisticGroupedWorkspaces = movedWorkspaces
        optimisticGroupedItems = MobileWorkspaceListItem.items(workspaces: movedWorkspaces, groups: groups)
        pendingWorkspaceMoveCount += 1
        let previousMove = pendingWorkspaceMoveTask
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Same ordering contract as moveFlatRows.
            await previousMove?.value
            let accepted = await moveWorkspace?(movedWorkspaceID, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup) ?? false
            pendingWorkspaceMoveCount -= 1
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
            }
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
        case .groupFooter(let groupID):
            workspaceID = nil
            self.groupID = groupID
            windowID = nil
            macDeviceID = nil
            isPinned = nil
            isGroupCollapsed = nil
        }
    }
}
