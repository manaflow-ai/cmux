import AppKit
import Bonsplit
import CmuxBrowser
import CmuxWorkspaces
import Foundation
import WebKit

final class BrowserPaneDropTargetView: NSView {
    weak var slotView: WindowBrowserSlotView?
    var dropContext: BrowserPaneDropContext?
    private var activeZone: DropZone?
    private weak var activeFileDropWebView: NSView?
    private weak var preparedFileDropWebView: NSView?
    private weak var performedFileDropWebView: NSView?
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

    @MainActor
    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard WindowInputRoutingContext.allowsPaneDropHitTesting(eventType: eventType) else { return false }

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

        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), dropContext != nil else { return nil }
        let eventType = NSApp.currentEvent?.type
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
        updateDragState(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        exitActiveFileDropWebView(sender)
        clearDragState(phase: "exited")
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let dropContext else {
#if DEBUG
            cmuxDebugLog("browser.paneDrop.prepare allowed=0 reason=missingContext")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        if shouldRouteFileDropToHostedWebView(sender, at: location) {
            clearDragState(phase: "prepare.text")
            let webView = activeFileDropWebView ?? slotView?.hostedWebViewForFileDrop(at: location)
            let accepted = webView?.prepareForDragOperation(sender) ?? false
            preparedFileDropWebView = accepted ? webView : nil
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.prepareAsWebView panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "accepted=\(accepted ? 1 : 0)"
            )
#endif
            return accepted
        }

        // A Dock-hosted browser pane only supports live-surface tab drops (routed
        // to the Dock in performDragOperation). Reject unsupported file-preview /
        // file-URL payloads here so prepare doesn't accept a drop that perform
        // would then fail; page-content file URLs already returned through the
        // hosted-WebView branch above.
        if let dock = AppDelegate.shared?.dockForPane(dropContext.paneId),
           liveSurfaceTransfer(for: sender, destinationDock: dock) == nil {
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.prepare.dock panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "allowed=0 reason=nonLiveDockDrop"
            )
#endif
            return false
        }

        return true
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
        let zone = PaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if shouldRouteFileDropToHostedWebView(sender, at: location) {
            let webView = preparedFileDropWebView ?? activeFileDropWebView ?? slotView?.hostedWebViewForFileDrop(at: location)
            let handled = webView?.performDragOperation(sender) ?? false
            if handled {
                performedFileDropWebView = webView
                focusBrowserPanelAfterSuccessfulFileDrop(context: dropContext)
            } else {
                preparedFileDropWebView = nil
                performedFileDropWebView = nil
            }
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.performAsWebView panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        // Dock-hosted browser panes live in a DockSplitStore, not the owning
        // workspace Bonsplit tree. Route live-surface tab drops to the Dock and
        // reject all other payloads so file previews are not consumed by the
        // workspace handlers for a pane the workspace does not own.
        if let dock = AppDelegate.shared?.dockForPane(dropContext.paneId) {
            guard let transfer = liveSurfaceTransfer(for: sender, destinationDock: dock) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.paneDrop.perform.dock panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                    "allowed=0 reason=nonLiveDockDrop"
                )
#endif
                return false
            }
            let dockZone = dock.portalPaneDropZone(
                tabId: transfer.tabId,
                sourcePaneId: transfer.sourcePaneId,
                targetPane: dropContext.paneId,
                proposedZone: zone
            )
            let handled = dock.performPortalPaneDrop(
                tabId: transfer.tabId,
                sourcePaneId: transfer.sourcePaneId,
                targetPane: dropContext.paneId,
                zone: dockZone
            )
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.perform.dock panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(dockZone) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        if let transfer = BrowserPaneDragTransfer.decode(
            from: sender.draggingPasteboard,
            filePreviewTransferType: DragOverlayRoutingPolicy.filePreviewTransferType,
            bonsplitTabTransferType: DragOverlayRoutingPolicy.bonsplitTabTransferType
        ),
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
                    destination: PaneDropRouting.filePreviewDestination(
                        targetPane: dropContext.paneId,
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

            guard let action = BrowserPaneDropAction.action(
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

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        defer {
            activeFileDropWebView = nil
            preparedFileDropWebView = nil
            performedFileDropWebView = nil
            clearDragState(phase: "conclude.clear")
        }
        guard let sender else { return }
        if let webView = performedFileDropWebView ?? preparedFileDropWebView ?? activeFileDropWebView {
            webView.concludeDragOperation(sender)
        }
    }

    private func updateDragState(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        if shouldDeferToPaneTabBar(at: location) {
            exitActiveFileDropWebView(sender)
            clearDragState(phase: "\(phase).tabBar")
            return []
        }

        guard let dropContext else {
            exitActiveFileDropWebView(sender)
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let zone = PaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if shouldRouteFileDropToHostedWebView(sender, at: location) {
            clearDragState(phase: "\(phase).text")
            return updateHostedWebViewDragState(sender, at: location)
        }

        exitActiveFileDropWebView(sender)

        // Dock-hosted browser panes route live-surface tab moves into the Dock
        // and reject everything else; main-area panes fall through below.
        if let dock = AppDelegate.shared?.dockForPane(dropContext.paneId) {
            guard let transfer = liveSurfaceTransfer(for: sender, destinationDock: dock) else {
                clearDragState(phase: "\(phase).reject")
                return []
            }
            let dockZone = dock.portalPaneDropZone(
                tabId: transfer.tabId,
                sourcePaneId: transfer.sourcePaneId,
                targetPane: dropContext.paneId,
                proposedZone: zone
            )
            activeZone = dockZone
            slotView?.setPortalDragDropZone(dockZone)
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.\(phase).dock panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(dockZone)"
            )
#endif
            return .move
        }

        if let transfer = BrowserPaneDragTransfer.decode(
            from: sender.draggingPasteboard,
            filePreviewTransferType: DragOverlayRoutingPolicy.filePreviewTransferType,
            bonsplitTabTransferType: DragOverlayRoutingPolicy.bonsplitTabTransferType
        ) {
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

    private func shouldRouteFileDropToHostedWebView(_ sender: any NSDraggingInfo, at location: NSPoint) -> Bool {
        guard DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types) else { return false }
        let canDropIntoHostedWebView = slotView?.hostedWebViewForFileDrop(at: location) != nil
        // Dock-hosted browser panes have no workspace-tree file-preview
        // destination, so page-content file drops should fall through to the
        // hosted WKWebView instead of being claimed and rejected by this pane.
        if canDropIntoHostedWebView,
           let dropContext,
           AppDelegate.shared?.dockForPane(dropContext.paneId) != nil {
            return true
        }
        return DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: canDropIntoHostedWebView
        )
    }

    private func activeDropContext() -> BrowserPaneDropContext? {
        dropContext
    }

    /// The live container tab a Dock drop can move; registry-backed virtual drags
    /// such as file previews own no live surface and must be rejected.
    private func liveSurfaceTransfer(for sender: any NSDraggingInfo, destinationDock: DockSplitStore) -> BrowserPaneDragTransfer? {
        guard let transfer = BrowserPaneDragTransfer.decode(
            from: sender.draggingPasteboard,
            filePreviewTransferType: DragOverlayRoutingPolicy.filePreviewTransferType,
            bonsplitTabTransferType: DragOverlayRoutingPolicy.bonsplitTabTransferType
        ),
              transfer.isFromCurrentProcess,
              !transfer.isFilePreview,
              AppDelegate.shared?.canMoveSurfaceIntoDock(sourceTabId: transfer.tabId, destinationDock: destinationDock) == true else {
            return nil
        }
        return transfer
    }

    private func updateHostedWebViewDragState(_ sender: any NSDraggingInfo, at location: NSPoint) -> NSDragOperation {
        guard let webView = slotView?.hostedWebViewForFileDrop(at: location) else {
            exitActiveFileDropWebView(sender)
            return []
        }
        if activeFileDropWebView !== webView {
            exitActiveFileDropWebView(sender)
            activeFileDropWebView = webView
            return webView.draggingEntered(sender)
        }
        return webView.draggingUpdated(sender)
    }

    private func exitActiveFileDropWebView(_ sender: (any NSDraggingInfo)?) {
        if let webView = activeFileDropWebView {
            webView.draggingExited(sender)
            activeFileDropWebView = nil
        }
    }

    private func focusBrowserPanelAfterSuccessfulFileDrop(context: BrowserPaneDropContext) {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: context.workspaceId) else { return }
        FileDropTextDropController.focusPanelAfterSuccessfulTextDrop(
            workspace: workspace,
            panelId: context.panelId,
            focusIntent: .browser(.webView),
            window: window ?? slotView?.window
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
