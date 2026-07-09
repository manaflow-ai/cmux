import AppKit
import Bonsplit
import Foundation
import WebKit

@MainActor
protocol FileDropPaneTarget: AnyObject {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?)
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?)
}

extension PaneDropTargetView: FileDropPaneTarget {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { prepareForDragOperation(sender) }
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool { performDragOperation(sender) }
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?) { concludeDragOperation(sender) }
}

extension BrowserPaneDropTargetView: FileDropPaneTarget {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { prepareForDragOperation(sender) }
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool { performDragOperation(sender) }
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?) { concludeDragOperation(sender) }
}

/// Transparent NSView installed on the window's theme frame (above the NSHostingView) to
/// handle file/URL drags from Finder. Nested NSHostingController layers (created by bonsplit's
/// SinglePaneWrapper) prevent AppKit's NSDraggingDestination routing from reaching deeply
/// embedded terminal views. This overlay sits above the entire content view hierarchy and
/// intercepts file drags, forwarding drops to the GhosttyNSView under the cursor.
///
/// Mouse events are forwarded to the views below via a hide-send-unhide pattern so clicks,
/// scrolls, and other interactions pass through normally.
final class FileDropOverlayView: NSView {
    /// Fallback handler when no terminal is found under the drop point.
    var onDrop: (([URL]) -> Bool)?
    private var isForwardingMouseEvent = false
    private weak var forwardedMouseDragTarget: NSView?
    private var forwardedMouseDragButton: ForwardedMouseDragButton?
    /// The WKWebView currently receiving forwarded drag events, so we can
    /// synthesize draggingExited/draggingEntered as the cursor moves.
    weak var activeDragWebView: WKWebView?
    /// The WKWebView that accepted prepareForDragOperation so conclude can be
    /// delivered to the same browser target after the drop completes.
    weak var preparedDragWebView: WKWebView?
    /// Pane drop target currently receiving delegated file drag events.
    weak var activePaneDropTarget: (any FileDropPaneTarget)?
    /// Pane drop target that accepted prepareForDragOperation.
    weak var preparedPaneDropTarget: (any FileDropPaneTarget)?
    var didPerformDragAsText = false
    weak var performedTextDragWebView: WKWebView?
    weak var performedTextPaneDropTarget: (any FileDropPaneTarget)?
    let hintBadgeView = FileDropHintBadgeView(frame: .zero)
    var lastHitTestLogSignature: String?
    var lastDragRouteLogSignatureByPhase: [String: String] = [:]

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(PasteboardFileURLReader.fileURLPasteboardTypes))
        addSubview(hintBadgeView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private enum ForwardedMouseDragButton: Equatable {
        case left
        case right
        case other(Int)
    }

    private func dragButton(for event: NSEvent) -> ForwardedMouseDragButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return .other(Int(event.buttonNumber))
        default:
            return nil
        }
    }

    private func shouldTrackForwardedMouseDragStart(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func shouldTrackForwardedMouseDragEnd(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    // MARK: Hit-testing — participation is routed by DragOverlayRoutingPolicy so
    // file-drop, bonsplit tab drags, and sidebar tab reorder drags cannot conflict.

    override func hitTest(_ point: NSPoint) -> NSView? {
        let eventType = NSApp.currentEvent?.type
        guard WindowInputRoutingContext.allowsFileDropOverlayHitTesting(eventType: eventType) else {
#if DEBUG
            logHitTestDecision(
                pasteboardTypes: nil,
                eventType: eventType,
                shouldCapture: false
            )
#endif
            return nil
        }

        let pb = NSPasteboard(name: .drag)
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
            pasteboardTypes: pb.types,
            eventType: eventType
        )
#if DEBUG
        logHitTestDecision(
            pasteboardTypes: pb.types,
            eventType: eventType,
            shouldCapture: shouldCapture
        )
#endif
        guard shouldCapture else { return nil }
        if shouldDeferFileDropOverlayToBonsplitTabBar(at: point) {
            return nil
        }

        return super.hitTest(point)
    }

    // MARK: Mouse forwarding — safety net for the rare case where stale drag pasteboard
    // data causes hitTest to return self when no drag is actually active.
    // We hit-test contentView directly and dispatch to the target rather than using
    // window.sendEvent(), which caches the mouse target and causes infinite recursion.

    private func forwardEvent(_ event: NSEvent) {
        guard !isForwardingMouseEvent else { return }
        guard let window, let contentView = window.contentView else { return }
        let eventButton = dragButton(for: event)

        isForwardingMouseEvent = true
        isHidden = true
        defer {
            isHidden = false
            isForwardingMouseEvent = false
        }

        let target: NSView?
        if let eventButton,
           forwardedMouseDragButton == eventButton,
           let activeTarget = forwardedMouseDragTarget,
           activeTarget.window != nil {
            // Preserve normal AppKit mouse-delivery semantics: once a drag starts,
            // keep routing dragged/up events to the original mouseDown target.
            target = activeTarget
        } else {
            let point = contentView.convert(event.locationInWindow, from: nil)
            target = contentView.hitTest(point)
        }

        guard let target, target !== self else {
            if shouldTrackForwardedMouseDragEnd(for: event.type),
               let eventButton,
               forwardedMouseDragButton == eventButton {
                forwardedMouseDragTarget = nil
                forwardedMouseDragButton = nil
            }
            return
        }

        if shouldTrackForwardedMouseDragStart(for: event.type), let eventButton {
            forwardedMouseDragTarget = target
            forwardedMouseDragButton = eventButton
        }

        switch event.type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseUp: target.mouseUp(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .rightMouseUp: target.rightMouseUp(with: event)
        case .rightMouseDragged: target.rightMouseDragged(with: event)
        case .otherMouseDown: target.otherMouseDown(with: event)
        case .otherMouseUp: target.otherMouseUp(with: event)
        case .otherMouseDragged: target.otherMouseDragged(with: event)
        case .scrollWheel: target.scrollWheel(with: event)
        default: break
        }

        if shouldTrackForwardedMouseDragEnd(for: event.type),
           let eventButton,
           forwardedMouseDragButton == eventButton {
            forwardedMouseDragTarget = nil
            forwardedMouseDragButton = nil
        }
    }

    override func mouseDown(with event: NSEvent) { forwardEvent(event) }
    override func mouseUp(with event: NSEvent) { forwardEvent(event) }
    override func mouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func scrollWheel(with event: NSEvent) { forwardEvent(event) }

    // MARK: NSDraggingDestination – accept file drops over terminal and browser views.
    //
    // AppKit sends draggingEntered once when the drag enters this overlay, then
    // draggingUpdated as the cursor moves within it. We track which WKWebView (if
    // any) is under the cursor and synthesize enter/exit calls so the browser's
    // HTML5 drag events (dragenter, dragleave, drop) fire correctly.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hintBadgeView.hide()
        preparedDragWebView = nil
        preparedPaneDropTarget = nil
        didPerformDragAsText = false
        performedTextDragWebView = nil
        performedTextPaneDropTarget = nil
        exitActiveDragTargets(sender)
    }

    private func exitActiveDragTargets(_ sender: (any NSDraggingInfo)?) {
        if let prev = activeDragWebView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }
        if let prev = activePaneDropTarget {
            prev.fileDropDraggingExited(sender)
            activePaneDropTarget = nil
        }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        if shouldRouteFileDropToTextDestination(sender) {
            let paneDropTarget = activePaneDropTarget ?? paneDropTargetForTextDrop(at: sender.draggingLocation)
            exitActiveDragTargets(sender)
            preparedDragWebView = nil
            if let paneDropTarget {
                let accepted = paneDropTarget.fileDropPrepareForDragOperation(sender)
                preparedPaneDropTarget = accepted ? paneDropTarget : nil
                return accepted
            }
            preparedPaneDropTarget = nil
            if let webView = webViewUnderPoint(sender.draggingLocation) {
                let accepted = webView.prepareForDragOperation(sender)
                preparedDragWebView = accepted ? webView : nil
                return accepted
            }
            return textDropDestinationKindUnderPoint(sender.draggingLocation) != nil
        }
        let paneDropTarget = shouldCapture
            ? (activePaneDropTarget ?? paneDropTargetUnderPoint(sender.draggingLocation))
            : nil
        let terminal = paneDropTarget == nil ? terminalUnderPoint(sender.draggingLocation) : nil
        let webView = paneDropTarget == nil && terminal == nil ? webViewUnderPoint(sender.draggingLocation) : nil
        let hasPaneTarget = paneDropTarget != nil || terminal != nil || webView != nil
