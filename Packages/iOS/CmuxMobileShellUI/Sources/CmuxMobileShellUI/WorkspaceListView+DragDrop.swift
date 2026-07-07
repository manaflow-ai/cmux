import CmuxMobileShellModel
import Foundation

extension WorkspaceListView {
    var hasPendingWorkspaceMove: Bool {
        optimisticFlatWorkspaces != nil || optimisticGroupedItems != nil || optimisticGroupedWorkspaces != nil
    }

    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
            && !hasPendingWorkspaceMove
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

    var canCreateWorkspaceInGroups: Bool {
        createWorkspaceInGroup != nil
            && canCreateWorkspaceForMacSelection
            && canRenderGroupsForSelection
    }

    func syncOptimisticWorkspaceOrder() {
        optimisticFlatWorkspaces = nil
        optimisticGroupedItems = nil
        optimisticGroupedWorkspaces = nil
    }

    func moveFlatRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceWorkspaces = optimisticFlatWorkspaces ?? filteredWorkspaces
        let items = sourceWorkspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        guard let intent = MobileWorkspaceListItem.moveIntent(
            items: items,
            workspaces: sourceWorkspaces,
            groups: [],
            sourceOffsets: sourceOffsets,
            destination: destination
        ) else {
            return
        }
        var movedWorkspaces = sourceWorkspaces
        movedWorkspaces.move(fromOffsets: sourceOffsets, toOffset: destination)
        optimisticFlatWorkspaces = movedWorkspaces
        guard let sourceIndex = sourceOffsets.first,
              case .workspace(let workspace, _) = items[sourceIndex] else {
            return
        }
        Task { @MainActor in
            await moveWorkspace?(workspace.id, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup)
            syncOptimisticWorkspaceOrder()
        }
    }

    func moveGroupedRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceItems = optimisticGroupedItems ?? groupedListItems
        let sourceWorkspaces = optimisticGroupedWorkspaces ?? groupedWorkspaces
        guard let intent = MobileWorkspaceListItem.moveIntent(
            items: sourceItems,
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
        let movedWorkspaces = MobileWorkspaceListItem.workspacesApplying(
            intent,
            movedWorkspaceID: movedWorkspaceID,
            workspaces: sourceWorkspaces
        )
        optimisticGroupedWorkspaces = movedWorkspaces
        optimisticGroupedItems = MobileWorkspaceListItem.items(workspaces: movedWorkspaces, groups: groups)
        Task { @MainActor in
            await moveWorkspace?(movedWorkspaceID, intent.groupID, intent.beforeWorkspaceID, intent.movesGroup)
            syncOptimisticWorkspaceOrder()
        }
    }
}
