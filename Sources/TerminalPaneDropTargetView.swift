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
    static func zone(for location: CGPoint, in size: CGSize) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > size.width - horizontalEdge {
            return .right
        } else if location.y > size.height - verticalEdge {
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

    static func overlayFrame(for zone: DropZone, in bounds: CGRect) -> CGRect {
        let midX = bounds.midX
        let midY = bounds.midY

        switch zone {
        case .center:
            return bounds.insetBy(dx: 10, dy: 10)
        case .left:
            return CGRect(x: bounds.minX + 8, y: bounds.minY + 8, width: max(0, midX - bounds.minX - 12), height: max(0, bounds.height - 16))
        case .right:
            return CGRect(x: midX + 4, y: bounds.minY + 8, width: max(0, bounds.maxX - midX - 12), height: max(0, bounds.height - 16))
        case .top:
            return CGRect(x: bounds.minX + 8, y: midY + 4, width: max(0, bounds.width - 16), height: max(0, bounds.maxY - midY - 12))
        case .bottom:
            return CGRect(x: bounds.minX + 8, y: bounds.minY + 8, width: max(0, bounds.width - 16), height: max(0, midY - bounds.minY - 12))
        }
    }
}

typealias TerminalPaneDropRouting = PaneDropRouting

final class PaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: PaneDropContext?
    private var activeZone: DropZone?
    private let dropZoneOverlayView = NSView(frame: .zero)
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            DragOverlayRoutingPolicy.bonsplitTabTransferType,
            .fileURL,
        ])
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
        let hasFileURL = DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes)
        guard hasTabTransfer || hasFileURL else { return false }
        guard let eventType else { return false }

        if hasFileURL, !hasTabTransfer {
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

        guard !DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard).isEmpty else {
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

    func shouldDeferToPaneTabBar(at point: NSPoint) -> Bool {
        let windowPoint = convert(point, to: nil)
        return BonsplitTabBarPassThrough
            .shouldPassThroughToPaneTabBar(windowPoint: windowPoint, below: self)
            .result
    }

    private func setupDropZoneOverlayView() {
        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
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
        guard hostedView == nil, let activeZone else {
            dropZoneOverlayView.isHidden = true
            return
        }
        dropZoneOverlayView.frame = PaneDropRouting.overlayFrame(for: activeZone, in: bounds)
        dropZoneOverlayView.isHidden = false
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
        let hasFileURL = DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes)
        guard hasTransferType || hasFileURL || capture else { return }

        let signature = [
            capture ? "1" : "0",
            hasTransferType ? "1" : "0",
            hasFileURL ? "1" : "0",
            String(describing: dropContext != nil),
            eventType.map { String($0.rawValue) } ?? "nil",
        ].joined(separator: "|")
        guard lastHitTestSignature != signature else { return }
        lastHitTestSignature = signature

        let types = pasteboardTypes?.map(\.rawValue).joined(separator: ",") ?? "-"
        cmuxDebugLog(
            "terminal.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) hasFileURL=\(hasFileURL ? 1 : 0) " +
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
