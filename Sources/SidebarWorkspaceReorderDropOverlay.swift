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
    let performPendingDrop: ((SidebarWorkspaceReorderPendingDrop, [Target]) -> Bool)?
    let clearDropIndicator: () -> Void
    let setWorkspaceDropTargetCollectionActive: (Bool) -> Void
    let hasLiveWorkspaceDrag: () -> Bool
    let pointOffset: CGSize

    init(
        targetBridge: TargetBridge,
        isValidDrag: @escaping () -> Bool,
        updateDrag: @escaping (CGPoint, [Target]) -> Bool,
        performDrop: @escaping (CGPoint, [Target]) -> Bool,
        performPendingDrop: ((SidebarWorkspaceReorderPendingDrop, [Target]) -> Bool)? = nil,
        clearDropIndicator: @escaping () -> Void,
        setWorkspaceDropTargetCollectionActive: @escaping (Bool) -> Void,
        hasLiveWorkspaceDrag: @escaping () -> Bool = { false },
        pointOffset: CGSize = .zero
    ) {
        self.targetBridge = targetBridge
        self.isValidDrag = isValidDrag
        self.updateDrag = updateDrag
        self.performDrop = performDrop
        self.performPendingDrop = performPendingDrop
        self.clearDropIndicator = clearDropIndicator
        self.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
        self.hasLiveWorkspaceDrag = hasLiveWorkspaceDrag
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
        view.performPendingDropAtPoint = performPendingDrop
        view.clearDropIndicator = clearDropIndicator
        view.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
        view.hasLiveWorkspaceDrag = hasLiveWorkspaceDrag
        view.pointOffset = pointOffset
    }

    static let pasteboardType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    static func shouldCaptureHitTest(
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLiveWorkspaceDrag: Bool = false
    ) -> Bool {
        guard WindowInputRoutingContext.allowsWorkspaceDropOverlayHitTesting(eventType: eventType) else {
            return false
        }
        // AppKit keeps the last drag's UTI on NSPasteboard(name: .drag). The
        // UTI is only a payload hint; a live coordinator session is required
        // before this overlay may claim pointer events.
        return hasLiveWorkspaceDrag
            && pasteboardTypes?.contains(pasteboardType) == true
    }
}
