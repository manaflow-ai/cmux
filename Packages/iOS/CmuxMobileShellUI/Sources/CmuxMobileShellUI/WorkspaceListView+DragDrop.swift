import CmuxMobileShellModel
import Foundation

extension WorkspaceListView {
    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
            && connectionStatus == .connected
            && canCreateWorkspaceForMacSelection
            && canRenderGroupsForSelection
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
    }

    var canCreateWorkspaceInGroups: Bool {
        createWorkspaceInGroup != nil
            && connectionStatus == .connected
            && canCreateWorkspaceForMacSelection
            && canRenderGroupsForSelection
    }

    func syncOptimisticWorkspaceOrder() {
        optimisticFlatWorkspaces = nil
        optimisticGroupedItems = nil
    }

    func moveFlatRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceWorkspaces = optimisticFlatWorkspaces ?? filteredWorkspaces
        let items = sourceWorkspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        guard let intent = MobileWorkspaceListItem.moveIntent(
            items: items,
            workspaces: filteredWorkspaces,
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
            await moveWorkspace?(workspace.id, intent.groupID, intent.beforeWorkspaceID)
            syncOptimisticWorkspaceOrder()
        }
    }

    func moveGroupedRows(from sourceOffsets: IndexSet, to destination: Int) {
        guard enablesWorkspaceReorder else { return }
        let sourceItems = optimisticGroupedItems ?? groupedListItems
        guard let intent = MobileWorkspaceListItem.moveIntent(
            items: sourceItems,
            workspaces: groupedWorkspaces,
            groups: groups,
            sourceOffsets: sourceOffsets,
            destination: destination
        ) else {
            return
        }
        var movedItems = sourceItems
        movedItems.move(fromOffsets: sourceOffsets, toOffset: destination)
        optimisticGroupedItems = movedItems
        guard let sourceIndex = sourceOffsets.first,
              case .workspace(let workspace, _) = sourceItems[sourceIndex] else {
            return
        }
        Task { @MainActor in
            await moveWorkspace?(workspace.id, intent.groupID, intent.beforeWorkspaceID)
            syncOptimisticWorkspaceOrder()
        }
    }
}
