import Foundation

@MainActor
extension TabManager {
    /// Selects a workspace by the order of ordinary rows rendered in the sidebar.
    ///
    /// Group anchors are represented by group headers, so they are intentionally
    /// absent from this numbered order. Collapsed child rows are absent as well.
    /// In an automatic Group By mode the numbers follow the drawn sections, where
    /// every workspace (a manual anchor included) is an ordinary row.
    @discardableResult
    func selectWorkspaceByNumber(_ digit: Int) -> Int? {
        let workspaceIds: [UUID]
        if let projection = automaticSidebarGroupingProjection() {
            workspaceIds = SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: projection.renderItems)
        } else {
            let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
            workspaceIds = SidebarWorkspaceRenderItem.numberedWorkspaceIds(
                tabs: tabs,
                groupsById: groupsById
            )
        }
        guard let targetIndex = WorkspaceShortcutMapper.workspaceIndex(
            forDigit: digit,
            workspaceCount: workspaceIds.count
        ),
        let workspace = tabs.first(where: { $0.id == workspaceIds[targetIndex] }) else {
            return nil
        }
        selectWorkspace(workspace)
        return targetIndex
    }
}
