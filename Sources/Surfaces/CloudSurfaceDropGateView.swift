import CmuxCloud
import AppKit
import Bonsplit

/// Intercepts only forbidden live surface drags, leaving ordinary hit testing alone.
@MainActor
final class CloudSurfaceDropGateView: NSView {
    weak var workspace: Workspace? {
        didSet { if oldValue !== workspace { feedback.clear() } }
    }
    var isActive = false {
        didSet { if !isActive { feedback.clear() } }
    }
    let feedback = SurfaceDropFeedback()
    private let sourceResolver: PaneTransferSourceResolver

    init(frame: NSRect, sourceResolver: PaneTransferSourceResolver = PaneTransferSourceResolver()) {
        self.sourceResolver = sourceResolver
        super.init(frame: frame)
        registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    func rejection(for pasteboard: NSPasteboard) -> SurfaceTransferRejection? {
        guard isActive, let workspace,
              DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboard.types) else { return nil }
        guard let transfer = sourceResolver.transfer(from: pasteboard) else {
            return workspace.surfaceOwnershipPolicy.rejection(for: nil)
        }
        // A tab already in this workspace is being reordered or split within it.
        if transfer.isFromCurrentProcess,
           workspace.panelIdFromSurfaceId(TabID(uuid: transfer.tabId)) != nil {
            return nil
        }
        guard let source = sourceResolver.source(for: transfer) else {
            return workspace.surfaceOwnershipPolicy.rejection(for: nil)
        }
        return workspace.surfaceDropRejection(transfer, source: source)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, bounds.contains(point),
              WindowInputRoutingContext(event: NSApp.currentEvent).allowsPaneDropHitTesting else { return nil }
        let pasteboard = NSPasteboard(name: .drag)
        guard sourceResolver.transfer(from: pasteboard) != nil else { return nil }
        return rejection(for: pasteboard) == nil ? nil : self
    }

    // MARK: - Drag destination

    /// AppKit picks a drag destination by registered type and geometry, not by
    /// `hitTest`, so this full-workspace overlay receives every tab drag over
    /// the workspace. It keeps the drags it rejects and hands the rest to the
    /// destination that would have received them without it (a tab strip, a
    /// pane drop target), which is the one pointer hit testing finds with this
    /// overlay passing through.
    private weak var forwardedDestination: NSView?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let rejection = rejection(for: sender.draggingPasteboard)
        feedback.update(rejection, over: self)
        let destination = rejection == nil ? destinationBeneath(sender) : nil
        if destination !== forwardedDestination {
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = destination
#if DEBUG
            dlog(
                "cloud.dropGate.forward rejected=\(rejection != nil ? 1 : 0) " +
                "to=\(destination.map { String(describing: type(of: $0)) } ?? "nil")"
            )
#endif
            return destination?.draggingEntered(sender) ?? []
        }
        return destination?.draggingUpdated(sender) ?? []
    }

    /// The nearest registered drag destination at the drag location with this
    /// overlay out of the way.
    private func destinationBeneath(_ sender: any NSDraggingInfo) -> NSView? {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return nil }
        let types = Set(sender.draggingPasteboard.types ?? [])
        guard !types.isEmpty else { return nil }
        let reference = root.superview ?? root
        var candidate = root.hitTest(reference.convert(sender.draggingLocation, from: nil))
        while let view = candidate {
            if view !== self, !view.isDescendant(of: self),
               !types.isDisjoint(with: view.registeredDraggedTypes) {
                return view
            }
            candidate = view.superview
        }
        return nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        feedback.clear()
        return forwardedDestination?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        feedback.clear()
        return forwardedDestination?.performDragOperation(sender) ?? false
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        feedback.clear()
        forwardedDestination?.draggingExited(sender)
        forwardedDestination = nil
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        feedback.clear()
        forwardedDestination?.draggingEnded(sender)
        forwardedDestination = nil
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        feedback.clear()
        forwardedDestination?.concludeDragOperation(sender)
        forwardedDestination = nil
    }

    override func viewDidHide() {
        feedback.clear()
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { feedback.clear() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { feedback.clear() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}
