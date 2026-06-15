import CmuxFoundation
import CoreGraphics
import Foundation

/// Pure planner for browser-stack sidebar drag/drop: resolves the target
/// section + index for a workspace move, the preferred target section under an
/// indicator, and the section-boundary indicator to render while dragging
/// across sections.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum ExtensionSidebarBrowserStackDropPlanner {
    public static func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow],
        preferredTargetSectionId: String? = nil
    ) -> CmuxSidebarProviderWorkspaceMove? {
        guard let sourceIndex = orderedRows.firstIndex(where: { $0.workspaceId == draggedWorkspaceId }) else {
            return nil
        }
        let sourceRow = orderedRows[sourceIndex]
        let remainingRows = orderedRows.filter { $0.workspaceId != draggedWorkspaceId }
        guard !remainingRows.isEmpty else { return nil }
        let adjustedInsertionPosition = insertionPosition > sourceIndex
            ? insertionPosition - 1
            : insertionPosition
        let clampedInsertionPosition = min(max(adjustedInsertionPosition, 0), remainingRows.count)

        let targetSectionId: String
        let targetIndex: Int
        if let preferredTargetSectionId {
            targetSectionId = preferredTargetSectionId
            targetIndex = remainingRows[..<clampedInsertionPosition].filter { $0.sectionId == targetSectionId }.count
        } else if clampedInsertionPosition < remainingRows.count {
            let targetRow = remainingRows[clampedInsertionPosition]
            targetSectionId = targetRow.sectionId
            targetIndex = remainingRows[..<clampedInsertionPosition].filter { $0.sectionId == targetSectionId }.count
        } else if let targetRow = remainingRows.last {
            targetSectionId = targetRow.sectionId
            targetIndex = remainingRows.filter { $0.sectionId == targetSectionId }.count
        } else {
            targetSectionId = sourceRow.sectionId
            targetIndex = 0
        }

        return CmuxSidebarProviderWorkspaceMove(
            workspaceId: draggedWorkspaceId,
            sourceSectionId: sourceRow.sectionId,
            targetSectionId: targetSectionId,
            targetIndex: targetIndex
        )
    }

    public static func preferredSectionId(
        targetWorkspaceId: UUID,
        indicator: SidebarDropIndicator?,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> String? {
        guard let targetIndex = orderedRows.firstIndex(where: { $0.workspaceId == targetWorkspaceId }) else {
            return nil
        }
        let targetRow = orderedRows[targetIndex]
        guard let indicator,
              let indicatorWorkspaceId = indicator.tabId,
              let indicatorIndex = orderedRows.firstIndex(where: { $0.workspaceId == indicatorWorkspaceId }) else {
            return targetRow.sectionId
        }
        if indicatorWorkspaceId == targetWorkspaceId {
            return targetRow.sectionId
        }
        if indicator.edge == .top, indicatorIndex == targetIndex + 1 {
            return targetRow.sectionId
        }
        return orderedRows[indicatorIndex].sectionId
    }

    public static func sectionBoundaryIndicator(
        draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID,
        pointerY: CGFloat?,
        targetHeight: CGFloat?,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> SidebarDropIndicator? {
        guard let draggedWorkspaceId,
              let sourceIndex = orderedRows.firstIndex(where: { $0.workspaceId == draggedWorkspaceId }),
              let targetIndex = orderedRows.firstIndex(where: { $0.workspaceId == targetWorkspaceId }),
              orderedRows[sourceIndex].sectionId != orderedRows[targetIndex].sectionId else {
            return nil
        }
        let edge: SidebarDropEdge
        if let pointerY, let targetHeight {
            edge = SidebarDropPlanner().edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
        } else {
            edge = sourceIndex < targetIndex ? .top : .bottom
        }
        if sourceIndex + 1 == targetIndex, edge == .top {
            return SidebarDropIndicator(tabId: targetWorkspaceId, edge: .top)
        }
        if targetIndex + 1 == sourceIndex, edge == .bottom {
            return SidebarDropIndicator(tabId: targetWorkspaceId, edge: .bottom)
        }
        return nil
    }
}
