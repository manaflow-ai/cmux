import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Extension browser stack drop targets
struct ExtensionSidebarBrowserStackEmptyArea: View {
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

struct ExtensionSidebarBrowserStackDropRow: Equatable {
    let workspaceId: UUID
    let sectionId: String
}

enum ExtensionSidebarBrowserStackDropPlanner {
    static func move(
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

    static func preferredSectionId(
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

    static func sectionBoundaryIndicator(
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
            edge = SidebarDropPlanner.edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
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

struct ExtensionSidebarBrowserStackDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == targetWorkspaceId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
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

    func updateDropIndicator(for info: DropInfo) {
        let nextIndicator = plannedDropIndicator(for: info)
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func plannedDropIndicator(for info: DropInfo) -> SidebarDropIndicator? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        return SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetWorkspaceId,
            tabIds: workspaceIds,
            pinnedTabIds: [],
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        ) ?? ExtensionSidebarBrowserStackDropPlanner.sectionBoundaryIndicator(
            draggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetWorkspaceId,
            pointerY: info.location.y,
            targetHeight: targetRowHeight,
            orderedRows: orderedRows
        )
    }

    func insertionPosition(draggedWorkspaceId: UUID, indicator: SidebarDropIndicator?) -> Int? {
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

    func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        indicator: SidebarDropIndicator?
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: draggedWorkspaceId,
            insertionPosition: insertionPosition,
            orderedRows: orderedRows,
            preferredTargetSectionId: preferredTargetSectionId(indicator: indicator)
        )
    }

    private func preferredTargetSectionId(indicator: SidebarDropIndicator?) -> String? {
        ExtensionSidebarBrowserStackDropPlanner.preferredSectionId(
            targetWorkspaceId: targetWorkspaceId,
            indicator: indicator,
            orderedRows: orderedRows
        )
    }
}

private struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner.move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition,
                orderedRows: orderedRows
              ) else {
            return false
        }
        return onMove(move)
    }

    func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner.indicator(
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
        guard SidebarDropPlanner.indicator(
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

