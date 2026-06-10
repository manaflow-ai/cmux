import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


final class WindowBrowserHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
    }

    private struct DividerHit {
        let kind: DividerCursorKind
        let isInHostedContent: Bool
    }

    private struct HostedInspectorDividerHit {
        let slotView: WindowBrowserSlotView
        let containerView: NSView
        let pageView: NSView
        let inspectorView: NSView
        let dockSide: HostedInspectorDockSide
    }

    private struct HostedInspectorDividerDragState {
        let slotView: WindowBrowserSlotView
        let containerView: NSView
        let pageView: NSView
        let inspectorView: NSView
        let dockSide: HostedInspectorDockSide
        let initialWindowX: CGFloat
        let initialPageFrame: NSRect
        let initialInspectorFrame: NSRect
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
    private static let hostedInspectorDividerHitExpansion: CGFloat = 6
    private static let minimumHostedInspectorWidth: CGFloat = 120
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
    private var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
    private var lastHostedInspectorLayoutBoundsSize: NSSize?

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        clearActiveDividerCursor(restoreArrow: false)
    }

#if DEBUG
    private static func shouldLogPointerEvent(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    private func debugLogPointerRouting(
        stage: String,
        point: NSPoint,
        titlebarPassThrough: Bool,
        sidebarPassThrough: Bool,
        dividerHit: DividerHit?,
        hitView: NSView?
    ) {
        let event = NSApp.currentEvent
        guard Self.shouldLogPointerEvent(event) else { return }

        let hitDesc: String = {
            guard let hitView else { return "nil" }
            return "\(type(of: hitView))@\(browserPortalDebugToken(hitView))"
        }()
        let dividerDesc: String = {
            guard let dividerHit else { return "nil" }
            let kind = dividerHit.kind == .vertical ? "vertical" : "horizontal"
            return "kind=\(kind),hosted=\(dividerHit.isInHostedContent ? 1 : 0)"
        }()
        let windowPoint = convert(point, to: nil)
        cmuxDebugLog(
            "browser.portal.pointer stage=\(stage) event=\(String(describing: event?.type)) " +
            "host=\(browserPortalDebugToken(self)) point=\(browserPortalDebugFrame(NSRect(origin: point, size: .zero))) " +
            "windowPoint=\(browserPortalDebugFrame(NSRect(origin: windowPoint, size: .zero))) " +
            "titlebar=\(titlebarPassThrough ? 1 : 0) sidebar=\(sidebarPassThrough ? 1 : 0) " +
            "divider=\(dividerDesc) hit=\(hitDesc)"
        )
    }
#endif

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

    override func layout() {
        super.layout()
        if let previousSize = lastHostedInspectorLayoutBoundsSize,
           Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
            return
        }
        lastHostedInspectorLayoutBoundsSize = bounds.size
        reapplyHostedInspectorDividersIfNeeded(reason: "host.layout")
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let slot = subview as? WindowBrowserSlotView else { return }
        slot.onHostedInspectorLayout = { [weak self] slotView in
            self?.reapplyHostedInspectorDividerIfNeeded(in: slotView, reason: "slot.layout")
        }
    }

    override func willRemoveSubview(_ subview: NSView) {
        if let slot = subview as? WindowBrowserSlotView {
            slot.onHostedInspectorLayout = nil
        }
        super.willRemoveSubview(subview)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let rootView = dividerSearchRootView() else { return }
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let routingContext = WindowInputRoutingContext(event: NSApp.currentEvent)
        guard routingContext.allowsPortalPointerHitTesting else {
            let hitView = super.hitTest(point)
            return hitView === self ? nil : hitView
        }

        let dividerHit = splitDividerHit(at: point)
        let hostedInspectorHit = dividerHit == nil ? hostedInspectorDividerHit(at: point) : nil
        updateDividerCursor(at: point, dividerHit: dividerHit, hostedInspectorHit: hostedInspectorHit)

        let eventType = routingContext.eventType
        let titlebarPassThrough = shouldPassThroughToTitlebar(at: point)
        let tabStripPassThrough = shouldPassThroughToPaneTabBar(at: point, eventType: eventType)
        let sidebarPassThrough = shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: dividerHit,
            hostedInspectorHit: hostedInspectorHit
        )
        let splitPassThrough = dividerHit.map { !$0.isInHostedContent } ?? false

        if titlebarPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.titlebarPass",
                point: point,
                titlebarPassThrough: true,
                sidebarPassThrough: sidebarPassThrough,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        if tabStripPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.tabStripPass",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: sidebarPassThrough,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        if sidebarPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.sidebarPass",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: true,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        if splitPassThrough {
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.splitPass",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: false,
                dividerHit: dividerHit,
                hitView: nil
            )
