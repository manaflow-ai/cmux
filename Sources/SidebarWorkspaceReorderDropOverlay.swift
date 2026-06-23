import AppKit
import SwiftUI

struct SidebarWorkspaceReorderDropOverlay: NSViewRepresentable {
    typealias Target = SidebarWorkspaceReorderDropOverlayTarget
    typealias TargetBridge = SidebarWorkspaceReorderDropOverlayTargetBridge
    typealias DropView = SidebarWorkspaceReorderDropView

    let targetBridge: TargetBridge
    let isValidDrag: () -> Bool
    let updateDrag: (CGPoint, [Target]) -> Bool
    let performDrop: (CGPoint, [Target]) -> Bool
    let clearDropIndicator: () -> Void
    let setWorkspaceDropTargetCollectionActive: (Bool) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes([Self.pasteboardType])
        update(view)
        targetBridge.attach(view)
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        update(nsView)
        targetBridge.attach(nsView)
    }

    private func update(_ view: DropView) {
        view.isValidDrag = isValidDrag
        view.updateDrag = updateDrag
        view.performDropAtPoint = performDrop
        view.clearDropIndicator = clearDropIndicator
        view.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
    }

    static let pasteboardType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    static func shouldCaptureHitTest(
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard WindowInputRoutingContext.allowsWorkspaceDropOverlayHitTesting(eventType: eventType) else {
            return false
        }
        return pasteboardTypes?.contains(pasteboardType) == true
    }
}