#if DEBUG
        logDragRouteDecision(
            phase: "prepare",
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasPaneTarget: hasPaneTarget
        )
#endif
        guard shouldCapture else {
            preparedDragWebView = nil
            preparedPaneDropTarget = nil
            exitActiveDragTargets(sender)
            return false
        }
        preparedDragWebView = nil
        if let paneDropTarget {
            let accepted = paneDropTarget.fileDropPrepareForDragOperation(sender)
            preparedPaneDropTarget = accepted ? paneDropTarget : nil
            return accepted
        }
        preparedPaneDropTarget = nil
        if let webView {
            let accepted = webView.prepareForDragOperation(sender)
            preparedDragWebView = accepted ? webView : nil
            return accepted
        }
        return hasPaneTarget
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        if shouldRouteFileDropToTextDestination(sender) {
            hintBadgeView.hide()
            didPerformDragAsText = false
            performedTextDragWebView = nil
            performedTextPaneDropTarget = nil
            let paneDropTarget = preparedPaneDropTarget ?? activePaneDropTarget ?? paneDropTargetForTextDrop(at: sender.draggingLocation)
            let webView = preparedDragWebView ?? activeDragWebView ?? webViewUnderPoint(sender.draggingLocation)
            exitActiveDragTargets(sender)
            preparedDragWebView = nil
            if let paneDropTarget {
                let handled = paneDropTarget.fileDropPerformDragOperation(sender)
                if handled {
                    didPerformDragAsText = true
                    performedTextPaneDropTarget = paneDropTarget
                } else {
                    preparedPaneDropTarget = nil
                }
                return handled
            }
            if let webView {
                BrowserFileDropNavigationGuard.shared.recordDelivery(webView: webView, pasteboard: sender.draggingPasteboard)
                let handled = webView.performDragOperation(sender)
                if !handled {
                    preparedDragWebView = nil
                    performedTextDragWebView = nil
                } else {
                    didPerformDragAsText = true
                    performedTextDragWebView = webView
                }
                return handled
            }
            let handled = performFileDropAsText(sender)
            didPerformDragAsText = handled
            return handled
        }
        didPerformDragAsText = false
        performedTextDragWebView = nil
        performedTextPaneDropTarget = nil
        let paneDropTarget = shouldCapture
            ? (preparedPaneDropTarget ?? activePaneDropTarget ?? paneDropTargetUnderPoint(sender.draggingLocation))
            : nil
        let terminal = paneDropTarget == nil ? terminalUnderPoint(sender.draggingLocation) : nil
        let webView = paneDropTarget == nil && terminal == nil
            ? (preparedDragWebView ?? activeDragWebView ?? webViewUnderPoint(sender.draggingLocation))
            : nil
        let hasPaneTarget = paneDropTarget != nil || terminal != nil || webView != nil