#endif
            return nil
        }
        // Mirror terminal portal routing: while tab-reorder drags are active,
        // pass through to SwiftUI drop targets behind the portal host.
        // Browser hover routing also arrives as cursor/enter events and may not
        // report a pressed-button state, so include that path here.
        if routingContext.allowsBrowserPortalDragRouting,
           Self.shouldPassThroughToDragTargets(
            pasteboardTypes: NSPasteboard(name: .drag).types,
            eventType: eventType
           ) {
            return nil
        }

        if let hostedInspectorHit {
            if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                debugLogPointerRouting(
                    stage: "hitTest.hostedInspectorNative",
                    point: point,
                    titlebarPassThrough: false,
                    sidebarPassThrough: false,
                    dividerHit: DividerHit(kind: .vertical, isInHostedContent: true),
                    hitView: nativeHit
                )
#endif
                return nativeHit
            }
#if DEBUG
            debugLogPointerRouting(
                stage: "hitTest.hostedInspectorManual",
                point: point,
                titlebarPassThrough: false,
                sidebarPassThrough: false,
                dividerHit: DividerHit(kind: .vertical, isInHostedContent: true),
                hitView: hostedInspectorHit.inspectorView
            )
#endif
            return self
        }
        let hitView = super.hitTest(point)
#if DEBUG
        debugLogPointerRouting(
            stage: "hitTest.result",
            point: point,
            titlebarPassThrough: false,
            sidebarPassThrough: false,
            dividerHit: dividerHit,
            hitView: hitView === self ? nil : hitView
        )
#endif
        return hitView === self ? nil : hitView
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
            super.mouseDown(with: event)
            return
        }

        hostedInspectorHit.slotView.isHostedInspectorDividerDragActive = true
        hostedInspectorDividerDrag = HostedInspectorDividerDragState(
            slotView: hostedInspectorHit.slotView,
            containerView: hostedInspectorHit.containerView,
            pageView: hostedInspectorHit.pageView,
            inspectorView: hostedInspectorHit.inspectorView,
            dockSide: hostedInspectorHit.dockSide,
            initialWindowX: event.locationInWindow.x,
            initialPageFrame: hostedInspectorHit.pageView.frame,
            initialInspectorFrame: hostedInspectorHit.inspectorView.frame
        )
#if DEBUG
        cmuxDebugLog(
            "browser.portal.manualInspectorDrag stage=start slot=\(browserPortalDebugToken(hostedInspectorHit.slotView)) " +
            "page=\(browserPortalDebugToken(hostedInspectorHit.pageView)) " +
            "inspector=\(browserPortalDebugToken(hostedInspectorHit.inspectorView)) " +
            "pageFrame=\(browserPortalDebugFrame(hostedInspectorHit.pageView.frame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(hostedInspectorHit.inspectorView.frame))"
        )
