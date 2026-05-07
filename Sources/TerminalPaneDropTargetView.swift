import AppKit
import Bonsplit
import Foundation
import SwiftUI

struct PaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

typealias TerminalPaneDropContext = PaneDropContext

struct PaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    static func decode(from pasteboard: NSPasteboard) -> PaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data) -> PaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        return PaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId
        )
    }
}

typealias TerminalPaneDragTransfer = PaneDragTransfer

enum PaneDropRouting {
    private static func fullPaneSize(for size: CGSize, topChromeHeight: CGFloat) -> CGSize {
        CGSize(width: size.width, height: size.height + max(0, topChromeHeight))
    }

    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, fullPaneSize.width * edgeRatio)
        let verticalEdge = max(80, fullPaneSize.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > fullPaneSize.width - horizontalEdge {
            return .right
        } else if location.y > fullPaneSize.height - verticalEdge {
            return .top
        } else if location.y < verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    static func filePreviewDestination(
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        switch zone {
        case .center:
            return .insert(targetPane: paneId, targetIndex: nil)
        case .left:
            return .split(targetPane: paneId, orientation: .horizontal, insertFirst: true)
        case .right:
            return .split(targetPane: paneId, orientation: .horizontal, insertFirst: false)
        case .top:
            return .split(targetPane: paneId, orientation: .vertical, insertFirst: true)
        case .bottom:
            return .split(targetPane: paneId, orientation: .vertical, insertFirst: false)
        }
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        overlayFrame(
            for: zone,
            in: CGRect(origin: .zero, size: fullPaneSize(for: size, topChromeHeight: topChromeHeight))
        )
    }

    static func overlayFrame(for zone: DropZone, in bounds: CGRect) -> CGRect {
        let padding: CGFloat = 4
        let midX = bounds.midX
        let midY = bounds.midY

        switch zone {
        case .center:
            return bounds.insetBy(dx: padding, dy: padding)
        case .left:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, midX - bounds.minX - padding), height: max(0, bounds.height - padding * 2))
        case .right:
            return CGRect(x: midX, y: bounds.minY + padding, width: max(0, bounds.maxX - midX - padding), height: max(0, bounds.height - padding * 2))
        case .top:
            return CGRect(x: bounds.minX + padding, y: midY, width: max(0, bounds.width - padding * 2), height: max(0, bounds.maxY - midY - padding))
        case .bottom:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, bounds.width - padding * 2), height: max(0, midY - bounds.minY - padding))
        }
    }
}

typealias TerminalPaneDropRouting = PaneDropRouting

final class PaneDropZoneOverlayAnimator {
    private let overlayView: NSView
    private var displayedZone: DropZone?
    private var animationGeneration: UInt64 = 0

    init(overlayView: NSView) {
        self.overlayView = overlayView
        Self.applyStyle(to: overlayView)
    }

    static func applyStyle(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        view.layer?.borderColor = cmuxAccentNSColor().cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 8
        view.isHidden = true
    }

    func hideImmediately() {
        displayedZone = nil
        animationGeneration &+= 1
        overlayView.layer?.removeAllAnimations()
        overlayView.isHidden = true
        overlayView.alphaValue = 1
    }

    func setZone(
        _ zone: DropZone?,
        frameForZone: (DropZone) -> CGRect,
        ensureAttached: () -> Void,
        bringToFront: () -> Void
    ) {
        let previousZone = displayedZone
        displayedZone = zone

        guard let zone else {
            guard !overlayView.isHidden else { return }
            animationGeneration &+= 1
            let generation = animationGeneration
            overlayView.layer?.removeAllAnimations()
            bringToFront()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.animationGeneration == generation else { return }
                guard self.displayedZone == nil else { return }
                self.overlayView.isHidden = true
                self.overlayView.alphaValue = 1
            }
            return
        }

        ensureAttached()
        let targetFrame = frameForZone(zone)
        let needsFrameUpdate = !Self.rectApproximatelyEqual(overlayView.frame, targetFrame)
        let zoneChanged = previousZone != zone

        if !overlayView.isHidden && !needsFrameUpdate && !zoneChanged {
            bringToFront()
            return
        }

        animationGeneration &+= 1
        overlayView.layer?.removeAllAnimations()

        if overlayView.isHidden {
            applyFrame(targetFrame)
            overlayView.alphaValue = 0
            overlayView.isHidden = false
            bringToFront()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlayView.animator().alphaValue = 1
            }
            return
        }

        bringToFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if needsFrameUpdate {
                overlayView.animator().frame = targetFrame
            }
            if overlayView.alphaValue < 1 {
                overlayView.animator().alphaValue = 1
            }
        }
    }

    private func applyFrame(_ frame: CGRect) {
        guard !Self.rectApproximatelyEqual(overlayView.frame, frame) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayView.frame = frame
        CATransaction.commit()
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}

