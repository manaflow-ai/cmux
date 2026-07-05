import CmuxMobileShellModel
import Foundation

extension WorkspaceListView {
    var enablesWorkspaceDragAndDrop: Bool {
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

    private var visibleDropIntentWorkspaces: [MobileWorkspacePreview] {
        if rendersGroupedSections {
            return groupedWorkspaces
        }
        return filteredWorkspaces
    }

    func handleWorkspaceDrop(
        _ payloads: [String],
        target: MobileWorkspaceDropTarget
    ) -> Bool {
        guard enablesWorkspaceDragAndDrop,
              let rawWorkspaceID = payloads.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawWorkspaceID.isEmpty else {
            return false
        }
        let draggedWorkspaceID = MobileWorkspacePreview.ID(rawValue: rawWorkspaceID)
        let dropWorkspaces = visibleDropIntentWorkspaces
        guard dropWorkspaces.contains(where: { $0.id == draggedWorkspaceID }),
              let intent = MobileWorkspaceDropIntentResolver.intent(
                workspaces: dropWorkspaces,
                groups: groups,
                draggedWorkspaceID: draggedWorkspaceID,
                target: target
              ) else {
            return false
        }
        moveWorkspace?(draggedWorkspaceID, intent.groupID, intent.beforeWorkspaceID)
        return true
    }
}