#endif
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragState = hostedInspectorDividerDrag else {
            super.mouseDragged(with: event)
            return
        }
        guard dragState.slotView.window === window else {
            dragState.slotView.isHostedInspectorDividerDragActive = false
            hostedInspectorDividerDrag = nil
            super.mouseDragged(with: event)
            return
        }

        let containerBounds = dragState.containerView.bounds
        let minimumInspectorWidth = min(
            Self.minimumHostedInspectorWidth,
            max(60, dragState.initialInspectorFrame.width)
        )
        let initialDividerX = dragState.dockSide.dividerX(
            pageFrame: dragState.initialPageFrame,
            inspectorFrame: dragState.initialInspectorFrame
        )
        let proposedDividerX = initialDividerX + (event.locationInWindow.x - dragState.initialWindowX)
        let clampedDividerX = dragState.dockSide.clampedDividerX(
            proposedDividerX,
            containerBounds: containerBounds,
            pageFrame: dragState.initialPageFrame,
            minimumInspectorWidth: minimumInspectorWidth
        )
        let inspectorWidth = dragState.dockSide.inspectorWidth(
            forDividerX: clampedDividerX,
            in: containerBounds
        )

        dragState.slotView.recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
        let appliedFrames = applyHostedInspectorDividerWidth(
            inspectorWidth,
            to: HostedInspectorDividerHit(
                slotView: dragState.slotView,
                containerView: dragState.containerView,
                pageView: dragState.pageView,
                inspectorView: dragState.inspectorView,
                dockSide: dragState.dockSide
            ),
            minimumInspectorWidth: Self.minimumHostedInspectorWidth,
            reason: "drag"
        )
        updateDividerCursor(
            at: convert(event.locationInWindow, from: nil),
            dividerHit: nil,
            hostedInspectorHit: HostedInspectorDividerHit(
                slotView: dragState.slotView,
                containerView: dragState.containerView,
                pageView: dragState.pageView,
                inspectorView: dragState.inspectorView,
                dockSide: dragState.dockSide
            )
        )
#if DEBUG
        cmuxDebugLog(
            "browser.portal.manualInspectorDrag stage=update slot=\(browserPortalDebugToken(dragState.slotView)) " +
            "dividerX=\(String(format: "%.1f", clampedDividerX)) " +
            "pageFrame=\(browserPortalDebugFrame(appliedFrames.pageFrame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(appliedFrames.inspectorFrame))"
        )
