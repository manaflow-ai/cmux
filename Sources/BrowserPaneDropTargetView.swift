import AppKit
import Bonsplit
import Foundation
import WebKit

final class BrowserPaneDropTargetView: NSView {
    weak var slotView: WindowBrowserSlotView?
    var dropContext: BrowserPaneDropContext? {
        didSet {
            if dropContext != oldValue {
                transferDropRouter.clear()
            }
        }
    }
    private var activeZone: DropZone?
    private let transferDropRouter = PaneTransferDropRouter()
    private let dropRoutingRegistration = PaneDropRoutingRegistration()
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

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            dropRoutingRegistration.clear()
            transferDropRouter.clear()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    @MainActor
    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        hasLiveTabTransfer: Bool = false
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
            && hasLiveTabTransfer
        let hasBonsplitTransfer = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            && hasLiveTabTransfer
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

        let dragPasteboard = NSPasteboard(name: .drag)
        let pasteboardTypes = dragPasteboard.types
        let hasLiveTabTransfer = DragOverlayRoutingPolicy.hasLiveTabTransfer(
            in: dragPasteboard,
            resolver: AppDelegate.shared?.liveTabDragCapabilityResolver
        )
        let capture = Self.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType,
            hasLiveTabTransfer: hasLiveTabTransfer
        )
#if DEBUG
        logHitTestDecision(capture: capture, pasteboardTypes: pasteboardTypes, eventType: eventType)
#endif
        return capture ? self : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let dropContext {
            transferDropRouter.begin(context: dropContext)
        } else {
            transferDropRouter.clear()
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
        exitActiveFileDropWebView(sender)
        didRequestWebViewRestoreForDrag = false
        clearDragState(phase: "exited")
        transferDropRouter.clear()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropRoutingRegistration.clear(sender)
        exitActiveFileDropWebView(sender)
        didRequestWebViewRestoreForDrag = false
        clearDragState(phase: "ended")
        transferDropRouter.clear()
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

        let proposedZone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )
        switch transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: proposedZone
        ) {
        case .accepted:
            return true
        case .rejected:
            return false
        case .notTransfer:
            return DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types)
                && transferDropRouter.container(for: dropContext) != nil
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dropRoutingRegistration.clear(sender)
            didRequestWebViewRestoreForDrag = false
            clearDragState(phase: "perform.clear")
            transferDropRouter.clear()
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
            let handled = webView?.performDragOperation(sender) ?? false
            if handled {
                // Arm the fallback guard only for delivered drops; WebKit resolves the
                // fallback navigation asynchronously, so it still sees the record.
                if let webView = webView as? WKWebView {
                    BrowserFileDropNavigationGuard.shared.recordDelivery(webView: webView, pasteboard: sender.draggingPasteboard)
                }
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

        switch transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: zone
        ) {
        case .accepted(let plan):
            let handled = transferDropRouter.perform(
                plan,
                pasteboard: sender.draggingPasteboard
            )
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(plan.transfer.tabId.uuidString.prefix(5)) zone=\(plan.zone) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        case .rejected:
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=rejectedTransfer zone=\(zone)"
            )
#endif
            return false
        case .notTransfer:
            break
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty,
              let container = transferDropRouter.container(for: dropContext) else {
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) reason=missingTransferAndFiles"
            )
#endif
            return false
        }
        let handled = container.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: urls,
            destination: PaneDropRouting.destination(
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
            dropRoutingRegistration.clear(sender)
            activeFileDropWebView = nil
            preparedFileDropWebView = nil
            performedFileDropWebView = nil
            didRequestWebViewRestoreForDrag = false
            clearDragState(phase: "conclude.clear")
            transferDropRouter.clear()
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

        switch transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: zone
        ) {
        case .accepted(let plan):
            activeZone = plan.zone
            slotView?.setPortalDragDropZone(plan.zone)
#if DEBUG
            cmuxDebugLog(
                "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(plan.transfer.tabId.uuidString.prefix(5)) zone=\(plan.zone)"
            )
#endif
            return .move
        case .rejected:
            clearDragState(phase: "\(phase).reject")
            return []
        case .notTransfer:
            break
        }

        guard DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types),
              transferDropRouter.container(for: dropContext) != nil else {
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

    private func focusBrowserPanelAfterSuccessfulFileDrop(context: BrowserPaneDropContext) {
        guard let appDelegate = AppDelegate.shared,
              let panel = appDelegate.browserPanel(for: context.panelId),
              let target = appDelegate.browserActionTarget(for: panel) else {
            return
        }
        _ = BrowserActionDispatcher(appDelegate: appDelegate).perform(
            .focus,
            on: target
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
