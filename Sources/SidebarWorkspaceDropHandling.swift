import AppKit
import SwiftUI

struct SidebarEmptyArea: View {
    let rowSpacing: CGFloat
    let dropTargetWorkspaceIds: [UUID]
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let actions: VerticalTabsSidebar.SidebarWorkspaceActionBundle

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                let selectionSnapshot = actions.addWorkspaceAtEnd()
                if let selectedId = selectionSnapshot.selectedWorkspaceId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = selectionSnapshot.sidebarIndex
                }
                selection = .tabs
            }
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: actions.makeSidebarTabDropDelegate(
                nil,
                $draggedTabId,
                $selectedTabIds,
                $lastSidebarSelectionIndex,
                nil,
                dragAutoScrollController,
                $dropIndicator
            ))
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: $dropIndicator,
                    performMoveToNewWorkspace: actions.moveBonsplitTabToNewWorkspaceAtEnd
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        guard indicator.edge == .bottom, let lastTabId = dropTargetWorkspaceIds.last else { return false }
        return indicator.tabId == lastTabId
    }
}

struct SidebarWorkspaceDropState {
    let workspaceIds: [UUID]
    let pinnedWorkspaceIds: Set<UUID>
}

struct SidebarBonsplitTabDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let syncSidebarSelection: (_ preferredSelectedWorkspaceId: UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer(),
              let app = AppDelegate.shared else {
            return false
        }

        if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
           source.workspaceId == targetWorkspaceId {
            syncSidebarSelection(nil)
            return true
        }

        guard app.moveBonsplitTab(
            tabId: transfer.tab.id,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection(targetWorkspaceId)
        return true
    }
}

struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let visibleWorkspaceDropState: SidebarWorkspaceDropState
    let selectedWorkspaceId: () -> UUID?
    let reorderVisibleWorkspace: (_ draggedWorkspaceId: UUID, _ targetIndex: Int, _ visibleWorkspaceIds: [UUID]) -> Bool
    let syncSidebarSelection: (_ preferredSelectedWorkspaceId: UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let hasDrag = draggedTabId != nil
#if DEBUG
        cmuxDebugLog("sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") hasType=\(hasType) hasDrag=\(hasDrag)")
#endif
        return hasType && hasDrag
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        if dropIndicator?.tabId == targetTabId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
#if DEBUG
        cmuxDebugLog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        guard let draggedTabId else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        let dropState = visibleWorkspaceDropState
        guard let fromIndex = dropState.workspaceIds.firstIndex(of: draggedTabId) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        guard let targetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            indicator: dropIndicator,
            tabIds: dropState.workspaceIds,
            pinnedTabIds: dropState.pinnedWorkspaceIds
        ) else {
#if DEBUG
            cmuxDebugLog(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dropIndicator))"
            )
#endif
            return false
        }

        guard fromIndex != targetIndex else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            syncSidebarSelection(nil)
            return true
        }

#if DEBUG
        cmuxDebugLog("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        guard reorderVisibleWorkspace(draggedTabId, targetIndex, dropState.workspaceIds) else {
#if DEBUG
            cmuxDebugLog(
                "sidebar.drop.abort reason=reorderFailed tab=\(draggedTabId.uuidString.prefix(5)) " +
                "from=\(fromIndex) to=\(targetIndex)"
            )
#endif
            return false
        }
        if let selectedId = selectedWorkspaceId() {
            selectedTabIds = [selectedId]
            syncSidebarSelection(selectedId)
        } else {
            selectedTabIds = []
            syncSidebarSelection(nil)
        }
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        let dropState = visibleWorkspaceDropState
        let nextIndicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            tabIds: dropState.workspaceIds,
            pinnedTabIds: dropState.pinnedWorkspaceIds,
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}
