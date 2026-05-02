import AppKit
import SwiftUI

struct SidebarBonsplitTabWorkspaceDropOverlay: NSViewRepresentable {
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?
    let updateAutoscroll: () -> Void
    let targets: [SidebarDropPlanner.WorkspaceDropTarget]

    func makeNSView(context: Context) -> SidebarBonsplitTabWorkspaceDropView {
        SidebarBonsplitTabWorkspaceDropView()
    }

    func updateNSView(_ nsView: SidebarBonsplitTabWorkspaceDropView, context: Context) {
        nsView.targets = targets
        nsView.isValidTransfer = {
            guard let transfer = BonsplitTabDragPayload.currentTransfer() else { return false }
            return AppDelegate.shared?.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id) ?? false
        }
        nsView.updateAutoscroll = updateAutoscroll
        nsView.setDropIndicator = { indicator in
            dropIndicator = indicator
        }
        nsView.performExistingWorkspaceMove = { workspaceId in
            guard let transfer = BonsplitTabDragPayload.currentTransfer(),
                  let app = AppDelegate.shared else {
                return false
            }
            if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
               source.workspaceId == workspaceId {
                syncSidebarSelection()
                return true
            }
            guard app.moveBonsplitTab(
                tabId: transfer.tab.id,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            ) else {
                return false
            }
            selectedTabIds = [workspaceId]
            syncSidebarSelection(preferredSelectedTabId: workspaceId)
            return true
        }
        nsView.performNewWorkspaceMove = { insertionIndex, _ in
            guard let transfer = BonsplitTabDragPayload.currentTransfer(),
                  let app = AppDelegate.shared,
                  let result = app.moveBonsplitTabToNewWorkspace(
                    tabId: transfer.tab.id,
                    destinationManager: tabManager,
                    focus: true,
                    focusWindow: true,
                    insertionIndexOverride: insertionIndex
                  ) else {
                return false
            }

            selectedTabIds = [result.destinationWorkspaceId]
            syncSidebarSelection(preferredSelectedTabId: result.destinationWorkspaceId)
            return true
        }
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

final class SidebarBonsplitTabWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    var targets: [SidebarDropPlanner.WorkspaceDropTarget] = []
    var isValidTransfer: () -> Bool = { false }
    var updateAutoscroll: () -> Void = {}
    var setDropIndicator: (SidebarDropIndicator?) -> Void = { _ in }
    var performExistingWorkspaceMove: (UUID) -> Bool = { _ in false }
    var performNewWorkspaceMove: (Int, SidebarDropIndicator) -> Bool = { _, _ in false }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureHitTest() ? super.hitTest(point) : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropIndicator(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsDrag(sender) && SidebarDropPlanner.workspaceAction(for: localPoint(sender), targets: targets) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setDropIndicator(nil) }
        guard acceptsDrag(sender),
              let action = SidebarDropPlanner.workspaceAction(for: localPoint(sender), targets: targets) else {
            return false
        }

        let moved: Bool
        switch action {
        case .existingWorkspace(let workspaceId):
            moved = performExistingWorkspaceMove(workspaceId)
        case .newWorkspace(let insertionIndex, let indicator):
            moved = performNewWorkspaceMove(insertionIndex, indicator)
        }

        return moved
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setDropIndicator(nil)
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else {
            setDropIndicator(nil)
            return []
        }

        updateAutoscroll()
        let point = localPoint(sender)
        let action = SidebarDropPlanner.workspaceAction(for: point, targets: targets)
        switch action {
        case .newWorkspace(_, let indicator):
            setDropIndicator(indicator)
        case .existingWorkspace, nil:
            setDropIndicator(nil)
        }

        return action == nil ? [] : .move
    }

    private func acceptsDrag(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.types?.contains(Self.pasteboardType) == true else { return false }
        return isValidTransfer()
    }

    private func shouldCaptureHitTest() -> Bool {
        guard BonsplitTabDragPayload.currentTransfer() != nil else { return false }
        guard let eventType = NSApp.currentEvent?.type else { return true }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .cursorUpdate, .mouseMoved:
            return true
        default:
            return false
        }
    }

    private func localPoint(_ sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }
}
