import AppKit
import Bonsplit
import Foundation

final class BrowserPaneDropTargetView: NSView {
    weak var slotView: WindowBrowserSlotView?
    var dropContext: BrowserPaneDropContext?
    private var activeZone: DropZone?
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(Set([
            DragOverlayRoutingPolicy.filePreviewTransferType,
            DragOverlayRoutingPolicy.bonsplitTabTransferType,
        ]).union(PasteboardFileURLReader.fileURLPasteboardTypes)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {}

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        let hasFileURL = DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes)
        let fileDropBehavior = DragOverlayRoutingPolicy.resolvedFileDropBehavior(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: true
        )
        let fileDropWantsPreview = fileDropBehavior == .preview
        let shouldCaptureFileDrop = fileDropBehavior != nil
        let hasFilePreviewTransfer = DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboardTypes)
        let hasBonsplitTransfer = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let shouldCaptureFilePreviewTransfer = hasFilePreviewTransfer && (!hasFileURL || fileDropWantsPreview)
        let shouldCaptureBonsplitTransfer = hasBonsplitTransfer && !hasFilePreviewTransfer
        guard shouldCaptureBonsplitTransfer || shouldCaptureFilePreviewTransfer || shouldCaptureFileDrop else { return false }
        guard let eventType else { return false }

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

        guard let dropContext else {
#if DEBUG
            cmuxDebugLog("browser.paneDrop.perform allowed=0 reason=missingContext")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        let canDropAsText = slotView?.canDropFileURLsAsText(at: location) ?? false
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types),
           DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: sender.draggingPasteboard.types,
                modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
                canDropAsText: canDropAsText
           ) {
            let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
            guard let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
                return false
            }
            let handled = FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: dropContext.panelId,
                focusIntent: .browser(.webView),
                window: window ?? slotView?.window,
                insert: {
                    slotView?.handleDroppedFileURLsAsText(urls, at: location) ?? false
                }
            )
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.performAsText panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "fileURLs=\(urls.count) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        if let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
           transfer.isFromCurrentProcess {
            if transfer.isFilePreview {
                guard let entry = FilePreviewDragRegistry.shared.consume(id: transfer.tabId),
                      let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                        "reason=missingFilePreviewEntry tab=\(transfer.tabId.uuidString.prefix(5))"
                    )
#endif
                    return false
                }
                let handled = workspace.handleFilePreviewDrop(
                    entry: entry,
                    destination: BrowserPaneDropRouting.filePreviewDestination(
                        target: dropContext,
                        zone: zone
                    )
                )
#if DEBUG
                cmuxDebugLog(
                    "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                    "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone) filePreview=1 handled=\(handled ? 1 : 0)"
                )
#endif
                return handled
            }

            guard let action = BrowserPaneDropRouting.action(
                for: transfer,
                target: dropContext,
                zone: zone
            ) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                    "reason=noAction zone=\(zone)"
                )
#endif
                return false
            }

            switch action {
            case .noOp:
#if DEBUG
                cmuxDebugLog(
                    "browser.paneDrop.perform allowed=1 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                    "tab=\(transfer.tabId.uuidString.prefix(5)) action=noop"
                )
#endif
                return true
            case .move(let tabId, let workspaceId, let targetPane, let splitTarget):
                let moved = AppDelegate.shared?.moveBonsplitTab(
                    tabId: tabId,
                    toWorkspace: workspaceId,
                    targetPane: targetPane,
                    splitTarget: splitTarget.map { ($0.orientation, $0.insertFirst) },
                    focus: true,
                    focusWindow: true
                ) ?? false
#if DEBUG
                let splitLabel = splitTarget.map {
                    "\($0.orientation.rawValue):\($0.insertFirst ? 1 : 0)"
                } ?? "none"
                cmuxDebugLog(
                    "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                    "tab=\(tabId.uuidString.prefix(5)) zone=\(zone) pane=\(targetPane.id.uuidString.prefix(5)) " +
                    "split=\(splitLabel) moved=\(moved ? 1 : 0)"
                )
#endif
                return moved
            }
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dropContext.workspaceId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) reason=missingTransferAndFiles"
            )
#endif
            return false
        }
        let handled = workspace.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: urls,
            destination: PaneDropRouting.filePreviewDestination(
                targetPane: dropContext.paneId,
                zone: zone
            )
        ))
#if DEBUG
        cmuxDebugLog(
            "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "fileURLs=\(urls.count) zone=\(zone) handled=\(handled ? 1 : 0)"
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

        guard let dropContext else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let canDropAsText = slotView?.canDropFileURLsAsText(at: location) ?? false
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types),
           DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: sender.draggingPasteboard.types,
                modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
                canDropAsText: canDropAsText
           ) {
            clearDragState(phase: "\(phase).text")
            return DragOverlayRoutingPolicy.textDropOperation(pasteboardTypes: sender.draggingPasteboard.types)
        }

        if let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard) {
            guard transfer.isFromCurrentProcess,
                  (!transfer.isFilePreview || FilePreviewDragRegistry.shared.contains(id: transfer.tabId)) else {
                clearDragState(phase: "\(phase).reject")
                return []
            }
            activeZone = zone
            slotView?.setPortalDragDropZone(zone)
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone)"
            )
#endif
            return .move
        }

        guard DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }
        activeZone = zone
        slotView?.setPortalDragDropZone(zone)
#if DEBUG
        cmuxDebugLog(
            "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) fileURL=1 zone=\(zone)"
        )
#endif
        return .copy
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
        slotView?.setPortalDragDropZone(nil)
#if DEBUG
        if let dropContext {
            cmuxDebugLog(
                "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) zone=none"
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
            "browser.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) hasFileURL=\(hasFileURL ? 1 : 0) context=\(dropContext != nil ? 1 : 0) " +
            "event=\(eventType.map { String($0.rawValue) } ?? "nil") types=\(types)"
        )
    }
#endif
}
