import CmuxSettings
import Foundation

/// Applies the authoritative workspace receipt to an optional workspace group.
@MainActor
struct CloudWorkspaceGroupDestination {
    weak var tabManager: TabManager?
    let groupId: UUID?
    let placement: WorkspaceGroupNewPlacement
    let referenceWorkspaceId: UUID?
    let initialWorkspaceId: UUID?

    func apply(workspaceID: UUID) {
        guard let tabManager else { return }
        if let groupId {
            tabManager.addWorkspaceToGroup(
                workspaceId: workspaceID,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
        }
        guard let initialWorkspaceId,
              tabManager.tabs.count > 1,
              let initialWorkspace = tabManager.tabs.first(where: { $0.id == initialWorkspaceId }),
              tabManager.selectedWorkspace?.id != initialWorkspaceId else { return }
        tabManager.closeWorkspace(initialWorkspace, recordHistory: false)
    }
}
