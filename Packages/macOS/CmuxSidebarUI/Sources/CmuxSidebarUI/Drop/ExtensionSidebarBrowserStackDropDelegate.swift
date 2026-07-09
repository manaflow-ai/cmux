public import SwiftUI
public import CmuxAppKitSupportUI
public import CmuxFoundation
public import CmuxSidebarProviderKit
internal import CmuxSidebar

/// `DropDelegate` for reordering provider-backed workspace rows *onto another
/// row* inside an extension sidebar's browser-stack column.
///
/// The delegate is fully self-contained: it reasons only over the immutable
/// ``ExtensionSidebarBrowserStackDropRow`` snapshot it is handed, plans the drop
/// position with ``SidebarDropPlanner`` and
/// ``ExtensionSidebarBrowserStackDropPlanner``, and reports the resulting
/// ``CmuxSidebarProviderWorkspaceMove`` back through the injected `onMove`
/// closure. It holds no app-target model reference; the dragged-row binding and
/// drop-indicator binding are owned by the host view, and auto-scroll is driven
/// through ``SidebarDragAutoScrollController``.
@MainActor
public struct ExtensionSidebarBrowserStackDropDelegate: DropDelegate {
    private let targetWorkspaceId: UUID
    private let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding private var draggedTabId: UUID?
    private let targetRowHeight: CGFloat?
    private let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding private var dropIndicator: SidebarDropIndicator?
    private let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    /// Creates the drop delegate for one target row.
    /// - Parameters:
    ///   - targetWorkspaceId: The workspace id of the hovered row.
    ///   - orderedRows: The ordered provider rows in the browser stack.
    ///   - draggedTabId: Binding to the workspace id currently being dragged.
    ///   - targetRowHeight: The hovered row's height, used to bias the
    ///     top/bottom drop edge by the pointer's vertical position.
    ///   - dragAutoScrollController: Drives edge auto-scroll during the drag.
    ///   - dropIndicator: Binding to the rendered drop-indicator position.
    ///   - onMove: Commits the planned move, returning whether it succeeded.
    public init(
        targetWorkspaceId: UUID,
        orderedRows: [ExtensionSidebarBrowserStackDropRow],
        draggedTabId: Binding<UUID?>,
        targetRowHeight: CGFloat?,
        dragAutoScrollController: SidebarDragAutoScrollController,
        dropIndicator: Binding<SidebarDropIndicator?>,
        onMove: @escaping (CmuxSidebarProviderWorkspaceMove) -> Bool
    ) {
        self.targetWorkspaceId = targetWorkspaceId
        self.orderedRows = orderedRows
        self._draggedTabId = draggedTabId
        self.targetRowHeight = targetRowHeight
        self.dragAutoScrollController = dragAutoScrollController
        self._dropIndicator = dropIndicator
        self.onMove = onMove
    }

    public func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    public func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    public func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == targetWorkspaceId {
            dropIndicator = nil
        }
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId else {
            return false
        }
        let resolvedDropIndicator = plannedDropIndicator(for: info)
        guard let insertionPosition = insertionPosition(
            draggedWorkspaceId: draggedTabId,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        guard let move = move(
            draggedWorkspaceId: draggedTabId,
            insertionPosition: insertionPosition,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator(for info: DropInfo) {
        let nextIndicator = plannedDropIndicator(for: info)
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func plannedDropIndicator(for info: DropInfo) -> SidebarDropIndicator? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        return SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetWorkspaceId,
            tabIds: workspaceIds,
            pinnedTabIds: [],
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        ) ?? ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).sectionBoundaryIndicator(
            draggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetWorkspaceId,
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        )
    }

    private func insertionPosition(draggedWorkspaceId: UUID, indicator: SidebarDropIndicator?) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        if let indicator {
            if let indicatorWorkspaceId = indicator.tabId {
                guard let indicatorIndex = workspaceIds.firstIndex(of: indicatorWorkspaceId) else { return nil }
                return indicator.edge == .bottom ? indicatorIndex + 1 : indicatorIndex
            }
            return workspaceIds.count
        }

        guard let sourceIndex = workspaceIds.firstIndex(of: draggedWorkspaceId),
              let targetIndex = workspaceIds.firstIndex(of: targetWorkspaceId) else {
            return nil
        }
        return sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        indicator: SidebarDropIndicator?
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: draggedWorkspaceId,
            insertionPosition: insertionPosition,
            preferredTargetSectionId: preferredTargetSectionId(indicator: indicator)
        )
    }

    private func preferredTargetSectionId(indicator: SidebarDropIndicator?) -> String? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).preferredSectionId(
            targetWorkspaceId: targetWorkspaceId,
            indicator: indicator
        )
    }
}
