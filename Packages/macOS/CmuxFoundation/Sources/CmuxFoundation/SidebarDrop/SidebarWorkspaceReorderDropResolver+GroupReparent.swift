import CoreGraphics
import Foundation

extension SidebarWorkspaceReorderDropResolver {
    func groupReparentPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let target = context.target,
              target.isGroupHeader,
              let targetGroupId = target.groupId,
              let targetGroup = groupsById[targetGroupId],
              target.workspaceId == targetGroup.anchorWorkspaceId,
              let draggedGroup = groupByAnchorId[draggedWorkspace.id],
              draggedGroup.id != targetGroupId,
              isCenterGroupHeaderDrop(pointerY: context.pointerY, targetHeight: context.targetHeight),
              canReparent(groupId: draggedGroup.id, to: targetGroupId, groupsById: groupsById) else {
            return nil
        }
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: nil,
            indicatorScope: .group(targetGroupId),
            action: .reparentGroup(groupId: draggedGroup.id, parentGroupId: targetGroupId)
        )
    }

    func pointerY(for edge: SidebarDropEdge, targetHeight: CGFloat?) -> CGFloat? {
        guard let targetHeight else { return nil }
        return edge == .top ? 0 : targetHeight
    }

    func rootGroup(
        containing groupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> SidebarWorkspaceReorderGroupSnapshot? {
        guard var root = groupsById[groupId] else { return nil }
        var visited: Set<UUID> = [root.id]
        while let parentId = root.parentGroupId,
              let parent = groupsById[parentId],
              visited.insert(parent.id).inserted {
            root = parent
        }
        return root
    }

    func isCenterGroupHeaderDrop(pointerY: CGFloat?, targetHeight: CGFloat?) -> Bool {
        guard let pointerY, let targetHeight else { return false }
        let height = max(targetHeight, 1)
        let edgeBand = min(max(height * 0.25, 4), height * 0.4)
        let y = min(max(pointerY, 0), height)
        return y > edgeBand && y < height - edgeBand
    }

    private func canReparent(
        groupId: UUID,
        to parentGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Bool {
        guard groupsById[groupId] != nil,
              groupsById[parentGroupId] != nil,
              groupId != parentGroupId else {
            return false
        }
        var visited: Set<UUID> = []
        var cursor: UUID? = parentGroupId
        while let current = cursor {
            guard visited.insert(current).inserted else { return false }
            if current == groupId { return false }
            cursor = groupsById[current]?.parentGroupId
        }
        return true
    }
}
