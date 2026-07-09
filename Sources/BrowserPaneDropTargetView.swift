import AppKit
import Bonsplit
import Foundation
import WebKit

final class BrowserPaneDropTargetView: NSView {
    weak var slotView: WindowBrowserSlotView?
    var dropContext: BrowserPaneDropContext?
    private var activeZone: DropZone?
    weak var activeFileDropWebView: NSView?
    weak var preparedFileDropWebView: NSView?
    weak var performedFileDropWebView: NSView?
    var didRequestWebViewRestoreForDrag = false
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
        // Dock-hosted status is deliberately not consulted here: it cannot change
        // the capture result (a file-URL payload always yields a disposition, so
        // `shouldCaptureFileDrop` is true either way; without a file URL the
        // disposition is nil either way), and this runs from `hitTest` on
        // pointer-hover events, where an app-wide dock ownership sweep per event
        // is too expensive. Prepare/perform resolve the real dock-aware
        // disposition via `fileDropDisposition(_:)`.
        let disposition = BrowserPaneFileDropRouting.disposition(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            isDockHosted: false
        )
        let fileDropWantsPreview = disposition == .previewInWorkspace
        let shouldCaptureFileDrop = disposition != nil
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
        didRequestWebViewRestoreForDrag = false
        clearDragState(phase: "exited")
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let dropContext = activeDropContext() else {
#if DEBUG
            cmuxDebugLog("browser.paneDrop.prepare allowed=0 reason=missingContext")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        if fileDropDisposition(sender) == .forwardToPage {
            clearDragState(phase: "prepare.text")
            let webView = activeFileDropWebView ?? webViewForFileDropDelivery(at: location)
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
        // would then fail — the window file-drop overlay can hold this pane as its
        // target and call prepare before perform. Mirrors update/perform. (File
        // URLs over page content already returned via the hosted-WebView branch
        // above, so they are not rejected here.)
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
            didRequestWebViewRestoreForDrag = false
            clearDragState(phase: "perform.clear")
        }

        guard let dropContext = activeDropContext() else {
#if DEBUG
            cmuxDebugLog("browser.paneDrop.perform allowed=0 reason=missingContext")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if fileDropDisposition(sender) == .forwardToPage {
            let webView = preparedFileDropWebView ?? activeFileDropWebView ?? webViewForFileDropDelivery(at: location)
            if let webView = webView as? WKWebView {
                BrowserFileDropNavigationGuard.shared.recordDelivery(webView: webView, pasteboard: sender.draggingPasteboard)
            }
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

        // A Dock-hosted browser pane lives in a `DockSplitStore`, not the owning
        // workspace's Bonsplit tree. Route a live-surface tab drop to the Dock
        // (mirroring `PaneDropTargetView`) and reject anything else; a main-area
        // pane (`dockForPane` is nil) falls through to the workspace handlers
        // below. Unsupported payloads are rejected here rather than mis-routed
        // (and, for file previews, consumed) through the workspace handlers, which
        // target a pane the workspace does not own.
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

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        defer {
            activeFileDropWebView = nil
            preparedFileDropWebView = nil
            performedFileDropWebView = nil
            didRequestWebViewRestoreForDrag = false
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

        guard let dropContext = activeDropContext() else {
            exitActiveFileDropWebView(sender)
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )

        if fileDropDisposition(sender) == .forwardToPage {
            clearDragState(phase: "\(phase).text")
            return updateHostedWebViewDragState(sender, at: location)
        }

        exitActiveFileDropWebView(sender)

        // Dock-hosted browser pane: route a live-surface tab move into the Dock
        // and reject anything else (see performDragOperation). A main-area pane
        // (`dockForPane` is nil) falls through to the workspace handling below.
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

    private func activeDropContext() -> BrowserPaneDropContext? {
        dropContext
    }

    /// The live container tab a Dock drop would move. Registry-backed virtual
    /// drags and owners without Dock transfer routing return nil. Shared by
    /// prepare/update/perform so unsupported payloads do not fall through to the
    /// workspace handlers.
    private func liveSurfaceTransfer(for sender: any NSDraggingInfo, destinationDock: DockSplitStore) -> BrowserPaneDragTransfer? {
        guard let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess,
              !transfer.isFilePreview,
              AppDelegate.shared?.canMoveSurfaceIntoDock(sourceTabId: transfer.tabId, destinationDock: destinationDock) == true else {
            return nil
        }
        return transfer
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
