import AppKit
import SwiftUI
import CmuxSidebar

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
    let pointOffset: CGSize

    init(
        targetBridge: TargetBridge,
        isValidDrag: @escaping () -> Bool,
        updateDrag: @escaping (CGPoint, [Target]) -> Bool,
        performDrop: @escaping (CGPoint, [Target]) -> Bool,
        clearDropIndicator: @escaping () -> Void,
        setWorkspaceDropTargetCollectionActive: @escaping (Bool) -> Void,
        pointOffset: CGSize = .zero
    ) {
        self.targetBridge = targetBridge
        self.isValidDrag = isValidDrag
        self.updateDrag = updateDrag
        self.performDrop = performDrop
        self.clearDropIndicator = clearDropIndicator
        self.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
        self.pointOffset = pointOffset
    }

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
        view.pointOffset = pointOffset
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
