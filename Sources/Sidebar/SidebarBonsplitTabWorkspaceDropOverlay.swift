import AppKit
import Bonsplit
import SwiftUI

struct SidebarBonsplitTabWorkspaceDropOverlay: NSViewRepresentable {
    let currentSelectedTabId: () -> UUID?
    let sidebarIndexForTabId: (UUID) -> Int?
    let moveToExistingWorkspace: (UUID) -> Bool
    let moveToNewWorkspace: (Int) -> UUID?
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
        nsView.hasValidTransfer = {
            BonsplitTabDragPayload.currentTransfer() != nil
        }
        nsView.canPerformAction = { action in
            guard let transfer = BonsplitTabDragPayload.currentTransfer(),
                  let app = AppDelegate.shared else {
                return false
            }
            switch action {
            case .existingWorkspace(let workspaceId):
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.canMoveBonsplitTab(tabId: transfer.tab.id, toWorkspace: workspaceId)
            case .newWorkspace:
                return app.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id)
            }
        }
        nsView.updateAutoscroll = updateAutoscroll
        nsView.setDropIndicator = { indicator in
            dropIndicator = indicator
        }
        nsView.performExistingWorkspaceMove = { workspaceId in
            guard moveToExistingWorkspace(workspaceId) else { return false }
            selectedTabIds = [workspaceId]
            syncSidebarSelection(preferredSelectedTabId: workspaceId)
            return true
        }
        nsView.performNewWorkspaceMove = { insertionIndex, _ in
            guard let destinationWorkspaceId = moveToNewWorkspace(insertionIndex) else { return false }
            selectedTabIds = [destinationWorkspaceId]
            syncSidebarSelection(preferredSelectedTabId: destinationWorkspaceId)
            return true
        }
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? currentSelectedTabId()
        if let selectedId {
            lastSidebarSelectionIndex = sidebarIndexForTabId(selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

final class SidebarBonsplitTabWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    var targets: [SidebarDropPlanner.WorkspaceDropTarget] = []
    var hasValidTransfer: () -> Bool = { false }
    var canPerformAction: (SidebarDropPlanner.WorkspaceDropAction) -> Bool = { _ in false }
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
        updateDrag(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.exited clear=1")
#endif
        setDropIndicator(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let action = action(for: sender)
        let accepted = acceptsDrag(sender, action: action)
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.prepare accepted=\(accepted ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return accepted
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setDropIndicator(nil) }
        let action = action(for: sender)
        guard acceptsDrag(sender, action: action), let action else {
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.perform moved=0 reason=notAccepted " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return false
        }

        let moved: Bool
        switch action {
        case .existingWorkspace(let workspaceId):
            moved = performExistingWorkspaceMove(workspaceId)
        case .newWorkspace(let insertionIndex, let indicator):
            moved = performNewWorkspaceMove(insertionIndex, indicator)
        }

#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.perform moved=\(moved ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return moved
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.concluded clear=1")
#endif
        setDropIndicator(nil)
    }

    private func updateDrag(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let action = action(for: sender)
        guard acceptsDrag(sender, action: action), let action else {
            setDropIndicator(nil)
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.\(phase) accepted=0 clear=1 " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return []
        }

        updateAutoscroll()
        switch action {
        case .newWorkspace(_, let indicator):
            setDropIndicator(indicator)
        case .existingWorkspace:
            setDropIndicator(nil)
        }

#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.\(phase) accepted=1 " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return .move
    }

    private func acceptsDrag(
        _ sender: any NSDraggingInfo,
        action: SidebarDropPlanner.WorkspaceDropAction?
    ) -> Bool {
        guard sender.draggingPasteboard.types?.contains(Self.pasteboardType) == true else { return false }
        guard hasValidTransfer(), let action else { return false }
        return canPerformAction(action)
    }

    private func action(for sender: any NSDraggingInfo) -> SidebarDropPlanner.WorkspaceDropAction? {
        SidebarDropPlanner.workspaceAction(for: localPoint(sender), targets: targets)
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

#if DEBUG
    private func debugActionDescription(_ action: SidebarDropPlanner.WorkspaceDropAction?) -> String {
        guard let action else { return "nil" }
        switch action {
        case .existingWorkspace(let workspaceId):
            return "existing:\(debugShortId(workspaceId))"
        case .newWorkspace(let insertionIndex, let indicator):
            return "new:index=\(insertionIndex),indicator=\(debugIndicatorDescription(indicator))"
        }
    }

    private func debugIndicatorDescription(_ indicator: SidebarDropIndicator) -> String {
        let target = indicator.tabId.map(debugShortId) ?? "end"
        let edge = indicator.edge == .top ? "top" : "bottom"
        return "\(target):\(edge)"
    }

    private func debugShortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(5))
    }
#endif
}
