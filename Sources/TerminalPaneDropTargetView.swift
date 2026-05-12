import AppKit
import Bonsplit
import Foundation
import SwiftUI

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

    deinit {}

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
            return FileDropTextDropController.performTerminalFileDrop(
                workspace: workspace,
                panelId: context.panelId,
                hostedView: hostedView,
                urls: urls,
                window: window
            )
        }

        guard let tabId = workspace.bonsplitController.selectedTab(inPane: context.paneId)?.id,
              let panelId = workspace.panelIdFromSurfaceId(tabId),
              let panel = workspace.panels[panelId] else {
            return false
        }
        if let terminalPanel = panel as? TerminalPanel {
            return FileDropTextDropController.performTerminalFileDrop(
                workspace: workspace,
                panelId: panelId,
                hostedView: terminalPanel.hostedView,
                urls: urls,
                window: window ?? terminalPanel.hostedView.window
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
            return nil
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
