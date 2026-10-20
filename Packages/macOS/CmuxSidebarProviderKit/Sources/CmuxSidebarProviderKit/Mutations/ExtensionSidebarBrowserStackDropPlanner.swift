import CmuxFoundation
import CoreGraphics
import Foundation

/// Pure planner for browser-stack sidebar drag/drop over an ordered set of rows.
///
/// Construct it with the rows currently displayed in the browser stack, then ask
/// it to resolve the target section + index for a workspace move, the preferred
/// target section under an indicator, or the section-boundary indicator to
/// render while dragging across sections. Holds no mutable state.
public struct ExtensionSidebarBrowserStackDropPlanner {
    /// The browser-stack rows, in display order, the plan operates over.
    public let orderedRows: [ExtensionSidebarBrowserStackDropRow]

    /// Creates a planner over the given ordered browser-stack rows.
    public init(orderedRows: [ExtensionSidebarBrowserStackDropRow]) {
        self.orderedRows = orderedRows
    }

    /// Resolves the cross-section move for a dragged workspace dropped at
    /// `insertionPosition`, optionally pinned to `preferredTargetSectionId`.
    public func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
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

    /// The section a drop on `targetWorkspaceId` should land in, given the
    /// current drop `indicator`.
    public func preferredSectionId(
        targetWorkspaceId: UUID,
        indicator: SidebarDropIndicator?
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

    /// The boundary indicator to render when dragging across a section edge, or
    /// `nil` when the drag is within a single section.
    public func sectionBoundaryIndicator(
        draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID,
        pointerY: CGFloat?,
        targetHeight: CGFloat?
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
