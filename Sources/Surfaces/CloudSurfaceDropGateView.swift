import CmuxCloud
import AppKit
import Bonsplit
import UniformTypeIdentifiers

/// Intercepts only forbidden live surface drags, leaving ordinary hit testing alone.
@MainActor
final class CloudSurfaceDropGateView: NSView {
    weak var workspace: Workspace? {
        didSet {
            if oldValue !== workspace {
                feedback.clear()
                forwardedDestination = nil
                forwardedSequenceNumber = nil
            }
        }
    }
    var isActive = false {
        didSet {
            if !isActive {
                feedback.clear()
                forwardedDestination = nil
                forwardedSequenceNumber = nil
            }
        }
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
        guard let transfer = sourceResolver.transfer(from: pasteboard),
              let source = sourceResolver.source(for: transfer) else {
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
    private var forwardedSequenceNumber: Int?

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
        if destination !== forwardedDestination || sender.draggingSequenceNumber != forwardedSequenceNumber {
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = destination
            forwardedSequenceNumber = sender.draggingSequenceNumber
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
        let types = sender.draggingPasteboard.types ?? []
        guard !types.isEmpty else { return nil }
        let reference = root.superview ?? root
        var candidate = root.hitTest(reference.convert(sender.draggingLocation, from: nil))
        while let view = candidate {
            if view !== self, !view.isDescendant(of: self),
               Self.accepts(types, registeredTypes: view.registeredDraggedTypes) {
                return view
            }
            candidate = view.superview
        }
        return nil
    }

    /// AppKit matches registered types by conformance: SwiftUI's `onDrop`
    /// destinations register `public.data` rather than the custom type.
    private static func accepts(
        _ types: [NSPasteboard.PasteboardType],
        registeredTypes: [NSPasteboard.PasteboardType]
    ) -> Bool {
        types.contains { type in
            registeredTypes.contains { registered in
                if type == registered { return true }
                guard let dragged = UTType(type.rawValue), let accepted = UTType(registered.rawValue) else { return false }
                return dragged.conforms(to: accepted)
            }
        }
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
        forwardedSequenceNumber = nil
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        feedback.clear()
        // Optional in NSDraggingDestination; NSView itself does not implement it.
        if let destination = forwardedDestination,
           destination.responds(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
            destination.draggingEnded(sender)
        }
        forwardedDestination = nil
        forwardedSequenceNumber = nil
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        feedback.clear()
        forwardedDestination?.concludeDragOperation(sender)
        // Keep the reference: AppKit sends draggingEnded after conclude, and
        // the forwarded destination should get it too.
    }

    override func viewDidHide() {
        feedback.clear()
        forwardedDestination = nil
        forwardedSequenceNumber = nil
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            feedback.clear()
            forwardedDestination = nil
            forwardedSequenceNumber = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            feedback.clear()
            forwardedDestination = nil
            forwardedSequenceNumber = nil
        }
        super.viewWillMove(toSuperview: newSuperview)
    }
}
