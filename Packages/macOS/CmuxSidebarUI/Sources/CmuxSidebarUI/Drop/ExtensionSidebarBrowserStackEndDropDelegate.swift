public import SwiftUI
public import CmuxAppKitSupportUI
public import CmuxFoundation
public import CmuxSidebarProviderKit
internal import CmuxSidebar

/// `DropDelegate` for the trailing end-strip of an extension sidebar's
/// browser-stack column: dropping here appends the dragged provider row to the
/// end of the ordered list.
///
/// Like ``ExtensionSidebarBrowserStackDropDelegate`` it is self-contained,
/// reasoning only over the immutable ``ExtensionSidebarBrowserStackDropRow``
/// snapshot and reporting the resulting ``CmuxSidebarProviderWorkspaceMove``
/// back through the injected `onMove` closure.
@MainActor
public struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    private let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding private var draggedTabId: UUID?
    private let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding private var dropIndicator: SidebarDropIndicator?
    private let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    /// Creates the end-strip drop delegate.
    /// - Parameters:
    ///   - orderedRows: The ordered provider rows in the browser stack.
    ///   - draggedTabId: Binding to the workspace id currently being dragged.
    ///   - dragAutoScrollController: Drives edge auto-scroll during the drag.
    ///   - dropIndicator: Binding to the rendered drop-indicator position.
    ///   - onMove: Commits the planned move, returning whether it succeeded.
    public init(
        orderedRows: [ExtensionSidebarBrowserStackDropRow],
        draggedTabId: Binding<UUID?>,
        dragAutoScrollController: SidebarDragAutoScrollController,
        dropIndicator: Binding<SidebarDropIndicator?>,
        onMove: @escaping (CmuxSidebarProviderWorkspaceMove) -> Bool
    ) {
        self.orderedRows = orderedRows
        self._draggedTabId = draggedTabId
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
        updateDropIndicator()
    }

    public func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}