#if DEBUG
        logDragRouteDecision(
            phase: "perform",
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasPaneTarget: hasPaneTarget
        )
#endif
        guard shouldCapture else {
            preparedDragWebView = nil
            preparedPaneDropTarget = nil
            exitActiveDragTargets(sender)
            return false
        }
        preparedDragWebView = nil
        if let paneDropTarget {
            let handled = paneDropTarget.fileDropPerformDragOperation(sender)
            if !handled {
                preparedPaneDropTarget = nil
                activePaneDropTarget = nil
            }
            return handled
        }
        preparedPaneDropTarget = nil
        if let webView {
            BrowserFileDropNavigationGuard.shared.recordDelivery(webView: webView, pasteboard: sender.draggingPasteboard)
            let handled = webView.performDragOperation(sender)
            if !handled {
                preparedDragWebView = nil
                activeDragWebView = nil
            }
            return handled
        }
        activeDragWebView = nil
        guard let terminal else { return false }
        return terminal.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        defer {
            hintBadgeView.hide()
            preparedDragWebView = nil
            activeDragWebView = nil
            preparedPaneDropTarget = nil
            activePaneDropTarget = nil
            didPerformDragAsText = false
            performedTextDragWebView = nil
            performedTextPaneDropTarget = nil
        }
        guard let sender else { return }
        if didPerformDragAsText {
            if let paneDropTarget = performedTextPaneDropTarget ?? preparedPaneDropTarget ?? activePaneDropTarget {
                paneDropTarget.fileDropConcludeDragOperation(sender)
            } else if let webView = performedTextDragWebView {
                webView.concludeDragOperation(sender)
            }
            exitActiveDragTargets(sender)
            return
        }
        guard DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            hasLocalDraggingSource: sender.draggingSource != nil
        ) else {
            return
        }
        if let paneDropTarget = preparedPaneDropTarget ?? activePaneDropTarget {
            paneDropTarget.fileDropConcludeDragOperation(sender)
            return
        }
        if let webView = preparedDragWebView ?? activeDragWebView {
            webView.concludeDragOperation(sender)
        }
    }

}
