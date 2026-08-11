import AppKit
import Bonsplit
import Foundation
import SwiftUI
import CmuxTerminal

final class PaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: PaneDropContext? {
        didSet {
            if dropContext != oldValue {
                clearActiveDropContainer()
            }
        }
    }
    private var activeZone: DropZone?
    private weak var activeDropContainer: (any PaneDropContainer)?
    private var activeDropContainerContext: PaneDropContext?
    private let dropRoutingRegistration = PaneDropRoutingRegistration()
    private let dropZoneOverlayView = NSView(frame: .zero)
    private lazy var dropZoneOverlayAnimator = PaneDropZoneOverlayAnimator(overlayView: dropZoneOverlayView)
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(Set([
            DragOverlayRoutingPolicy.bonsplitTabTransferType,
        ]).union(PasteboardFileURLReader.fileURLPasteboardTypes)))
        setupDropZoneOverlayView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            dropRoutingRegistration.clear()
            clearActiveDropContainer()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func layout() {
        super.layout()
        updateStandaloneDropZoneOverlay()
    }

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        let routingContext = WindowInputRoutingContext(eventType: eventType)
        guard routingContext.allowsPaneDropHitTesting else { return false }

        let hasTabTransfer = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let hasFileDropPayload = DragOverlayRoutingPolicy.hasFileDropPayload(pasteboardTypes)
        guard hasTabTransfer || hasFileDropPayload else { return false }

        if hasFileDropPayload, !hasTabTransfer {
            return routingContext.allowsFileDropPaneHitTesting
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        performHitTest(at: point, currentEvent: NSApp.currentEvent)
    }

    func performHitTest(at point: NSPoint, currentEvent: NSEvent?) -> NSView? {
        guard bounds.contains(point), dropContext != nil else { return nil }
        let eventType = currentEvent?.type
        guard WindowInputRoutingContext.allowsPaneDropHitTesting(eventType: eventType) else { return nil }
        if shouldDeferToPaneTabBar(at: point) {
            return nil
        }

        let pasteboardTypes = NSPasteboard(name: .drag).types
        let capture = Self.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        )
#if DEBUG
        logHitTestDecision(capture: capture, pasteboardTypes: pasteboardTypes, eventType: eventType)
#endif
        return capture ? self : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let dropContext {
            _ = resolveAndCacheDropContainer(for: dropContext)
        } else {
            clearActiveDropContainer()
        }
        let operation = updateDragState(sender, phase: "entered")
        dropRoutingRegistration.update(sender, operation: operation, targetView: self)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = updateDragState(sender, phase: "updated")
        dropRoutingRegistration.update(sender, operation: operation, targetView: self)
        return operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropRoutingRegistration.clear(sender)
        clearDragState(phase: "exited")
        clearActiveDropContainer()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        dropRoutingRegistration.clear(sender)
        clearDragState(phase: "ended")
        clearActiveDropContainer()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let dropContext else {
            clearActiveDropContainer()
            return false
        }
        return dropContainer(for: dropContext) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let modifierFlags = DragOverlayRoutingPolicy.currentModifierFlags
        defer {
            dropRoutingRegistration.clear(sender)
            clearDragState(phase: "perform.clear")
            clearActiveDropContainer()
        }

        guard let dropContext else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform allowed=0 reason=missingContext")
#endif
            return false
        }

        guard let container = dropContainer(for: dropContext) else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform allowed=0 reason=missingContainer")
