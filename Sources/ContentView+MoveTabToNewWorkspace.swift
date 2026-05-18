import AppKit
import SwiftUI

extension ContentView {
    func appendMoveTabToNewWorkspaceCommandContribution(
        to contributions: inout [CommandPaletteCommandContribution],
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveTabToNewWorkspace",
                title: { _ in String(localized: "command.moveTabToNewWorkspace.title", defaultValue: "Move Tab to New Workspace") },
                subtitle: panelSubtitle,
                keywords: ["move", "tab", "workspace", "detach", "sidebar", "surface"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) },
                enablement: { $0.bool(CommandPaletteContextKeys.panelCanMoveToNewWorkspace) }
            )
        )
    }

    func moveFocusedPanelToNewWorkspace() -> Bool {
        guard let panelContext = focusedPanelContext else { return false }
        return AppDelegate.shared?.moveSurfaceToNewWorkspace(
            panelId: panelContext.panelId,
            focus: true,
            focusWindow: false
        ) != nil
    }
}

struct SidebarBonsplitTabNewWorkspaceDropOverlay: NSViewRepresentable {
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?
    let performMoveToNewWorkspace: (BonsplitTabDragPayload.Transfer) -> (workspaceId: UUID, sidebarIndex: Int?)?

    func makeNSView(context: Context) -> SidebarBonsplitTabNewWorkspaceDropView {
        return SidebarBonsplitTabNewWorkspaceDropView()
    }

    func updateNSView(_ nsView: SidebarBonsplitTabNewWorkspaceDropView, context: Context) {
        nsView.isValidTransfer = { transfer in
            return AppDelegate.shared?.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id) ?? false
        }
        nsView.setDropActive = { isActive in
            dropIndicator = isActive ? SidebarDropIndicator(tabId: nil, edge: .bottom) : nil
        }
        nsView.performMove = { transfer in
            guard let result = performMoveToNewWorkspace(transfer) else {
                return false
            }

            selectedTabIds = [result.workspaceId]
            lastSidebarSelectionIndex = result.sidebarIndex
            return true
        }
    }
}

final class SidebarBonsplitTabNewWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    var isValidTransfer: (BonsplitTabDragPayload.Transfer) -> Bool = { _ in false }
    var setDropActive: (Bool) -> Void = { _ in }
    var performMove: (BonsplitTabDragPayload.Transfer) -> Bool = { _ in false }

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let capture = shouldCaptureHitTest()
        guard capture else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropActive(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptedTransfer(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setDropActive(false) }
        guard let transfer = acceptedTransfer(sender) else { return false }
        return performMove(transfer)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setDropActive(false)
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptedTransfer(sender) != nil else {
            setDropActive(false)
            return []
        }
        setDropActive(true)
        return .move
    }

    private func acceptedTransfer(_ sender: any NSDraggingInfo) -> BonsplitTabDragPayload.Transfer? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.types?.contains(Self.pasteboardType) == true,
              let transfer = BonsplitTabDragPayload.transfer(from: pasteboard),
              isValidTransfer(transfer) else {
            return nil
        }
        return transfer
    }

    private func shouldCaptureHitTest() -> Bool {
        guard BonsplitTabDragPayload.canRouteWorkspaceDrop(
            pasteboardTypes: NSPasteboard(name: .drag).types
        ) else { return false }
        guard let eventType = NSApp.currentEvent?.type else { return true }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .cursorUpdate, .mouseMoved:
            return true
        default:
            return false
        }
    }
}