#endif
    }

    override func mouseUp(with event: NSEvent) {
        if let dragState = hostedInspectorDividerDrag {
            dragState.slotView.isHostedInspectorDividerDragActive = false
#if DEBUG
            cmuxDebugLog(
                "browser.portal.manualInspectorDrag stage=end slot=\(browserPortalDebugToken(dragState.slotView)) " +
                "pageFrame=\(browserPortalDebugFrame(dragState.pageView.frame)) " +
                "inspectorFrame=\(browserPortalDebugFrame(dragState.inspectorView.frame))"
            )
#endif
            scheduleHostedInspectorDividerReapply(in: dragState.slotView, reason: "dragEndAsync")
        }
        hostedInspectorDividerDrag = nil
        updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
    }

    private func shouldPassThroughToTitlebar(at point: NSPoint) -> Bool {
        guard let window else { return false }
        // Window-level portal hosts sit above SwiftUI content. Never intercept
        // hits that land in native titlebar space or the custom titlebar strip
        // we reserve directly under it for window drag/double-click behaviors.
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
        return decision.result
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        let dividerHit = splitDividerHit(at: point)
        let hostedInspectorHit = dividerHit == nil ? hostedInspectorDividerHit(at: point) : nil
        return shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: dividerHit,
            hostedInspectorHit: hostedInspectorHit
        )
    }

    private func shouldPassThroughToSidebarResizer(
        at point: NSPoint,
        dividerHit: DividerHit?,
        hostedInspectorHit: HostedInspectorDividerHit? = nil
    ) -> Bool {
        // If WebKit has a hosted vertical inspector split collapsed to the pane edge,
        // prefer that divider over the app/sidebar resize hit zone.
        if let dividerHit,
           dividerHit.isInHostedContent,
           dividerHit.kind == .vertical {
            return false
        }
        if hostedInspectorHit != nil {
            return false
        }

        // Browser portal host sits above SwiftUI content. Allow pointer/mouse events
        // to reach the SwiftUI sidebar divider resizer zone.
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        if shouldPassThroughToTrailingSidebarResizer(at: point, visibleSlots: visibleSlots) {
            return true
        }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleSlots.contains {
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

        // Ignore transient 0-origin slots during layout churn and preserve the last
        // known-good divider edge.
        let dividerCandidates = visibleSlots
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
        visibleSlots: [WindowBrowserSlotView]
    ) -> Bool {
        guard let rightMostEdge = visibleSlots.map(\.frame.maxX).max() else { return false }
        let trailingGap = bounds.maxX - rightMostEdge
        guard trailingGap > Self.minimumVisibleLeadingContentWidth else { return false }
        return SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightMostEdge).contains(point.x)
    }

    private func updateDividerCursor(
        at point: NSPoint,
        dividerHit: DividerHit? = nil,
        hostedInspectorHit: HostedInspectorDividerHit? = nil
    ) {
        let resolvedDividerHit = dividerHit ?? splitDividerHit(at: point)
        let resolvedHostedInspectorHit = resolvedDividerHit == nil ? (hostedInspectorHit ?? hostedInspectorDividerHit(at: point)) : nil
        if shouldPassThroughToSidebarResizer(
            at: point,
            dividerHit: resolvedDividerHit,
            hostedInspectorHit: resolvedHostedInspectorHit
        ) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        let nextKind = resolvedDividerHit?.kind ?? (resolvedHostedInspectorHit == nil ? nil : .vertical)
        guard let nextKind else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func nativeHostedInspectorHit(
        at point: NSPoint,
        hostedInspectorHit: HostedInspectorDividerHit
    ) -> NSView? {
        guard let nativeHit = super.hitTest(point), nativeHit !== self else { return nil }
        if nativeHit === hostedInspectorHit.pageView ||
            nativeHit.isDescendant(of: hostedInspectorHit.pageView) {
            return nil
        }
        if nativeHit === hostedInspectorHit.inspectorView ||
            nativeHit.isDescendant(of: hostedInspectorHit.inspectorView) {
            return nativeHit
        }
        if hostedInspectorHit.inspectorView.isDescendant(of: nativeHit),
           !(hostedInspectorHit.pageView === nativeHit || hostedInspectorHit.pageView.isDescendant(of: nativeHit)) {
            return nativeHit
        }
        return nil
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    private func splitDividerHit(at point: NSPoint) -> DividerHit? {
        guard window != nil else { return nil }
        let windowPoint = convert(point, to: nil)
        guard let rootView = dividerSearchRootView() else { return nil }
        return Self.dividerHit(at: windowPoint, in: rootView, hostView: self)
    }

    private func dividerSearchRootView() -> NSView? {
        if let container = superview {
            return container
        }
        return window?.contentView
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        guard let dividerHit = splitDividerHit(at: point) else { return false }
        // Portal host should pass split-divider events through to app layout splits,
        // but keep WebKit inspector/internal split dividers interactive.
        return !dividerHit.isInHostedContent
    }

    static func shouldPassThroughToDragTargets(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        )
    }

    private func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.height > 1 }

        for slot in visibleSlots {
            let pointInSlot = slot.convert(point, from: self)
            guard slot.bounds.contains(pointInSlot),
                  let hit = hostedInspectorDividerCandidate(in: slot) else {
                continue
            }

            if hostedInspectorDividerHitRect(for: hit).contains(pointInSlot) {
                return hit
            }
        }

        return nil
    }

    private func hostedInspectorDividerCandidate(in slot: WindowBrowserSlotView) -> HostedInspectorDividerHit? {
        let inspectorCandidates = Self.visibleDescendants(in: slot)
            .filter { Self.isVisibleHostedInspectorCandidate($0) && Self.isInspectorView($0) }
            .sorted { lhs, rhs in
                let lhsFrame = slot.convert(lhs.bounds, from: lhs)
                let rhsFrame = slot.convert(rhs.bounds, from: rhs)
                return lhsFrame.minX < rhsFrame.minX
            }

        var bestHit: HostedInspectorDividerHit?
        var bestScore = -CGFloat.greatestFiniteMagnitude

        for inspectorCandidate in inspectorCandidates {
            guard let candidate = hostedInspectorDividerCandidate(in: slot, startingAt: inspectorCandidate) else {
                continue
            }
            let score = hostedInspectorDividerCandidateScore(candidate)
            if score > bestScore {
                bestScore = score
                bestHit = candidate
            }
        }

        return bestHit
    }

    private func hostedInspectorDividerCandidate(
        in slot: WindowBrowserSlotView,
        startingAt inspectorLeaf: NSView
    ) -> HostedInspectorDividerHit? {
        var current: NSView? = inspectorLeaf
        var bestHit: HostedInspectorDividerHit?

        while let inspectorView = current, inspectorView !== slot {
            guard let containerView = inspectorView.superview else { break }

            let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                guard Self.isVisibleHostedInspectorSiblingCandidate(candidate) else { return nil }
                guard candidate !== inspectorView else { return nil }
                guard Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8 else {
                    return nil
                }
                guard let dockSide = HostedInspectorDockSide.resolve(
                    pageFrame: candidate.frame,
                    inspectorFrame: inspectorView.frame
                ) else {
                    return nil
                }
                return (view: candidate, dockSide: dockSide)
            }

            if let pageCandidate = pageCandidates.max(by: {
                hostedInspectorPageCandidateScore($0.view, inspectorView: inspectorView)
                    < hostedInspectorPageCandidateScore($1.view, inspectorView: inspectorView)
            }) {
                bestHit = HostedInspectorDividerHit(
                    slotView: slot,
                    containerView: containerView,
                    pageView: pageCandidate.view,
                    inspectorView: inspectorView,
                    dockSide: pageCandidate.dockSide
                )
            }

            current = containerView
        }

        return bestHit
    }

    private func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
        let slotBounds = hit.slotView.bounds
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        return hit.dockSide.dividerHitRect(
            in: slotBounds,
            pageFrame: pageFrame,
            inspectorFrame: inspectorFrame,
            expansion: Self.hostedInspectorDividerHitExpansion
        )
    }

    private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
        let pageFrame = hit.slotView.convert(hit.pageView.bounds, from: hit.pageView)
        let inspectorFrame = hit.slotView.convert(hit.inspectorView.bounds, from: hit.inspectorView)
        let overlap = Self.verticalOverlap(between: pageFrame, and: inspectorFrame)
        let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
        return (overlap * 1_000) + coverageWidth + pageFrame.width
    }

    private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
        let overlap = Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
        let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
        return (overlap * 1_000) + coverageWidth + pageView.frame.width
    }

    private func reapplyHostedInspectorDividersIfNeeded(reason: String) {
        let visibleSlots = subviews.compactMap { $0 as? WindowBrowserSlotView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.height > 1 }
        for slot in visibleSlots {
            reapplyHostedInspectorDividerIfNeeded(in: slot, reason: reason)
        }
    }

    private func scheduleHostedInspectorDividerReapply(in slot: WindowBrowserSlotView, reason: String) {
        guard slot.preferredHostedInspectorWidth != nil else { return }
        DispatchQueue.main.async { [weak self, weak slot] in
            guard let self, let slot, slot.isDescendant(of: self) else { return }
            self.reapplyHostedInspectorDividerIfNeeded(in: slot, reason: reason)
        }
    }

    @discardableResult
    func reapplyHostedInspectorDividerIfNeeded(in slot: WindowBrowserSlotView, reason: String) -> Bool {
        guard !slot.isHostedInspectorDividerDragActive else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.manualInspectorDrag stage=skipReapply slot=\(browserPortalDebugToken(slot)) " +
                "reason=\(reason)"
            )