#endif
            return false
        }

        let textDestinationKind = container.fileDropTextDestinationKind(
            in: dropContext.paneId,
            hasHostedTerminal: hostedView != nil
        )
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: modifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            let handled = container.performFileDropAsText(
                urls,
                context: dropContext,
                hostedView: hostedView,
                window: window
            )
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.performAsText panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "fileURLs=\(urls.count) pane=\(dropContext.paneId.id.uuidString.prefix(5)) " +
                "handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        if let transfer = PaneDragTransfer.decode(from: sender.draggingPasteboard),
           transfer.isFromCurrentProcess {
            guard container.canPerformPortalPaneDrop(transfer) else {
                return false
            }
            let zone = resolvedZone(
                for: sender,
                transfer: transfer,
                context: dropContext,
                container: container
            )
            let handled = container.performPortalPaneDrop(
                tabId: transfer.tabId,
                sourcePaneId: transfer.sourcePaneId,
                targetPane: dropContext.paneId,
                zone: zone
            )
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone) " +
                "pane=\(dropContext.paneId.id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        if let handled = container.performSimulatorFileDrop(
            urls: urls,
            panelId: dropContext.panelId
        ) {
            return handled
        }
        guard !urls.isEmpty else {
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=missingTransferAndFiles"
            )
#endif
            return false
        }

        let zone = fileDropZone(for: sender)
        let handled = container.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: urls,
            destination: PaneDropRouting.filePreviewDestination(
                targetPane: dropContext.paneId,
                zone: zone
            )
        ))
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "fileURLs=\(urls.count) zone=\(zone) pane=\(dropContext.paneId.id.uuidString.prefix(5)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
        return handled
    }

    /// Resolves the current drag operation using the owner fixed for this context.
    private func updateDragState(
        _ sender: any NSDraggingInfo,
        phase: String
    ) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        if shouldDeferToPaneTabBar(at: location) {
            clearDragState(phase: "\(phase).tabBar")
            return []
        }

        guard let dropContext else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        guard let container = dropContainer(for: dropContext) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let textDestinationKind = container.fileDropTextDestinationKind(
            in: dropContext.paneId,
            hasHostedTerminal: hostedView != nil
        )
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            clearDragState(phase: "\(phase).text")
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) fileDrop=1 textDestination=\(String(describing: textDestinationKind))"
            )
#endif
            return DragOverlayRoutingPolicy.textDropOperation(pasteboardTypes: sender.draggingPasteboard.types)
        }

        if let transfer = PaneDragTransfer.decode(from: sender.draggingPasteboard),
           transfer.isFromCurrentProcess {
            guard container.canPerformPortalPaneDrop(transfer) else {
                clearDragState(phase: "\(phase).reject")
                return []
            }
            let zone = resolvedZone(
                for: sender,
                transfer: transfer,
                context: dropContext,
                container: container
            )
            setActiveDropZone(zone)
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone)"
            )
#endif
            return .move
        }

        guard DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        if let operation = container.simulatorFileDropOperation(
            urls: urls,
            panelId: dropContext.panelId
        ) {
            clearDragState(phase: "\(phase).simulator")
            return operation
        }

        let zone = fileDropZone(for: sender)
        setActiveDropZone(zone)
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "fileURL=1 zone=\(zone)"
        )
