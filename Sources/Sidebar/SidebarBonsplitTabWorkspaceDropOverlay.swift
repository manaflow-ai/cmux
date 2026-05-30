import AppKit
import Bonsplit
import SwiftUI

struct SidebarBonsplitTabWorkspaceDropOverlay: NSViewRepresentable {
    let currentSelectedTabId: () -> UUID?
    let sidebarIndexForTabId: (UUID) -> Int?
    let moveToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let moveToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
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
        nsView.canPerformAction = { action, transfer in
            guard let app = AppDelegate.shared else {
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
        nsView.performExistingWorkspaceMove = { workspaceId, transfer in
            guard moveToExistingWorkspace(workspaceId, transfer) else { return false }
            selectedTabIds = [workspaceId]
            syncSidebarSelection(preferredSelectedTabId: workspaceId)
            return true
        }
        nsView.performNewWorkspaceMove = { insertionIndex, _, transfer in
            guard let destinationWorkspaceId = moveToNewWorkspace(insertionIndex, transfer) else { return false }
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
    var canPerformAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var updateAutoscroll: () -> Void = {}
    var setDropIndicator: (SidebarDropIndicator?) -> Void = { _ in }
    var performExistingWorkspaceMove: (UUID, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var performNewWorkspaceMove: (Int, SidebarDropIndicator, BonsplitTabDragPayload.Transfer) -> Bool = { _, _, _ in false }

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
        let accepted = acceptedTransfer(sender, action: action) != nil
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
        guard let action, let transfer = acceptedTransfer(sender, action: action) else {
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
            moved = performExistingWorkspaceMove(workspaceId, transfer)
        case .newWorkspace(let insertionIndex, let indicator):
            moved = performNewWorkspaceMove(insertionIndex, indicator, transfer)
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
        guard acceptedTransfer(sender, action: action) != nil, let action else {
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

    private func acceptedTransfer(
        _ sender: any NSDraggingInfo,
        action: SidebarDropPlanner.WorkspaceDropAction?
    ) -> BonsplitTabDragPayload.Transfer? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.types?.contains(Self.pasteboardType) == true,
              let transfer = BonsplitTabDragPayload.transfer(from: pasteboard),
              let action,
              canPerformAction(action, transfer) else {
            return nil
        }
        return transfer
    }

    private func action(for sender: any NSDraggingInfo) -> SidebarDropPlanner.WorkspaceDropAction? {
        SidebarDropPlanner.workspaceAction(for: localPoint(sender), targets: targets)
    }

    private func shouldCaptureHitTest() -> Bool {
        let eventType = NSApp.currentEvent?.type
        guard WindowInputRoutingContext.allowsWorkspaceDropOverlayHitTesting(eventType: eventType) else {
            return false
        }
        guard BonsplitTabDragPayload.canRouteWorkspaceDrop(
            pasteboardTypes: NSPasteboard(name: .drag).types
        ) else { return false }
        return true
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