#endif
            return false
        }
        guard let preferredWidth = slot.resolvedPreferredHostedInspectorWidth(in: slot.bounds) else { return false }
        guard let hit = hostedInspectorDividerCandidate(in: slot) else { return false }
        let oldPageFrame = hit.pageView.frame
        let oldInspectorFrame = hit.inspectorView.frame
        _ = applyHostedInspectorDividerWidth(
            preferredWidth,
            to: hit,
            minimumInspectorWidth: Self.minimumHostedInspectorWidth,
            reason: reason
        )
        return !Self.rectApproximatelyEqual(oldPageFrame, hit.pageView.frame, epsilon: 0.5) ||
            !Self.rectApproximatelyEqual(oldInspectorFrame, hit.inspectorView.frame, epsilon: 0.5)
    }

    @discardableResult
    private func applyHostedInspectorDividerWidth(
        _ preferredWidth: CGFloat,
        to hit: HostedInspectorDividerHit,
        minimumInspectorWidth: CGFloat,
        reason: String
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let containerBounds = hit.containerView.bounds
        let nextFrames = hit.dockSide.resizedFrames(
            preferredWidth: preferredWidth,
            in: containerBounds,
            pageFrame: hit.pageView.frame,
            inspectorFrame: hit.inspectorView.frame,
            minimumInspectorWidth: minimumInspectorWidth
        )
        let pageFrame = nextFrames.pageFrame
        let inspectorFrame = nextFrames.inspectorFrame

        let oldPageFrame = hit.pageView.frame
        let oldInspectorFrame = hit.inspectorView.frame
        let pageChanged = !Self.rectApproximatelyEqual(pageFrame, oldPageFrame, epsilon: 0.5)
        let inspectorChanged = !Self.rectApproximatelyEqual(inspectorFrame, oldInspectorFrame, epsilon: 0.5)
        guard pageChanged || inspectorChanged else {
            return (pageFrame, inspectorFrame)
        }

        hit.slotView.isApplyingHostedInspectorLayout = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hit.pageView.frame = pageFrame
        hit.inspectorView.frame = inspectorFrame
        CATransaction.commit()
        hit.slotView.isApplyingHostedInspectorLayout = false

        let isLiveDrag = reason == "drag"
        hit.pageView.needsDisplay = true
        hit.pageView.setNeedsDisplay(hit.pageView.bounds)
        hit.inspectorView.needsDisplay = true
        hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
        hit.containerView.needsDisplay = true
        hit.containerView.setNeedsDisplay(hit.containerView.bounds)
        hit.slotView.needsDisplay = true
        hit.slotView.setNeedsDisplay(hit.slotView.bounds)
#if DEBUG
        cmuxDebugLog(
            "browser.portal.manualInspectorDrag stage=reapply slot=\(browserPortalDebugToken(hit.slotView)) " +
            "container=\(browserPortalDebugToken(hit.containerView)) reason=\(reason) " +
            "preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
            "liveDrag=\(isLiveDrag ? 1 : 0) " +
            "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
            "oldPageFrame=\(browserPortalDebugFrame(oldPageFrame)) oldInspectorFrame=\(browserPortalDebugFrame(oldInspectorFrame)) " +
            "pageFrame=\(browserPortalDebugFrame(pageFrame)) " +
            "inspectorFrame=\(browserPortalDebugFrame(inspectorFrame))"
        )
#endif
        return (pageFrame, inspectorFrame)
    }
    private static func dividerHit(
        at windowPoint: NSPoint,
        in view: NSView,
        hostView: WindowBrowserHostView
    ) -> DividerHit? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
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
                    let expanded = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expanded.contains(pointInSplit) {
                        return DividerHit(
                            kind: splitView.isVertical ? .vertical : .horizontal,
                            isInHostedContent: splitView.isDescendant(of: hostView)
                        )
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let hit = dividerHit(at: windowPoint, in: subview, hostView: hostView) {
                return hit
            }
        }

        return nil
    }

    private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }

    private static func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    private static func isInspectorView(_ view: NSView) -> Bool {
        cmuxIsWebInspectorObject(view)
    }

    private static func isVisibleHostedInspectorCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    private static func isVisibleHostedInspectorSiblingCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.height > 1
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

}

