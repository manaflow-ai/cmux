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
        _ rawWorkspaceID: String,
        target: MobileWorkspaceDropTarget
    ) -> Bool {
        guard enablesWorkspaceDragAndDrop else {
            return false
        }
        let trimmedWorkspaceID = rawWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspaceID.isEmpty else {
            return false
        }
        let draggedWorkspaceID = MobileWorkspacePreview.ID(rawValue: trimmedWorkspaceID)
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

    func handleWorkspaceProviderDrop(
        _ providers: [NSItemProvider],
        target: MobileWorkspaceDropTarget
    ) -> Bool {
        guard enablesWorkspaceDragAndDrop,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let rawWorkspaceID = object as? String else { return }
            Task { @MainActor in
                _ = handleWorkspaceDrop(rawWorkspaceID, target: target)
            }
        }
        return true
    }

    func handleWorkspaceInsert(
        _ providers: [NSItemProvider],
        index: Int,
        items: [MobileWorkspaceListItem]
    ) {
        guard let target = MobileWorkspaceListItem.insertionDropTarget(items: items, index: index) else {
            return
        }
        _ = handleWorkspaceProviderDrop(providers, target: target)
    }
}
