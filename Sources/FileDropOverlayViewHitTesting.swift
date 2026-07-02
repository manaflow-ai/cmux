import AppKit
import Bonsplit
import Foundation
import WebKit

extension FileDropOverlayView {
    /// The registered sidebar tree under the drag location, if any.
    /// `NSDraggingInfo.draggingLocation` is already in window coordinates.
    func sidebarTreeDropView(at windowPoint: NSPoint) -> NSView? {
        guard let window else { return nil }
        return SidebarFileDropDeferralRegistry.view(atWindowPoint: windowPoint, in: window)
    }

    /// Route the drag to a sidebar tree (Notes outline) when the cursor is
    /// over its region — the same forwarding shape as the WKWebView route.
    /// Returns nil when the drag is not over a registered sidebar tree.
    private func updateSidebarTreeDragTarget(_ sender: any NSDraggingInfo) -> NSDragOperation? {
        guard let sidebarView = sidebarTreeDropView(at: sender.draggingLocation) else {
            if let prev = activeSidebarDropView {
                prev.draggingExited(sender)
                activeSidebarDropView = nil
            }
            return nil
        }
        hintBadgeView.hide()
        if let prev = activeDragWebView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }
        if let prev = activePaneDropTarget {
            prev.fileDropDraggingExited(sender)
            activePaneDropTarget = nil
        }
        if activeSidebarDropView !== sidebarView {
            activeSidebarDropView?.draggingExited(sender)
            activeSidebarDropView = sidebarView
            #if DEBUG
            cmuxDebugLog("overlay.fileDrop.sidebarRoute entered view=\(type(of: sidebarView))")
            #endif
            return sidebarView.draggingEntered(sender)
        }
        return sidebarView.draggingUpdated(sender)
    }

    func updateDragTarget(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let loc = sender.draggingLocation
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        if let sidebarOperation = updateSidebarTreeDragTarget(sender) {
            return sidebarOperation
        }
        updateHintBadge(sender: sender, pasteboardTypes: types)

        if shouldRouteFileDropToTextDestination(sender) {
            let paneDropTarget = paneDropTargetForTextDrop(at: loc)
            if let prev = activePaneDropTarget {
                if fileDropPaneTargetsAreIdentical(prev, paneDropTarget) {
                    return prev.fileDropDraggingUpdated(sender)
                }
                prev.fileDropDraggingExited(sender)
                activePaneDropTarget = nil
            }
            if let paneDropTarget {
                if let prev = activeDragWebView {
                    prev.draggingExited(sender)
                    activeDragWebView = nil
                }
                activePaneDropTarget = paneDropTarget
                return paneDropTarget.fileDropDraggingEntered(sender)
            }
            if let webView = webViewUnderPoint(loc) {
                if activeDragWebView !== webView {
                    if let prev = activeDragWebView {
                        prev.draggingExited(sender)
                    }
                    activeDragWebView = webView
                    return webView.draggingEntered(sender)
                }
                return webView.draggingUpdated(sender)
            }
            if let prev = activeDragWebView {
                prev.draggingExited(sender)
                activeDragWebView = nil
            }
            return textDropDestinationKindUnderPoint(loc) == nil
                ? []
                : DragOverlayRoutingPolicy.textDropOperation(pasteboardTypes: types)
        }

        let paneDropTarget = shouldCapture ? paneDropTargetUnderPoint(loc) : nil
        let webView = shouldCapture && paneDropTarget == nil ? webViewUnderPoint(loc) : nil

        if let prev = activeDragWebView {
            if prev !== webView {
                prev.draggingExited(sender)
                activeDragWebView = nil
            }
        }
        if let prev = activePaneDropTarget,
           !fileDropPaneTargetsAreIdentical(prev, paneDropTarget) {
            prev.fileDropDraggingExited(sender)
            activePaneDropTarget = nil
        }

        if let paneDropTarget {
            if !fileDropPaneTargetsAreIdentical(activePaneDropTarget, paneDropTarget) {
                activePaneDropTarget = paneDropTarget
                return paneDropTarget.fileDropDraggingEntered(sender)
            }
            return paneDropTarget.fileDropDraggingUpdated(sender)
        }

        if let webView {
            if activeDragWebView !== webView {
                activeDragWebView = webView
                return webView.draggingEntered(sender)
            }
            return webView.draggingUpdated(sender)
        }

        let hasPaneTarget = terminalUnderPoint(loc) != nil
#if DEBUG
        logDragRouteDecision(
            phase: phase,
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasPaneTarget: hasPaneTarget
        )
#endif
        guard shouldCapture, hasPaneTarget else { return [] }
        return .copy
    }

    private func fileDropPaneTargetsAreIdentical(
        _ lhs: (any FileDropPaneTarget)?,
        _ rhs: (any FileDropPaneTarget)?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    func shouldRouteFileDropToTextDestination(_ sender: any NSDraggingInfo) -> Bool {
        let canDropAsText = textDropDestinationKindUnderPoint(sender.draggingLocation) != nil
        return DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: canDropAsText
        )
    }

    private func updateHintBadge(
        sender: any NSDraggingInfo,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) {
        let kind = textDropDestinationKindUnderPoint(sender.draggingLocation)
        guard let alternateBehavior = DragOverlayRoutingPolicy.alternateFileDropBehaviorForShiftHint(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: kind != nil
        ), let kind,
           let hintText = kind.hintText(for: alternateBehavior),
           let targetBounds = hintBadgeTargetBoundsUnderPoint(sender.draggingLocation) else {
            hintBadgeView.hide()
            return
        }
        hintBadgeView.show(text: hintText, centeredIn: targetBounds, clippedTo: bounds)
    }

    func textDropDestinationKindUnderPoint(_ windowPoint: NSPoint) -> FileDropTextDestinationKind? {
        if editableTextViewUnderPoint(windowPoint) != nil {
            return .editor
        }
        if webViewUnderPoint(windowPoint) != nil {
            return .editor
        }
        if terminalUnderPoint(windowPoint) != nil {
            return .terminal
        }
        return nil
    }

    private func hintBadgeTargetBoundsUnderPoint(_ windowPoint: NSPoint) -> CGRect? {
        if let paneDropTarget = paneDropTargetUnderPoint(windowPoint),
           let targetView = paneDropTarget as? NSView {
            return convert(targetView.bounds, from: targetView)
        }
        if let terminal = terminalUnderPoint(windowPoint) {
            return convert(terminal.bounds, from: terminal)
        }
        if let webView = webViewUnderPoint(windowPoint) {
            return convert(webView.bounds, from: webView)
        }
        if let textView = editableTextViewUnderPoint(windowPoint) {
            return convert(textView.visibleRect, from: textView)
        }
        return nil
    }

    func performFileDropAsText(_ sender: any NSDraggingInfo) -> Bool {
        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        let windowPoint = sender.draggingLocation
        if let textView = editableTextViewUnderPoint(windowPoint) {
            let text = TerminalImageTransferPlanner.insertedText(forFileURLs: urls)
            guard !text.isEmpty else { return false }
            return insert(text, into: textView)
        }
        if let terminal = terminalUnderPoint(windowPoint) {
            return insert(urls, into: terminal)
        }
        return false
    }

    private func viewUnderPoint(_ windowPoint: NSPoint) -> NSView? {
        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        return contentView.hitTest(point)
    }

    private func editableTextViewUnderPoint(_ windowPoint: NSPoint) -> NSTextView? {
        var current = viewUnderPoint(windowPoint)
        while let view = current {
            if let textView = view as? NSTextView, textView.isEditable {
                return textView
            }
            if let textField = view as? NSTextField,
               textField.isEditable,
               let editor = textField.currentEditor() as? NSTextView {
                return editor
            }
            current = view.superview
        }

        return nil
    }

    private func insert(_ text: String, into textView: NSTextView) -> Bool {
        guard textView.isEditable else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    private func insert(_ urls: [URL], into terminal: GhosttyNSView) -> Bool {
        FileDropTextDropController.performTerminalFileDrop(
            terminal: terminal,
            urls: urls
        )
    }

    /// Hit-tests the window to find a WKWebView (browser panel) under the cursor.
    func webViewUnderPoint(_ windowPoint: NSPoint) -> WKWebView? {
        if let window,
           let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window) {
            return portalWebView
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let webView = view as? WKWebView { return webView }
            current = view.superview
        }
        return nil
    }

    private func debugTopHitViewForCurrentEvent() -> String {
        guard let window,
              let currentEvent = NSApp.currentEvent,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return "-" }

        let pointInTheme = themeFrame.convert(currentEvent.locationInWindow, from: nil)
        // Don't toggle isHidden here — it triggers setNeedsDisplay which can
        // exceed AppKit's display-pass limit during cursor-update display cycles.
        guard let hit = themeFrame.hitTest(pointInTheme) else { return "nil" }
        var chain: [String] = []
        var current: NSView? = hit
        var depth = 0
        while let view = current, depth < 6 {
            chain.append(debugHitViewDescriptor(view))
            current = view.superview
            depth += 1
        }
        return chain.joined(separator: "->")
    }

    private func debugHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let ptr = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let dragTypes = debugRegisteredDragTypes(view)
        return "\(className)@\(ptr){dragTypes=\(dragTypes)}"
    }

    private func debugRegisteredDragTypes(_ view: NSView) -> String {
        let types = view.registeredDraggedTypes
        guard !types.isEmpty else { return "-" }

        let interestingTypes = types.filter { type in
            let raw = type.rawValue
            return PasteboardFileURLReader.fileURLPasteboardTypes.contains(type)
                || raw == DragOverlayRoutingPolicy.bonsplitTabTransferType.rawValue
                || raw == DragOverlayRoutingPolicy.sidebarTabReorderType.rawValue
                || raw.contains("public.text")
                || raw.contains("public.url")
                || raw.contains("public.data")
        }
        let selected = interestingTypes.isEmpty ? Array(types.prefix(3)) : interestingTypes
        let rendered = selected.map(\.rawValue).joined(separator: ",")
        if selected.count < types.count {
            return "\(rendered),+\(types.count - selected.count)"
        }
        return rendered
    }

    private func hasRelevantDragTypes(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return DragOverlayRoutingPolicy.hasFileDropPayload(types)
            || types.contains(DragOverlayRoutingPolicy.bonsplitTabTransferType)
            || types.contains(DragOverlayRoutingPolicy.sidebarTabReorderType)
    }

    private func debugEventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "other(\(eventType.rawValue))"
        }
    }

