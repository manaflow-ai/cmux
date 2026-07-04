import CmuxFoundation
import CmuxWorkspaces
import Foundation

@MainActor
struct SidebarDropIndicatorRowScopeResolver {
    let tabs: [Workspace]
    let workspaceGroups: [WorkspaceGroup]
    let workspaceRenderItems: [SidebarWorkspaceRenderItem]
    let topLevelWorkspaceRowIds: [UUID]

    func rowIds(for scope: SidebarWorkspaceReorderDropIndicatorScope) -> [UUID] {
        switch scope {
        case .raw:
            return tabs.map(\.id)
        case .topLevel:
            return topLevelWorkspaceRowIds
        case .group(let groupId):
            return groupRowIds(for: groupId)
        }
    }

    private func groupRowIds(for groupId: UUID) -> [UUID] {
        guard workspaceGroups.contains(where: { $0.id == groupId }),
              let rootIndex = workspaceRenderItems.firstIndex(where: { item in
                  if case .groupHeader(let group, _, _) = item {
                      return group.id == groupId
                  }
                  return false
              }) else {
            return []
        }

        let rootDepth = workspaceRenderItems[rootIndex].depth
        var rowIds: [UUID] = []
        rowIds.reserveCapacity(workspaceRenderItems.count - rootIndex)
        for index in rootIndex..<workspaceRenderItems.count {
            let item = workspaceRenderItems[index]
            if !rowIds.isEmpty && item.depth <= rootDepth {
                break
            }
            rowIds.append(item.rowWorkspaceId)
        }
        return rowIds
    }
}