final class PaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: PaneDropContext?
    private var activeZone: DropZone?
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

    override func layout() {
        super.layout()
        updateStandaloneDropZoneOverlay()
    }

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        let hasTabTransfer = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let hasFileDropPayload = DragOverlayRoutingPolicy.hasFileDropPayload(pasteboardTypes)
        guard hasTabTransfer || hasFileDropPayload else { return false }
        guard let eventType else { return false }

        if hasFileDropPayload, !hasTabTransfer {
            switch eventType {
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                 .leftMouseUp, .rightMouseUp, .otherMouseUp:
                return true
            default:
                return false
            }
        }

        switch eventType {
        case .cursorUpdate,
             .mouseEntered,
             .mouseExited,
             .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .leftMouseUp,
             .rightMouseUp,
             .otherMouseUp,
             .appKitDefined,
             .applicationDefined,
             .systemDefined,
             .periodic:
            return true
        default:
            return false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), dropContext != nil else { return nil }
        if shouldDeferToPaneTabBar(at: point) {
            return nil
        }

        let pasteboardTypes = NSPasteboard(name: .drag).types
        let eventType = NSApp.currentEvent?.type
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
        updateDragState(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDragState(phase: "exited")
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            clearDragState(phase: "perform.clear")
        }

        guard let dropContext,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform allowed=0 reason=missingContext")
#endif
            return false
        }

        let textDestinationKind = fileDropTextDestinationKind(context: dropContext, workspace: workspace)
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            let handled = handleFileDropAsText(urls, context: dropContext, workspace: workspace)
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
            let zone = resolvedZone(for: sender, transfer: transfer, context: dropContext, workspace: workspace)
            let handled = workspace.performPortalPaneDrop(
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
        let handled = workspace.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
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

    private func updateDragState(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        if shouldDeferToPaneTabBar(at: location) {
            clearDragState(phase: "\(phase).tabBar")
            return []
        }

        guard let dropContext,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let textDestinationKind = fileDropTextDestinationKind(context: dropContext, workspace: workspace)
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
            let zone = resolvedZone(
                for: sender,
                transfer: transfer,
                context: dropContext,
                workspace: workspace
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

    private func fileDropZone(for sender: any NSDraggingInfo) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        return PaneDropRouting.zone(for: location, in: bounds.size)
    }

    private func resolvedZone(
        for sender: any NSDraggingInfo,
        transfer: PaneDragTransfer,
        context: PaneDropContext,
        workspace: Workspace
    ) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        let proposedZone = PaneDropRouting.zone(for: location, in: bounds.size)
        return workspace.portalPaneDropZone(
            tabId: transfer.tabId,
            sourcePaneId: transfer.sourcePaneId,
            targetPane: context.paneId,
            proposedZone: proposedZone
        )
    }

    private func handleFileDropAsText(
        _ urls: [URL],
        context: PaneDropContext,
        workspace: Workspace
    ) -> Bool {
        if let hostedView {
            return FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: context.panelId,
                focusIntent: .terminal(.surface),
                window: window,
                insert: {
                    hostedView.handleDroppedURLsAsText(urls)
                }
            )
        }

        guard let tabId = workspace.bonsplitController.selectedTab(inPane: context.paneId)?.id,
              let panelId = workspace.panelIdFromSurfaceId(tabId),
              let panel = workspace.panels[panelId] else {
            return false
        }
        if let terminalPanel = panel as? TerminalPanel {
            return FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: panelId,
                focusIntent: .terminal(.surface),
                window: window ?? terminalPanel.hostedView.window,
                insert: {
                    terminalPanel.hostedView.handleDroppedURLsAsText(urls)
                }
            )
        }
        if let filePreviewPanel = panel as? FilePreviewPanel {
            return FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: panelId,
                focusIntent: .filePreview(.textEditor),
                window: window,
                insert: {
                    filePreviewPanel.handleDroppedFileURLsAsText(urls)
                }
            )
        }
        return false
    }

    private func fileDropTextDestinationKind(
        context: PaneDropContext,
        workspace: Workspace
    ) -> FileDropTextDestinationKind? {
        if hostedView != nil {
            return .terminal
        }

        guard let tabId = workspace.bonsplitController.selectedTab(inPane: context.paneId)?.id,
              let panelId = workspace.panelIdFromSurfaceId(tabId),
              let panel = workspace.panels[panelId] else {
            return nil
        }

        switch panel.panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .editor
        case .filePreview:
            guard let filePreviewPanel = panel as? FilePreviewPanel,
                  filePreviewPanel.previewMode == .text else {
                return nil
            }
            return .editor
        case .markdown:
            return nil
        }
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