#endif
        return .copy
    }

    /// Resolves pane ownership once when a drag enters this target.
    private func resolveAndCacheDropContainer(
        for context: PaneDropContext
    ) -> (any PaneDropContainer)? {
        let container = AppDelegate.shared?.paneDropContainer(for: context)
        activeDropContainer = container
        activeDropContainerContext = container == nil ? nil : context
        return container
    }

    /// Reuses the active owner, resolving it once when overlay forwarding starts late.
    private func dropContainer(
        for context: PaneDropContext
    ) -> (any PaneDropContainer)? {
        if activeDropContainerContext == context {
            return activeDropContainer
        }
        return resolveAndCacheDropContainer(for: context)
    }

    /// Releases cached ownership when the drag or target context ends.
    private func clearActiveDropContainer() {
        activeDropContainer = nil
        activeDropContainerContext = nil
    }

    static func simulatorFileDropOperation(
        urls: [URL],
        workspace: Workspace,
        panelId: UUID
    ) -> NSDragOperation? {
        guard let canHandle = workspace.canHandleSimulatorExternalFileDrop(
            urls: urls,
            panelId: panelId
        ) else {
            return nil
        }
        return canHandle ? .copy : []
    }

    private func fileDropZone(for sender: any NSDraggingInfo) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        return PaneDropRouting.zone(for: location, in: bounds.size)
    }

    private func resolvedZone(
        for sender: any NSDraggingInfo,
        transfer: PaneDragTransfer,
        context: PaneDropContext,
        container: any PaneDropContainer
    ) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        let proposedZone = PaneDropRouting.zone(for: location, in: bounds.size)
        return container.portalPaneDropZone(
            tabId: transfer.tabId,
            sourcePaneId: transfer.sourcePaneId,
            targetPane: context.paneId,
            proposedZone: proposedZone
        )
    }

    func shouldDeferToPaneTabBar(at point: NSPoint) -> Bool {
        let windowPoint = convert(point, to: nil)
        return BonsplitTabBarPassThrough
            .shouldPassThroughToPaneTabBar(windowPoint: windowPoint, below: self)
            .result
    }

    private func setupDropZoneOverlayView() {
        _ = dropZoneOverlayAnimator
        dropZoneOverlayView.autoresizingMask = []
        addSubview(dropZoneOverlayView)
    }

    private func setActiveDropZone(_ zone: DropZone?) {
        activeZone = zone
        if let hostedView {
            hostedView.setDropZoneOverlay(zone: zone)
            dropZoneOverlayView.isHidden = true
        } else {
            updateStandaloneDropZoneOverlay()
        }
    }

    private func updateStandaloneDropZoneOverlay() {
        guard hostedView == nil else {
            dropZoneOverlayAnimator.hideImmediately()
            return
        }
        dropZoneOverlayAnimator.setZone(
            activeZone,
            frameForZone: { [weak self] zone in
                guard let self else { return .zero }
                return PaneDropRouting.overlayFrame(for: zone, in: self.bounds)
            },
            ensureAttached: { [weak self] in
                guard let self else { return }
                if self.dropZoneOverlayView.superview !== self {
                    self.dropZoneOverlayView.removeFromSuperview()
                    self.addSubview(self.dropZoneOverlayView)
                }
            },
            bringToFront: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayView.superview === self,
                      self.subviews.last !== self.dropZoneOverlayView else { return }
                self.addSubview(self.dropZoneOverlayView, positioned: .above, relativeTo: nil)
            }
        )
    }

    private func clearDragState(phase: String) {
        guard activeZone != nil else { return }
        setActiveDropZone(nil)
#if DEBUG
        if let dropContext {
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) zone=none"
            )
        }
#endif
    }

#if DEBUG
    private func logHitTestDecision(
        capture: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) {
        let hasTransferType = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let hasFileDropPayload = DragOverlayRoutingPolicy.hasFileDropPayload(pasteboardTypes)
        guard hasTransferType || hasFileDropPayload || capture else { return }

        let signature = [
            capture ? "1" : "0",
            hasTransferType ? "1" : "0",
            hasFileDropPayload ? "1" : "0",
            String(describing: dropContext != nil),
            eventType.map { String($0.rawValue) } ?? "nil",
        ].joined(separator: "|")
        guard lastHitTestSignature != signature else { return }
        lastHitTestSignature = signature

        let types = pasteboardTypes?.map(\.rawValue).joined(separator: ",") ?? "-"
        cmuxDebugLog(
            "terminal.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) hasFileDrop=\(hasFileDropPayload ? 1 : 0) " +
            "context=\(dropContext != nil ? 1 : 0) " +
            "event=\(eventType.map { String($0.rawValue) } ?? "nil") types=\(types)"
        )
    }
#endif
}

typealias TerminalPaneDropTargetView = PaneDropTargetView

struct PaneDropTargetRepresentable: NSViewRepresentable {
    let dropContext: PaneDropContext?

    func makeNSView(context: Context) -> PaneDropTargetView {
        PaneDropTargetView(frame: .zero)
    }

    func updateNSView(_ nsView: PaneDropTargetView, context: Context) {
        nsView.dropContext = dropContext
        nsView.hostedView = nil
        if dropContext == nil {
            nsView.draggingExited(nil)
        }
    }
}
