import Foundation

@MainActor
extension TabManager {
    var numberedWorkspaceShortcutWorkspaceIds: [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        return SidebarWorkspaceRenderItem.numberedShortcutWorkspaceIds(
            tabs: tabs,
            groupsById: groupsById
        )
    }

    @discardableResult
    func selectWorkspaceByShortcutDigit(_ digit: Int) -> Bool {
        guard let workspaceId = WorkspaceShortcutMapper.workspaceId(
            forDigit: digit,
            workspaceIds: numberedWorkspaceShortcutWorkspaceIds
        ),
              let workspace = tabs.first(where: { $0.id == workspaceId }) else {
            return false
        }
        selectWorkspace(workspace)
        return true
    }
}
