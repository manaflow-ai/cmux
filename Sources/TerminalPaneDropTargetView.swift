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

final class PaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: PaneDropContext?
    private var activeZone: DropZone?
    private let dropZoneOverlayView = NSView(frame: .zero)
    private let dropHintView = NSVisualEffectView(frame: .zero)
    private let dropHintLabel = NSTextField(labelWithString: "")
    private var activeFileDropHint: PaneFileDropHint?
    private var activeShiftKeyHeld: Bool?
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
        setupDropHintView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateStandaloneDropZoneOverlay()
        updateDropHintFrame()
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

        let pasteboard = sender.draggingPasteboard
        let pasteboardTypes = pasteboard.types

        if DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes),
           let transfer = PaneDragTransfer.decode(from: pasteboard),
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

        let urls = DragOverlayRoutingPolicy.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=missingTransferAndFiles"
            )
#endif
            return false
        }

        let shiftKeyHeld = activeShiftKeyHeld ?? currentShiftKeyHeld()
        switch workspace.externalFileDropRouting(
            forPanelId: dropContext.panelId,
            shiftKeyHeld: shiftKeyHeld
        ) {
        case .agentPromptPaste:
            let handled = hostedView?.handleAgentDroppedURLs(urls) ?? false
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "fileURLs=\(urls.count) route=agentPromptPaste shift=\(shiftKeyHeld ? 1 : 0) " +
                "pane=\(dropContext.paneId.id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        case .terminalPaste:
            let handled = hostedView?.handleDroppedURLs(urls) ?? false
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "fileURLs=\(urls.count) route=terminalPaste shift=\(shiftKeyHeld ? 1 : 0) " +
                "pane=\(dropContext.paneId.id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        case .filePreview:
            break
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
            "fileURLs=\(urls.count) route=filePreview shift=\(shiftKeyHeld ? 1 : 0) zone=\(zone) " +
            "pane=\(dropContext.paneId.id.uuidString.prefix(5)) " +
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

        let pasteboard = sender.draggingPasteboard
        let pasteboardTypes = pasteboard.types

        if DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes),
           let transfer = PaneDragTransfer.decode(from: pasteboard),
           transfer.isFromCurrentProcess {
            let zone = resolvedZone(
                for: sender,
                transfer: transfer,
                context: dropContext,
                workspace: workspace
            )
            setActiveFileDropHint(nil)
            setActiveDropZone(zone)
            return .move
        }

        guard DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let shiftKeyHeld = currentShiftKeyHeld()
        activeShiftKeyHeld = shiftKeyHeld
        let routing = workspace.externalFileDropRouting(
            forPanelId: dropContext.panelId,
            shiftKeyHeld: shiftKeyHeld
        )
        setActiveFileDropHint(workspace.externalFileDropHint(
            forPanelId: dropContext.panelId,
            shiftKeyHeld: shiftKeyHeld
        ))

        switch routing {
        case .agentPromptPaste, .terminalPaste:
            setActiveDropZone(nil)
            return .copy
        case .filePreview:
            break
        }

        let zone = fileDropZone(for: sender)
        setActiveDropZone(zone)
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

    private func setupDropHintView() {
        dropHintView.material = .hudWindow
        dropHintView.blendingMode = .withinWindow
        dropHintView.state = .active
        dropHintView.wantsLayer = true
        dropHintView.layer?.cornerRadius = 8
        dropHintView.layer?.masksToBounds = true
        dropHintView.layer?.borderWidth = 1
        dropHintView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        dropHintView.isHidden = true
        dropHintView.autoresizingMask = []

        dropHintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dropHintLabel.textColor = .white
        dropHintLabel.alignment = .center
        dropHintLabel.lineBreakMode = .byWordWrapping
        dropHintLabel.maximumNumberOfLines = 2
        dropHintLabel.translatesAutoresizingMaskIntoConstraints = false
        dropHintView.addSubview(dropHintLabel)
        NSLayoutConstraint.activate([
            dropHintLabel.leadingAnchor.constraint(equalTo: dropHintView.leadingAnchor, constant: 14),
            dropHintLabel.trailingAnchor.constraint(equalTo: dropHintView.trailingAnchor, constant: -14),
            dropHintLabel.topAnchor.constraint(equalTo: dropHintView.topAnchor, constant: 8),
            dropHintLabel.bottomAnchor.constraint(equalTo: dropHintView.bottomAnchor, constant: -8),
        ])
        addSubview(dropHintView, positioned: .above, relativeTo: nil)
    }

    private func setActiveDropZone(_ zone: DropZone?) {
        guard activeZone != zone else { return }
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

    private func setActiveFileDropHint(_ hint: PaneFileDropHint?) {
        guard activeFileDropHint != hint else {
            updateDropHintFrame()
            return
        }

        activeFileDropHint = hint
        guard let hint else {
            dropHintView.isHidden = true
            return
        }

        dropHintLabel.stringValue = hint.displayText
        dropHintView.isHidden = false
        updateDropHintFrame()
    }

    private func updateDropHintFrame() {
        guard !dropHintView.isHidden else { return }

        let availableWidth = max(40, bounds.width - 24)
        let maxWidth = min(availableWidth, 520)
        dropHintLabel.preferredMaxLayoutWidth = max(0, maxWidth - 28)

        let labelSize = dropHintLabel.fittingSize
        let width = min(maxWidth, max(min(maxWidth, 220), labelSize.width + 28))
        let height = max(32, labelSize.height + 16)
        let x = bounds.minX + max(0, (bounds.width - width) / 2)
        let y = max(bounds.minY + 8, bounds.maxY - height - 12)
        dropHintView.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func clearDragState(phase: String) {
        activeShiftKeyHeld = nil
        guard activeZone != nil || activeFileDropHint != nil else { return }
        setActiveDropZone(nil)
        setActiveFileDropHint(nil)
#if DEBUG
        if let dropContext {
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) zone=none hint=none"
            )
        }
#endif
    }

    private func currentShiftKeyHeld() -> Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).intersection(.deviceIndependentFlagsMask).contains(.shift)
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
