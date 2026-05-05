import AppKit
import Bonsplit
import Foundation

struct TerminalPaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

struct TerminalPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    static func decode(from pasteboard: NSPasteboard) -> TerminalPaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data) -> TerminalPaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        return TerminalPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId
        )
    }
}

enum TerminalPaneDropRouting {
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
}

final class TerminalPaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: TerminalPaneDropContext?
    private var activeZone: DropZone?
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes) else { return false }
        guard let eventType else { return false }

        switch eventType {
        case .cursorUpdate,
             .mouseEntered,
             .mouseExited,
             .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
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
              let transfer = TerminalPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform allowed=0 reason=missingTransfer")
#endif
            return false
        }

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

    private func updateDragState(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        if shouldDeferToPaneTabBar(at: location) {
            clearDragState(phase: "\(phase).tabBar")
            return []
        }

        guard let dropContext,
              let transfer = TerminalPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let zone = resolvedZone(
            for: sender,
            transfer: transfer,
            context: dropContext,
            workspace: workspace
        )
        activeZone = zone
        hostedView?.setDropZoneOverlay(zone: zone)
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone)"
        )
#endif
        return .move
    }

    private func resolvedZone(
        for sender: any NSDraggingInfo,
        transfer: TerminalPaneDragTransfer,
        context: TerminalPaneDropContext,
        workspace: Workspace
    ) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        let proposedZone = TerminalPaneDropRouting.zone(for: location, in: bounds.size)
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

    private func clearDragState(phase: String) {
        guard activeZone != nil else { return }
        activeZone = nil
        hostedView?.setDropZoneOverlay(zone: nil)
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
        guard hasTransferType || capture else { return }

        let signature = [
            capture ? "1" : "0",
            hasTransferType ? "1" : "0",
            String(describing: dropContext != nil),
            eventType.map { String($0.rawValue) } ?? "nil",
        ].joined(separator: "|")
        guard lastHitTestSignature != signature else { return }
        lastHitTestSignature = signature

        let types = pasteboardTypes?.map(\.rawValue).joined(separator: ",") ?? "-"
        cmuxDebugLog(
            "terminal.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) context=\(dropContext != nil ? 1 : 0) " +
            "event=\(eventType.map { String($0.rawValue) } ?? "nil") types=\(types)"
        )
    }
#endif
}
