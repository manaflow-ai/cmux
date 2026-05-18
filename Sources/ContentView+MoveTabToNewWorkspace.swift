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
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?

    func makeNSView(context: Context) -> SidebarBonsplitTabNewWorkspaceDropView {
        return SidebarBonsplitTabNewWorkspaceDropView()
    }

    func updateNSView(_ nsView: SidebarBonsplitTabNewWorkspaceDropView, context: Context) {
        nsView.isValidTransfer = {
            guard let transfer = BonsplitTabDragPayload.currentTransfer() else { return false }
            return AppDelegate.shared?.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id) ?? false
        }
        nsView.setDropActive = { isActive in
            dropIndicator = isActive ? SidebarDropIndicator(tabId: nil, edge: .bottom) : nil
        }
        nsView.performMove = {
            guard let transfer = BonsplitTabDragPayload.currentTransfer(),
                  let app = AppDelegate.shared,
                  let result = app.moveBonsplitTabToNewWorkspace(
                    tabId: transfer.tab.id,
                    destinationManager: tabManager,
                    focus: true,
                    focusWindow: true,
                    placementOverride: .end
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

final class SidebarBonsplitTabNewWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    var isValidTransfer: () -> Bool = { false }
    var setDropActive: (Bool) -> Void = { _ in }
    var performMove: () -> Bool = { false }

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
        acceptsDrag(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setDropActive(false) }
        guard acceptsDrag(sender) else { return false }
        return performMove()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setDropActive(false)
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else {
            setDropActive(false)
            return []
        }
        setDropActive(true)
        return .move
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
}