#if DEBUG
    func logHitTestDecision(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        shouldCapture: Bool
    ) {
        let isDragEvent = eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
        guard shouldCapture || isDragEvent || hasRelevantDragTypes(pasteboardTypes) else { return }

        let signature = "\(shouldCapture ? 1 : 0)|\(debugEventName(eventType))|\(debugPasteboardTypes(pasteboardTypes))"
        guard lastHitTestLogSignature != signature else { return }
        lastHitTestLogSignature = signature
        cmuxDebugLog(
            "overlay.fileDrop.hitTest capture=\(shouldCapture ? 1 : 0) " +
            "event=\(debugEventName(eventType)) " +
            "topHit=\(debugTopHitViewForCurrentEvent()) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    func logDragRouteDecision(
        phase: String,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        shouldCapture: Bool,
        hasLocalDraggingSource: Bool,
        hasPaneTarget: Bool
    ) {
        guard shouldCapture || hasRelevantDragTypes(pasteboardTypes) else { return }
        let signature = [
            shouldCapture ? "1" : "0",
            hasLocalDraggingSource ? "1" : "0",
            hasPaneTarget ? "1" : "0",
            debugPasteboardTypes(pasteboardTypes)
        ].joined(separator: "|")
        guard lastDragRouteLogSignatureByPhase[phase] != signature else { return }
        lastDragRouteLogSignatureByPhase[phase] = signature
        cmuxDebugLog(
            "overlay.fileDrop.\(phase) capture=\(shouldCapture ? 1 : 0) " +
            "localSource=\(hasLocalDraggingSource ? 1 : 0) " +
            "hasPane=\(hasPaneTarget ? 1 : 0) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }
#endif
    /// Hit-tests the window to find the GhosttyNSView under the cursor.
    func terminalUnderPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        if let window,
           let portalTerminal = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window) {
            return portalTerminal
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let terminal = view as? GhosttyNSView { return terminal }
            current = view.superview
        }
        return nil
    }

    func shouldDeferFileDropOverlayToBonsplitTabBar(at point: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = convert(point, to: nil)
        return BonsplitTabBarHitRegionRegistry.containsWindowPoint(windowPoint, in: window)
    }

    func paneDropTargetUnderPoint(_ windowPoint: NSPoint) -> (any FileDropPaneTarget)? {
        if let paneTarget = inlinePaneDropTargetUnderPoint(windowPoint) {
            return paneTarget
        }
        guard let window else { return nil }
        if let terminalPaneTarget = TerminalWindowPortalRegistry.terminalPaneDropTargetAtWindowPoint(windowPoint, in: window) {
            return terminalPaneTarget
        }
        return BrowserWindowPortalRegistry.browserPaneDropTargetAtWindowPoint(windowPoint, in: window)
    }

    func paneDropTargetForTextDrop(at windowPoint: NSPoint) -> (any FileDropPaneTarget)? {
        if let textView = editableTextViewUnderPoint(windowPoint),
           !(textView is SavingTextView) {
            return nil
        }
        return paneDropTargetUnderPoint(windowPoint)
    }

    private func inlinePaneDropTargetUnderPoint(_ windowPoint: NSPoint) -> PaneDropTargetView? {
        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }

        let point = contentView.convert(windowPoint, from: nil)
        return paneDropTarget(in: contentView, at: point)
    }

    private func paneDropTarget(in view: NSView, at point: NSPoint) -> PaneDropTargetView? {
        for subview in view.subviews.reversed() {
            guard !subview.isHidden, subview.alphaValue > 0 else { continue }
            let pointInSubview = subview.convert(point, from: view)
            guard subview.bounds.contains(pointInSubview) else { continue }
            if let paneTarget = subview as? PaneDropTargetView {
                return paneTarget
            }
            if let nestedTarget = paneDropTarget(in: subview, at: pointInSubview) {
                return nestedTarget
            }
        }
        return view as? PaneDropTargetView
    }
}
