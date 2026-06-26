import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebar
import SwiftUI
import CmuxSettings

enum SidebarWorkspaceGroupHeaderDropZone {
    static func isCenterDrop(locationY: CGFloat, rowHeight: CGFloat) -> Bool {
        let height = max(rowHeight, 1)
        let edgeBand = min(max(height * 0.25, 4), height * 0.4)
        let y = min(max(locationY, 0), height)
        return y > edgeBand && y < height - edgeBand
    }
}

enum SidebarWorkspaceGroupHeaderDropAction: Equatable {
    case addWorkspaceToGroup(UUID)
    case noOp
}

enum SidebarWorkspaceGroupHeaderDropPolicy {
    static func action(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceIsPinned: Bool,
        draggedWorkspaceGroupId: UUID?,
        draggedWorkspaceIsGroupAnchor: Bool,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        targetAnchorMatchesGroup: Bool,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              targetAnchorMatchesGroup,
              SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return nil
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return .noOp
        }
        guard !draggedWorkspaceIsPinned,
              !draggedWorkspaceIsGroupAnchor else {
            return nil
        }
        return .addWorkspaceToGroup(draggedWorkspaceId)
    }

    static func shouldConsumeNoOpEdgeDrop(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceGroupId: UUID?,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> Bool {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              tabIds.count > 1,
              tabIds.contains(draggedWorkspaceId),
              tabIds.contains(targetAnchorWorkspaceId),
              !SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return false
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return true
        }
        return SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: targetAnchorWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: locationY,
            targetHeight: rowHeight
        ) == nil
    }
}

@MainActor
struct SidebarWorkspaceGroupHeaderDropDelegate: DropDelegate {
    let targetGroupId: UUID
    let targetAnchorWorkspaceId: UUID
    let tabManager: TabManager
    let dragState: SidebarDragState
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    let reorderDelegate: SidebarTabDropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        reorderDelegate.validateDrop(info: info) || groupHeaderCenterDropAction(info) != nil
    }

    func dropEntered(info: DropInfo) {
        if updateGroupHeaderCenterDrop(info) { return }
        reorderDelegate.dropEntered(info: info)
    }

    func dropExited(info: DropInfo) {
        reorderDelegate.dropExited(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if updateGroupHeaderCenterDrop(info) {
            return DropProposal(operation: .move)
        }
        return reorderDelegate.dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let action = groupHeaderCenterDropAction(info) else {
            if shouldConsumeGroupHeaderNoOpEdgeDrop(info) {
                clearDropState()
                return true
            }
            return reorderDelegate.performDrop(info: info)
        }
        defer { clearDropState() }
        switch action {
        case .addWorkspaceToGroup(let draggedTabId):
            tabManager.addWorkspaceToGroup(workspaceId: draggedTabId, groupId: targetGroupId)
        case .noOp:
            break
        }
        return true
    }

    private func updateGroupHeaderCenterDrop(_ info: DropInfo) -> Bool {
        guard groupHeaderCenterDropAction(info) != nil else { return false }
        dragAutoScrollController.updateFromDragLocation()
        dragState.clearDropIndicator()
        return true
    }

    private func groupHeaderCenterDropAction(_ info: DropInfo) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }),
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }) else {
            return nil
        }
        return SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceIsPinned: draggedTab.isPinned,
            draggedWorkspaceGroupId: draggedTab.groupId,
            draggedWorkspaceIsGroupAnchor: tabManager.workspaceGroups.contains {
                $0.anchorWorkspaceId == draggedTabId
            },
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            targetAnchorMatchesGroup: group.anchorWorkspaceId == targetAnchorWorkspaceId,
            locationY: info.location.y,
            rowHeight: targetRowHeight ?? 1
        )
    }

    private func shouldConsumeGroupHeaderNoOpEdgeDrop(_ info: DropInfo) -> Bool {
        let height = targetRowHeight ?? 1
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }) else { return false }
        return SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceGroupId: draggedTab.groupId,
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            tabIds: tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            pinnedTabIds: tabManager.sidebarReorderPinnedWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            locationY: info.location.y,
            rowHeight: height
        )
    }

    private func clearDropState() {
        dragState.clearDrag()
        dragAutoScrollController.stop()
    }
}
