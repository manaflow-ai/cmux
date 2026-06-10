import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif


final class WindowTerminalHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
    }

    private enum DividerCursorKind: Equatable {
        case vertical
        case horizontal

        var cursor: NSCursor {
            switch self {
            case .vertical: return .resizeLeftRight
            case .horizontal: return .resizeUpDown
            }
        }
    }

    override var isOpaque: Bool { false }
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
#if DEBUG
    private var lastDragRouteSignature: String?
#endif

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        clearActiveDividerCursor(restoreArrow: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearActiveDividerCursor(restoreArrow: false)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, let rootView = window.contentView else { return }
        var regions: [DividerRegion] = []
        Self.collectSplitDividerRegions(in: rootView, into: &regions)
        let expansion: CGFloat = 4
        for region in regions {
            var rectInHost = convert(region.rectInWindow, from: nil)
            rectInHost = rectInHost.insetBy(
                dx: region.isVertical ? -expansion : 0,
                dy: region.isVertical ? 0 : -expansion
            )
            let clipped = rectInHost.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            guard !cursorRectIntersectsChromePassThrough(clipped) else { continue }
            addCursorRect(clipped, cursor: region.isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        clearActiveDividerCursor(restoreArrow: true)
    }

    // PERF: hitTest is called on EVERY event including keyboard. Keep non-pointer
    // path minimal. Do not add work outside the input-routing guard.
    override func hitTest(_ point: NSPoint) -> NSView? {
        performHitTest(at: point, currentEvent: NSApp.currentEvent)
    }

    // Test seam: production calls go through `hitTest(_:)` which reads
    // `NSApp.currentEvent`; tests can call this directly with a synthetic
    // pointer event so the typing-latency guard doesn't gate them out.
    func performHitTest(at point: NSPoint, currentEvent: NSEvent?) -> NSView? {
        let routingContext = WindowInputRoutingContext(event: currentEvent)
        let eventType = routingContext.eventType

        if routingContext.allowsPortalPointerHitTesting {
            if shouldPassThroughToTitlebar(at: point) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            if shouldPassThroughToPaneTabBar(at: point, eventType: currentEvent?.type) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            if shouldPassThroughToSidebarResizer(at: point) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            // Compute divider hit once and reuse for both cursor update and pass-through.
            if let kind = splitDividerCursorKind(at: point) {
                activeDividerCursorKind = kind
                kind.cursor.set()
                TerminalWindowPortalRegistry.noteSplitDividerInteraction(
                    in: window,
                    event: currentEvent
                )
                return nil
            }

            clearActiveDividerCursor(restoreArrow: true)

            if routingContext.allowsTerminalPortalDragRouting {
                let dragPasteboardTypes = NSPasteboard(name: .drag).types
                let shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                    pasteboardTypes: dragPasteboardTypes,
                    eventType: eventType
                )
                if shouldPassThrough {
                    let hitView = super.hitTest(point)
                    if hitView is TerminalPaneDropTargetView {
#if DEBUG
                        logDragRouteDecision(
                            passThrough: false,
                            eventType: eventType,
                            pasteboardTypes: dragPasteboardTypes,
                            hitView: hitView
                        )
#endif
                        return hitView
                    }
#if DEBUG
                    logDragRouteDecision(
                        passThrough: true,
                        eventType: eventType,
                        pasteboardTypes: dragPasteboardTypes,
                        hitView: nil
                    )
#endif
                    return nil
                }
            }

            let hitView = super.hitTest(point)
#if DEBUG
            logDragRouteDecision(
                passThrough: false,
                eventType: currentEvent?.type,
                pasteboardTypes: nil,
                hitView: hitView
            )
#endif
            return hitView === self ? nil : hitView
        }

        // Non-pointer event: skip divider/drag routing, just do standard hit testing.
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }

    private func shouldPassThroughToTitlebar(at point: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = convert(point, to: nil)
        return windowPoint.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window)
    }

    private func shouldPassThroughToPaneTabBar(
        at point: NSPoint,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard let decision = BonsplitTabBarPassThrough.passThroughDecision(
            at: point,
            in: self,
            eventType: eventType
        ) else { return false }
        guard decision.result else { return false }
        if decision.registryHit {
            return true
        }
        return hostedTerminalHitView(at: point) == nil
    }

    private func hostedTerminalHitView(at point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView,
                  !hostedView.isHidden,
                  hostedView.alphaValue > 0,
                  hostedView.frame.contains(point) else { continue }

            return hostedView.hitTest(point) ?? hostedView
        }
        return nil
    }

    private func shouldPassThroughToChrome(at point: NSPoint, eventType: NSEvent.EventType?) -> Bool {
        shouldPassThroughToTitlebar(at: point)
            || shouldPassThroughToPaneTabBar(at: point, eventType: eventType)
    }

    private func cursorRectIntersectsChromePassThrough(_ rect: NSRect) -> Bool {
        let samples = [
            NSPoint(x: rect.midX, y: rect.midY),
            NSPoint(x: rect.midX, y: rect.maxY - 0.5),
            NSPoint(x: rect.midX, y: rect.minY + 0.5),
            NSPoint(x: rect.minX + 0.5, y: rect.midY),
            NSPoint(x: rect.maxX - 0.5, y: rect.midY),
        ]
        return samples.contains { shouldPassThroughToChrome(at: $0, eventType: .cursorUpdate) }
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        // The sidebar resizer handle is implemented in SwiftUI. When terminals
        // are portal-hosted, this AppKit host can otherwise sit above the handle
        // and steal hover/mouse events.
        let visibleHostedViews = subviews.compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        if shouldPassThroughToTrailingSidebarResizer(at: point, visibleHostedViews: visibleHostedViews) {
            return true
        }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleHostedViews.contains {
            $0.frame.minX <= Self.sidebarLeadingEdgeEpsilon
                && $0.frame.maxX > Self.minimumVisibleLeadingContentWidth
        }
        if hasLeadingContent {
            if cachedSidebarDividerX != nil {
                sidebarDividerMissCount += 1
                if sidebarDividerMissCount >= 2 {
                    cachedSidebarDividerX = nil
                    sidebarDividerMissCount = 0
                }
            }
            return false
        }

        // Ignore transient 0-origin hosts while layouts churn (e.g. workspace
        // creation/switching). They can temporarily report minX=0 and would
        // otherwise clear divider pass-through, causing hover flicker.
        let dividerCandidates = visibleHostedViews
            .map(\.frame.minX)
            .filter { $0 > Self.sidebarLeadingEdgeEpsilon }
        if let leftMostEdge = dividerCandidates.min() {
            cachedSidebarDividerX = leftMostEdge
            sidebarDividerMissCount = 0
        } else if cachedSidebarDividerX != nil {
            // Keep cache briefly for layout churn, but clear if we miss repeatedly
            // so stale divider positions don't steal pointer routing.
            sidebarDividerMissCount += 1
            if sidebarDividerMissCount >= 4 {
                cachedSidebarDividerX = nil
                sidebarDividerMissCount = 0
            }
        }

        guard let dividerX = cachedSidebarDividerX else {
            return false
        }

        return SidebarResizeInteraction.Edge.leading.hitRange(dividerX: dividerX).contains(point.x)
    }

    private func shouldPassThroughToTrailingSidebarResizer(
        at point: NSPoint,
        visibleHostedViews: [GhosttySurfaceScrollView]
    ) -> Bool {
        let contentHostedViews = visibleHostedViews.filter { !$0.isRightSidebarDockSurface }
        guard let rightMostEdge = contentHostedViews.map(\.frame.maxX).max() else { return false }
        let trailingGap = bounds.maxX - rightMostEdge
        guard trailingGap > Self.minimumVisibleLeadingContentWidth else { return false }
        return SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightMostEdge).contains(point.x)
    }

    private func updateDividerCursor(at point: NSPoint) {
        if shouldPassThroughToChrome(at: point, eventType: NSApp.currentEvent?.type) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        if shouldPassThroughToSidebarResizer(at: point) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        guard let nextKind = splitDividerCursorKind(at: point) else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    private func splitDividerCursorKind(at point: NSPoint) -> DividerCursorKind? {
        guard let window else { return nil }
        let windowPoint = convert(point, to: nil)
        guard let rootView = window.contentView else { return nil }
        return Self.dividerCursorKind(at: windowPoint, in: rootView)
    }

    static func hasSplitDivider(atScreenPoint screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return dividerCursorKind(at: windowPoint, in: rootView) != nil
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in view: NSView) -> DividerCursorKind? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                // Keep divider interactions reliable even when portal-hosted terminal frames
                // temporarily overlap divider edges during rapid layout churn.
                let expansion: CGFloat = 5
                let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
                for dividerIndex in 0..<dividerCount {
                    let first = splitView.arrangedSubviews[dividerIndex].frame
                    let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                    let thickness = splitView.dividerThickness
                    let dividerRect: NSRect
                    if splitView.isVertical {
                        // Keep divider hit-testing active even when one side is nearly collapsed,
                        // so users can drag the divider back out from the border.
                        // But ignore transient states where both panes are effectively 0-width.
                        guard first.width > 1 || second.width > 1 else { continue }
                        let x = max(0, first.maxX)
                        dividerRect = NSRect(
                            x: x,
                            y: 0,
                            width: thickness,
                            height: splitView.bounds.height
                        )
                    } else {
                        // Same behavior for horizontal splits with a near-zero-height pane.
                        guard first.height > 1 || second.height > 1 else { continue }
                        let y = max(0, first.maxY)
                        dividerRect = NSRect(
                            x: 0,
                            y: y,
                            width: splitView.bounds.width,
                            height: thickness
                        )
                    }
                    let expandedDividerRect = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expandedDividerRect.contains(pointInSplit) {
                        return splitView.isVertical ? .vertical : .horizontal
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let kind = dividerCursorKind(at: windowPoint, in: subview) {
                return kind
            }
        }

        return nil
    }

    private static func collectSplitDividerRegions(in view: NSView, into result: inout [DividerRegion]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(
                    DividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in view.subviews {
            collectSplitDividerRegions(in: subview, into: &result)
        }
    }

#if DEBUG
    private func logDragRouteDecision(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hitView: NSView?
    ) {
        let hasRelevantTypes = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes)
        guard passThrough || hasRelevantTypes else { return }

        let targetClass = hitView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let signature = [
            passThrough ? "1" : "0",
            debugEventName(eventType),
            debugPasteboardTypes(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        cmuxDebugLog(
            "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
            "event=\(debugEventName(eventType)) target=\(targetClass) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
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
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDragged: return "otherMouseDragged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "other(\(eventType.rawValue))"
        }
    }
#endif
}

