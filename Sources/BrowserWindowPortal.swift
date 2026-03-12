import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit

private var cmuxWindowBrowserPortalKey: UInt8 = 0
private var cmuxWindowBrowserPortalCloseObserverKey: UInt8 = 0
private var cmuxBrowserSearchOverlayPanelIdAssociationKey: UInt8 = 0

#if DEBUG
private func browserPortalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func browserPortalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}
#endif

private extension NSObject {
    @discardableResult
    func browserPortalCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

private extension NSResponder {
    var browserPortalOwningView: NSView? {
        if let editor = self as? NSTextView,
           editor.isFieldEditor,
           let editedView = editor.delegate as? NSView {
            return editedView
        }
        return self as? NSView
    }
}

private extension WKWebView {
    func browserPortalNotifyHidden(reason: String) {
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPortalCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "browser.portal.webview.hidden web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func browserPortalReattachRenderingState(reason: String) {
        guard window != nil else { return }

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPortalCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            dlog(
                "browser.portal.webview.reattach web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPortalDebugFrame(frame))"
            )
        }
#endif
    }
}

enum HostedInspectorDockSide {
    case leading
    case trailing

    static func resolve(
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        epsilon: CGFloat = 1
    ) -> Self? {
        if pageFrame.maxX <= inspectorFrame.minX + epsilon {
            return .trailing
        }
        if inspectorFrame.maxX <= pageFrame.minX + epsilon {
            return .leading
        }
        return nil
    }

    func dividerX(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        }
    }

    func dividerHitRect(
        in bounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        expansion: CGFloat
    ) -> NSRect {
        return NSRect(
            x: dividerX(pageFrame: pageFrame, inspectorFrame: inspectorFrame) - expansion,
            y: bounds.minY,
            width: expansion * 2,
            height: max(0, bounds.height)
        )
    }

    func clampedDividerX(
        _ proposedDividerX: CGFloat,
        containerBounds: NSRect,
        pageFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> CGFloat {
        switch self {
        case .leading:
            let minDividerX = min(containerBounds.maxX, containerBounds.minX + minimumInspectorWidth)
            let maxDividerX = max(minDividerX, min(containerBounds.maxX, pageFrame.maxX))
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        case .trailing:
            let minDividerX = max(containerBounds.minX, pageFrame.minX)
            let maxDividerX = max(minDividerX, containerBounds.maxX - minimumInspectorWidth)
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        }
    }

    func inspectorWidth(forDividerX dividerX: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerX - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerX)
        }
    }

    func resizedFrames(
        preferredWidth: CGFloat,
        in containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let normalizedMinY = containerBounds.minY
        let normalizedHeight = max(0, containerBounds.height)

        switch self {
        case .leading:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = min(containerBounds.maxX, containerBounds.minX + clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = dividerX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = containerBounds.minX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)

        case .trailing:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = max(containerBounds.minX, containerBounds.maxX - clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = containerBounds.minX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = dividerX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)
        }
    }
}

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
        dlog(
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
        let dividerHit = splitDividerHit(at: point)
        let hostedInspectorHit = dividerHit == nil ? hostedInspectorDividerHit(at: point) : nil
        updateDividerCursor(at: point, dividerHit: dividerHit, hostedInspectorHit: hostedInspectorHit)

        let titlebarPassThrough = shouldPassThroughToTitlebar(at: point)
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
        if Self.shouldPassThroughToDragTargets(
            pasteboardTypes: NSPasteboard(name: .drag).types,
            eventType: NSApp.currentEvent?.type
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
        dlog(
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
        dlog(
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
            dlog(
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
        let nativeTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let customTitlebarBandHeight = max(28, min(72, nativeTitlebarHeight))
        let interactionBandMinY = window.contentLayoutRect.maxY - customTitlebarBandHeight - 0.5
        return windowPoint.y >= interactionBandMinY
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

        let regionMinX = dividerX - SidebarResizeInteraction.hitWidthPerSide
        let regionMaxX = dividerX + SidebarResizeInteraction.hitWidthPerSide
        return point.x >= regionMinX && point.x <= regionMaxX
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
        if DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        ) {
            return true
        }

        guard let eventType else { return false }
        switch eventType {
        case .cursorUpdate, .mouseEntered, .mouseExited, .mouseMoved:
            // Browser-side tab drags can surface as hover events with a mixed
            // pasteboard payload (tabtransfer plus promised-file UTIs). Prefer
            // the explicit Bonsplit drag types so WKWebView cannot steal the
            // session as a file upload.
            return DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
                || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
        default:
            return false
        }
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
    fileprivate func reapplyHostedInspectorDividerIfNeeded(in slot: WindowBrowserSlotView, reason: String) -> Bool {
        guard !slot.isHostedInspectorDividerDragActive else {
#if DEBUG
            dlog(
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
        dlog(
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
        String(describing: type(of: view)).contains("WKInspector")
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

private final class BrowserDropZoneOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct BrowserPortalSearchOverlayConfiguration {
    let panelId: UUID
    let searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void
}

struct BrowserPaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

struct BrowserPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    static func decode(from pasteboard: NSPasteboard) -> BrowserPaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data) -> BrowserPaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        return BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId
        )
    }
}

struct BrowserPaneSplitTarget: Equatable {
    let orientation: SplitOrientation
    let insertFirst: Bool
}

enum BrowserPaneDropAction: Equatable {
    case noOp
    case move(
        tabId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        splitTarget: BrowserPaneSplitTarget?
    )
}

enum BrowserPaneDropRouting {
    private static let padding: CGFloat = 4

    private static func fullPaneSize(for slotSize: CGSize, topChromeHeight: CGFloat) -> CGSize {
        CGSize(width: slotSize.width, height: slotSize.height + max(0, topChromeHeight))
    }

    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, fullPaneSize.width * edgeRatio)
        let verticalEdge = max(80, fullPaneSize.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > fullPaneSize.width - horizontalEdge {
            return .right
        } else if location.y > fullPaneSize.height - verticalEdge {
            return .top
        } else if location.y < verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        switch zone {
        case .center:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height - padding * 2
            )
        case .left:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width / 2 - padding,
                height: fullPaneSize.height - padding * 2
            )
        case .right:
            return CGRect(
                x: fullPaneSize.width / 2,
                y: padding,
                width: fullPaneSize.width / 2 - padding,
                height: fullPaneSize.height - padding * 2
            )
        case .top:
            return CGRect(
                x: padding,
                y: fullPaneSize.height / 2,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height / 2 - padding
            )
        case .bottom:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height / 2 - padding
            )
        }
    }

    static func action(
        for transfer: BrowserPaneDragTransfer,
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BrowserPaneDropAction? {
        if zone == .center, transfer.sourcePaneId == target.paneId.id {
            return .noOp
        }

        let splitTarget: BrowserPaneSplitTarget?
        switch zone {
        case .center:
            splitTarget = nil
        case .left:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: true)
        case .right:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
        case .top:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: true)
        case .bottom:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: false)
        }

        return .move(
            tabId: transfer.tabId,
            targetWorkspaceId: target.workspaceId,
            targetPane: target.paneId,
            splitTarget: splitTarget
        )
    }
}

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
              let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
#if DEBUG
            dlog("browser.paneDrop.perform allowed=0 reason=missingTransfer")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )
        guard let action = BrowserPaneDropRouting.action(
            for: transfer,
            target: dropContext,
            zone: zone
        ) else {
#if DEBUG
            dlog(
                "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=noAction zone=\(zone)"
            )
#endif
            return false
        }

        switch action {
        case .noOp:
#if DEBUG
            dlog(
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
            dlog(
                "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuidString.prefix(5)) zone=\(zone) pane=\(targetPane.id.uuidString.prefix(5)) " +
                "split=\(splitLabel) moved=\(moved ? 1 : 0)"
            )
#endif
            return moved
        }
    }

    private func updateDragState(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        guard let dropContext,
              let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )
        activeZone = zone
        slotView?.setPortalDragDropZone(zone)
#if DEBUG
        dlog(
            "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone)"
        )
#endif
        return .move
    }

    private func clearDragState(phase: String) {
        guard activeZone != nil else { return }
        activeZone = nil
        slotView?.setPortalDragDropZone(nil)
#if DEBUG
        if let dropContext {
            dlog(
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
        dlog(
            "browser.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) context=\(dropContext != nil ? 1 : 0) " +
            "event=\(eventType.map { String($0.rawValue) } ?? "nil") types=\(types)"
        )
    }
#endif
}

final class WindowBrowserSlotView: NSView {
    override var isOpaque: Bool { false }
    private let paneDropTargetView = BrowserPaneDropTargetView(frame: .zero)
    private let dropZoneOverlayView = BrowserDropZoneOverlayView(frame: .zero)
    private var searchOverlayHostingView: NSHostingView<BrowserSearchOverlay>?
    private weak var hostedWebView: WKWebView?
    private var hostedWebViewConstraints: [NSLayoutConstraint] = []
    private var forwardedDropZone: DropZone?
    private var portalDragDropZone: DropZone?
    private var displayedDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var isRefreshingInteractionLayers = false
    private var paneTopChromeHeight: CGFloat = 0
    var preferredHostedInspectorWidth: CGFloat?
    private var preferredHostedInspectorWidthFraction: CGFloat?
    fileprivate var isHostedInspectorDividerDragActive = false
    var onHostedInspectorLayout: ((WindowBrowserSlotView) -> Void)?
    fileprivate var isApplyingHostedInspectorLayout = false
    private var lastHostedInspectorLayoutBoundsSize: NSSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []

        paneDropTargetView.slotView = self

        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        paneDropTargetView.frame = bounds
        applyResolvedDropZoneOverlay()
        guard !isApplyingHostedInspectorLayout else { return }
        if let previousSize = lastHostedInspectorLayoutBoundsSize,
           Self.sizeApproximatelyEqual(previousSize, bounds.size) {
            return
        }
        lastHostedInspectorLayoutBoundsSize = bounds.size
        onHostedInspectorLayout?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachDropZoneOverlayIfNeeded()
        applyResolvedDropZoneOverlay()
    }

    func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
        preferredHostedInspectorWidth = width
        guard containerBounds.width > 0 else {
            preferredHostedInspectorWidthFraction = nil
            return
        }
        preferredHostedInspectorWidthFraction = width / containerBounds.width
    }

    func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
        if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
            return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
        }
        return preferredHostedInspectorWidth
    }

    private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        forwardedDropZone = zone
        applyResolvedDropZoneOverlay()
    }

    func setPortalDragDropZone(_ zone: DropZone?) {
        portalDragDropZone = zone
        applyResolvedDropZoneOverlay()
    }

    func setPaneDropContext(_ context: BrowserPaneDropContext?) {
        paneDropTargetView.dropContext = context
    }

    func setPaneTopChromeHeight(_ height: CGFloat) {
        let resolvedHeight = max(0, height)
        guard abs(paneTopChromeHeight - resolvedHeight) > 0.5 else { return }
        paneTopChromeHeight = resolvedHeight
        applyResolvedDropZoneOverlay()
    }

    private func logSearchOverlayEvent(_ action: String, panelId: UUID?) {
#if DEBUG
        let firstResponderSummary: String = {
            guard let firstResponder = window?.firstResponder else { return "nil" }
            if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
                let delegateSummary = editor.delegate.map { String(describing: type(of: $0)) } ?? "nil"
                return "fieldEditor(delegate=\(delegateSummary))"
            }
            return String(describing: type(of: firstResponder))
        }()
        dlog(
            "browser.findbar.portal action=\(action) " +
            "panel=\(panelId?.uuidString.prefix(5) ?? "nil") " +
            "window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(firstResponderSummary) " +
            "hasOverlay=\(searchOverlayHostingView != nil ? 1 : 0)"
        )
#endif
    }

    func setSearchOverlay(_ configuration: BrowserPortalSearchOverlayConfiguration?) {
        guard let configuration else {
            logSearchOverlayEvent("remove", panelId: nil)
            if let overlay = searchOverlayHostingView {
                objc_setAssociatedObject(
                    overlay,
                    &cmuxBrowserSearchOverlayPanelIdAssociationKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
            searchOverlayHostingView?.removeFromSuperview()
            searchOverlayHostingView = nil
            return
        }

        logSearchOverlayEvent("set", panelId: configuration.panelId)
        let rootView = BrowserSearchOverlay(
            panelId: configuration.panelId,
            searchState: configuration.searchState,
            focusRequestGeneration: configuration.focusRequestGeneration,
            canApplyFocusRequest: configuration.canApplyFocusRequest,
            onNext: configuration.onNext,
            onPrevious: configuration.onPrevious,
            onClose: configuration.onClose,
            onFieldDidFocus: configuration.onFieldDidFocus
        )

        if let overlay = searchOverlayHostingView {
            logSearchOverlayEvent("updateExisting", panelId: configuration.panelId)
            overlay.rootView = rootView
            objc_setAssociatedObject(
                overlay,
                &cmuxBrowserSearchOverlayPanelIdAssociationKey,
                configuration.panelId,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            if overlay.superview !== self {
                overlay.removeFromSuperview()
                addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            return
        }

        let overlay = NSHostingView(rootView: rootView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(
            overlay,
            &cmuxBrowserSearchOverlayPanelIdAssociationKey,
            configuration.panelId,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        searchOverlayHostingView = overlay
        logSearchOverlayEvent("create", panelId: configuration.panelId)
    }

    func searchOverlayPanelId(for responder: NSResponder) -> UUID? {
        guard let overlay = searchOverlayHostingView,
              let view = responder.browserPortalOwningView,
              view.isDescendant(of: overlay) else {
            return nil
        }
        return objc_getAssociatedObject(overlay, &cmuxBrowserSearchOverlayPanelIdAssociationKey) as? UUID
    }

    @discardableResult
    func yieldSearchOverlayFocusIfOwned(by panelId: UUID, in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder,
              searchOverlayPanelId(for: firstResponder) == panelId else {
            return false
        }
        return window.makeFirstResponder(nil)
    }

    func pinHostedWebView(_ webView: WKWebView) {
        guard webView.superview === self else { return }

        let hasCompanionWKSubviews = Self.hasWebKitCompanionSubview(in: self, primaryWebView: webView)
        let needsPlainWebViewFrameReset =
            !hasCompanionWKSubviews &&
            Self.frameDiffersFromBounds(webView.frame, bounds: bounds)
        let needsFrameHosting =
            hostedWebView !== webView ||
            !hostedWebViewConstraints.isEmpty ||
            needsPlainWebViewFrameReset ||
            !webView.translatesAutoresizingMaskIntoConstraints ||
            webView.autoresizingMask != [.width, .height]
        guard needsFrameHosting else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }

        NSLayoutConstraint.deactivate(hostedWebViewConstraints)
        hostedWebViewConstraints = []
        hostedWebView = webView
        // Attached Web Inspector mutates the moved WKWebView's frame directly.
        // Re-pin plain web views after cross-host reattach, but preserve the
        // WebKit-managed split frame when docked DevTools siblings are present.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        if !hasCompanionWKSubviews {
            webView.frame = bounds
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func frameDiffersFromBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(frame.minX - bounds.minX) > epsilon ||
            abs(frame.minY - bounds.minY) > epsilon ||
            abs(frame.width - bounds.width) > epsilon ||
            abs(frame.height - bounds.height) > epsilon
    }

    private static func hasWebKitCompanionSubview(in host: NSView, primaryWebView: WKWebView) -> Bool {
        var stack = host.subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current.isDescendant(of: primaryWebView) {
                continue
            }
            if String(describing: type(of: current)).contains("WK") {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    func effectivePaneTopChromeHeight() -> CGFloat {
        paneTopChromeHeight
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== paneDropTargetView else { return }
        bringInteractionLayersToFrontIfNeeded()
    }

    private var activeDropZone: DropZone? {
        portalDragDropZone ?? forwardedDropZone
    }

    private func overlayContainerView() -> NSView {
        superview ?? self
    }

    private func attachDropZoneOverlayIfNeeded() {
        let container = overlayContainerView()
        guard dropZoneOverlayView.superview !== container else { return }
        dropZoneOverlayView.removeFromSuperview()
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
    }

    private func applyResolvedDropZoneOverlay() {
        let resolvedZone = activeDropZone
        if resolvedZone != nil, (bounds.width <= 2 || bounds.height <= 2) {
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        let previousZone = displayedDropZone
        displayedDropZone = resolvedZone
        let previousFrame = dropZoneOverlayView.frame

        guard let zone = resolvedZone else {
            guard !dropZoneOverlayView.isHidden else {
                bringInteractionLayersToFrontIfNeeded()
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
            bringInteractionLayersToFrontIfNeeded()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.displayedDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
            }
            return
        }
        attachDropZoneOverlayIfNeeded()

        let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
        let needsFrameUpdate = !Self.rectApproximatelyEqual(previousFrame, targetFrame)
        let zoneChanged = previousZone != zone

        if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        dropZoneOverlayAnimationGeneration &+= 1
        dropZoneOverlayView.layer?.removeAllAnimations()

        if dropZoneOverlayView.isHidden {
            applyDropZoneOverlayFrame(targetFrame)
            dropZoneOverlayView.alphaValue = 0
            dropZoneOverlayView.isHidden = false
            bringInteractionLayersToFrontIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dropZoneOverlayView.animator().alphaValue = 1
            }
            return
        }

        bringInteractionLayersToFrontIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if needsFrameUpdate {
                dropZoneOverlayView.animator().frame = targetFrame
            }
            if dropZoneOverlayView.alphaValue < 1 {
                dropZoneOverlayView.animator().alphaValue = 1
            }
        }
    }

    private func interactionLayerPriority(of view: NSView) -> Int {
        if view === paneDropTargetView { return 1 }
        return 0
    }

    private func bringInteractionLayersToFrontIfNeeded() {
        guard !isRefreshingInteractionLayers else { return }
        isRefreshingInteractionLayers = true
        defer { isRefreshingInteractionLayers = false }

        if paneDropTargetView.superview !== self {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
        let overlayContainer = overlayContainerView()
        if dropZoneOverlayView.superview !== overlayContainer {
            attachDropZoneOverlayIfNeeded()
        } else if overlayContainer.subviews.last !== dropZoneOverlayView {
            overlayContainer.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let slotView = Unmanaged<WindowBrowserSlotView>.fromOpaque(context).takeUnretainedValue()
            let lhsPriority = slotView.interactionLayerPriority(of: lhs)
            let rhsPriority = slotView.interactionLayerPriority(of: rhs)
            if lhsPriority == rhsPriority { return .orderedSame }
            return lhsPriority < rhsPriority ? .orderedAscending : .orderedDescending
        }, context: context)
    }

    private func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = BrowserPaneDropRouting.overlayFrame(
            for: zone,
            in: size,
            topChromeHeight: paneTopChromeHeight
        )
        guard let superview else { return localFrame }
        return superview.convert(localFrame, from: self)
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}

@MainActor
final class WindowBrowserPortal: NSObject {
    private static let transientRecoveryRetryBudget: Int = 12

    private weak var window: NSWindow?
    private let hostView = WindowBrowserHostView(frame: .zero)
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    private var geometryObservers: [NSObjectProtocol] = []

    private struct Entry {
        weak var webView: WKWebView?
        weak var containerView: WindowBrowserSlotView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var dropZone: DropZone?
        var paneDropContext: BrowserPaneDropContext?
        var searchOverlay: BrowserPortalSearchOverlayConfiguration?
        var paneTopChromeHeight: CGFloat
        var transientRecoveryReason: String?
        var transientRecoveryRetriesRemaining: Int
    }

    private var entriesByWebViewId: [ObjectIdentifier: Entry] = [:]
    private var webViewByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.autoresizingMask = []
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

    static func shouldTreatSplitResizeAsExternalGeometry(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: WindowBrowserHostView
    ) -> Bool {
        guard splitView.window === window else { return false }
        // WebKit's attached DevTools uses internal NSSplitView instances for the
        // side/bottom inspector layout. Those resizes are local to hosted content
        // and should not trigger a full portal re-sync/refresh pass.
        return !splitView.isDescendant(of: hostView)
    }

    private func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      Self.shouldTreatSplitResizeAsExternalGeometry(
                          splitView,
                          window: window,
                          hostView: self.hostView
                      ) else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    private func scheduleExternalGeometrySynchronize() {
        guard !hasExternalGeometrySyncScheduled else { return }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasExternalGeometrySyncScheduled = false
            self.synchronizeAllEntriesFromExternalGeometryChange()
        }
    }

    private func synchronizeAllEntriesFromExternalGeometryChange() {
        guard ensureInstalled() else { return }
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        synchronizeAllWebViews(excluding: nil, source: "externalGeometry")

        for entry in entriesByWebViewId.values {
            guard let webView = entry.webView,
                  let containerView = entry.containerView,
                  !containerView.isHidden else { continue }
            guard webView.superview === containerView else { continue }
            refreshHostedWebViewPresentation(
                webView,
                in: containerView,
                reason: "externalGeometry"
            )
        }
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }
        let placementReference = preferredHostPlacementReference(in: container, fallback: reference)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            installedContainerView = container
            installedReferenceView = reference
        } else {
            let aboveReference = Self.isView(hostView, above: reference, in: container)
            let abovePlacementReference = placementReference === reference
                || Self.isView(hostView, above: placementReference, in: container)
            if !aboveReference || !abovePlacementReference {
                container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            }
        }

        synchronizeHostFrameToReference()
        return true
    }

    @discardableResult
    private func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostView.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.hostFrame.update host=\(browserPortalDebugToken(hostView)) " +
                "frame=\(browserPortalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        if contentView.className == "NSGlassEffectView",
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    private static func searchOverlayConfigurationsEquivalent(
        _ lhs: BrowserPortalSearchOverlayConfiguration?,
        _ rhs: BrowserPortalSearchOverlayConfiguration?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.panelId == rhs.panelId &&
                lhs.searchState === rhs.searchState &&
                lhs.focusRequestGeneration == rhs.focusRequestGeneration
        default:
            return false
        }
    }

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor clipping.
    /// SwiftUI/AppKit hosting layers can briefly report an anchor bounds rect larger than the
    /// visible split pane during rearrangement; intersecting through ancestor bounds keeps the
    /// portal locked to the pane the user can actually see.
    private func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    private static func frameExtendsOutsideBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        frame.minX < bounds.minX - epsilon ||
            frame.minY < bounds.minY - epsilon ||
            frame.maxX > bounds.maxX + epsilon ||
            frame.maxY > bounds.maxY + epsilon
    }

#if DEBUG
    private static func inspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if String(describing: type(of: subview)).contains("WKInspector") {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }
#endif

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    private func preferredHostPlacementReference(in container: NSView, fallback reference: NSView) -> NSView {
        container.subviews.last(where: {
            $0 !== hostView && ($0 === reference || $0 is WindowTerminalHostView)
        }) ?? reference
    }

    private func ensureContainerView(for entry: Entry, webView: WKWebView) -> WindowBrowserSlotView {
        if let existing = entry.containerView {
            existing.setPaneDropContext(entry.paneDropContext)
            existing.setSearchOverlay(entry.searchOverlay)
            existing.setPaneTopChromeHeight(entry.paneTopChromeHeight)
            return existing
        }
        let created = WindowBrowserSlotView(frame: .zero)
        created.setPaneDropContext(entry.paneDropContext)
        created.setSearchOverlay(entry.searchOverlay)
        created.setPaneTopChromeHeight(entry.paneTopChromeHeight)
#if DEBUG
        dlog(
            "browser.portal.container.create web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(created))"
        )
#endif
        return created
    }

    private func runHostedWebViewRefreshPass(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String,
        phase: String
    ) {
        guard !containerView.isHidden else { return }
        guard !containerView.isHostedInspectorDividerDragActive else {
#if DEBUG
            dlog(
                "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) reason=\(reason) phase=\(phase) drag=1"
            )
#endif
            return
        }

        containerView.needsLayout = true
        containerView.needsDisplay = true
        containerView.setNeedsDisplay(containerView.bounds)

        if let scrollView = webView.enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        webView.needsLayout = true
        webView.needsDisplay = true
        webView.setNeedsDisplay(webView.bounds)

        containerView.layoutSubtreeIfNeeded()
        if let scrollView = webView.enclosingScrollView {
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.layoutSubtreeIfNeeded()
            scrollView.displayIfNeeded()
        }
        webView.layoutSubtreeIfNeeded()
        webView.browserPortalReattachRenderingState(reason: "\(reason):\(phase)")
        containerView.displayIfNeeded()
        webView.displayIfNeeded()
        (webView.window ?? hostView.window)?.displayIfNeeded()
#if DEBUG
        dlog(
            "browser.portal.refresh web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(containerView)) reason=\(reason) " +
            "phase=\(phase) frame=\(browserPortalDebugFrame(containerView.frame))"
        )
#endif
    }

    private func refreshHostedWebViewPresentation(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String
    ) {
        guard !containerView.isHidden else { return }

        runHostedWebViewRefreshPass(webView, in: containerView, reason: reason, phase: "immediate")
        DispatchQueue.main.async { [weak self, weak webView, weak containerView] in
            guard let self, let webView, let containerView else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "async"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak webView, weak containerView] in
            guard let self, let webView, let containerView else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "delayed"
            )
        }
    }

    private func moveWebKitRelatedSubviewsIfNeeded(
        from sourceSuperview: NSView,
        to containerView: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        guard sourceSuperview !== containerView else { return }
        // When Web Inspector is docked, WebKit can inject companion WK* subviews
        // next to the primary WKWebView. Move those with the web view so inspector
        // UI state does not get orphaned in the old host during split churn.
        let relatedSubviews = sourceSuperview.subviews.filter { view in
            if view === primaryWebView { return true }
            let className = String(describing: type(of: view))
            guard className.contains("WK") else { return false }
            if className.contains("WKInspector") {
                return !view.isHidden && view.alphaValue > 0 && view.frame.width > 1 && view.frame.height > 1
            }
            return true
        }
        guard !relatedSubviews.isEmpty else { return }
#if DEBUG
        dlog(
            "browser.portal.reparent.batch reason=\(reason) source=\(browserPortalDebugToken(sourceSuperview)) " +
            "container=\(browserPortalDebugToken(containerView)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: containerView))) " +
            "sourceFlipped=\(sourceSuperview.isFlipped ? 1 : 0) targetFlipped=\(containerView.isFlipped ? 1 : 0) " +
            "sourceBounds=\(browserPortalDebugFrame(sourceSuperview.bounds)) targetBounds=\(browserPortalDebugFrame(containerView.bounds))"
        )
#endif
        for view in relatedSubviews {
            let frameInWindow = sourceSuperview.convert(view.frame, to: nil)
            let className = String(describing: type(of: view))
            view.removeFromSuperview()
            containerView.addSubview(view, positioned: .above, relativeTo: nil)
            let convertedFrame = containerView.convert(frameInWindow, from: nil)
            view.frame = convertedFrame
#if DEBUG
            dlog(
                "browser.portal.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(browserPortalDebugToken(view)) frameInWindow=\(browserPortalDebugFrame(frameInWindow)) " +
                "converted=\(browserPortalDebugFrame(convertedFrame))"
            )
#endif
        }
    }

    func detachWebView(withId webViewId: ObjectIdentifier) {
        guard let entry = entriesByWebViewId.removeValue(forKey: webViewId) else { return }
        if let anchor = entry.anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadContainerSuperview = (entry.containerView?.superview === hostView) ? 1 : 0
        let hadWebSuperview = entry.webView?.superview == nil ? 0 : 1
        dlog(
            "browser.portal.detach web=\(browserPortalDebugToken(entry.webView)) " +
            "container=\(browserPortalDebugToken(entry.containerView)) " +
            "anchor=\(browserPortalDebugToken(entry.anchorView)) " +
            "hadContainerSuperview=\(hadContainerSuperview) hadWebSuperview=\(hadWebSuperview)"
        )
#endif
        entry.webView?.browserPortalNotifyHidden(reason: "detach")
        entry.webView?.removeFromSuperview()
        entry.containerView?.removeFromSuperview()
    }

    /// Update the visibleInUI/zPriority state on an existing entry without rebinding.
    /// Used when a bind is deferred (host not yet in window) so stale portal syncs
    /// do not keep an old anchor visible.
    func updateEntryVisibility(forWebViewId webViewId: ObjectIdentifier, visibleInUI: Bool, zPriority: Int) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.visibleInUI != visibleInUI || entry.zPriority != zPriority else { return }
        entry.visibleInUI = visibleInUI
        entry.zPriority = zPriority
        entriesByWebViewId[webViewId] = entry
    }

    func isWebViewBoundToAnchor(withId webViewId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByWebViewId[webViewId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func hideWebView(withId webViewId: ObjectIdentifier, source: String = "externalHide") {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        entry.visibleInUI = false
        entry.zPriority = 0
        entriesByWebViewId[webViewId] = entry
        synchronizeWebView(withId: webViewId, source: source)
    }

    func updateDropZoneOverlay(forWebViewId webViewId: ObjectIdentifier, zone: DropZone?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.dropZone != zone else { return }
        entry.dropZone = zone
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setDropZoneOverlay(zone: zone)
    }

    func updatePaneDropContext(forWebViewId webViewId: ObjectIdentifier, context: BrowserPaneDropContext?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.paneDropContext != context else { return }
        entry.paneDropContext = context
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneDropContext(context)
    }

    func updateSearchOverlay(
        forWebViewId webViewId: ObjectIdentifier,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard !Self.searchOverlayConfigurationsEquivalent(entry.searchOverlay, configuration) else { return }
        entry.searchOverlay = configuration
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setSearchOverlay(configuration)
    }

    func searchOverlayPanelId(for responder: NSResponder) -> UUID? {
        for entry in entriesByWebViewId.values {
            if let panelId = entry.containerView?.searchOverlayPanelId(for: responder) {
                return panelId
            }
        }
        return nil
    }

    @discardableResult
    func yieldSearchOverlayFocusIfOwned(by panelId: UUID) -> Bool {
        guard let window else { return false }
        for entry in entriesByWebViewId.values {
            if entry.containerView?.yieldSearchOverlayFocusIfOwned(by: panelId, in: window) == true {
                return true
            }
        }
        return false
    }

    func updatePaneTopChromeHeight(forWebViewId webViewId: ObjectIdentifier, height: CGFloat) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        let resolvedHeight = max(0, height)
        guard abs(entry.paneTopChromeHeight - resolvedHeight) > 0.5 else { return }
        entry.paneTopChromeHeight = resolvedHeight
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneTopChromeHeight(resolvedHeight)
    }

    func forceRefreshWebView(withId webViewId: ObjectIdentifier, reason: String) {
        guard ensureInstalled() else { return }
        synchronizeWebView(
            withId: webViewId,
            source: "forceRefresh",
            forcePresentationRefresh: true
        )
        guard let entry = entriesByWebViewId[webViewId],
              let webView = entry.webView,
              let containerView = entry.containerView,
              !containerView.isHidden else {
            return
        }
        refreshHostedWebViewPresentation(
            webView,
            in: containerView,
            reason: reason
        )
    }

    func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let webViewId = ObjectIdentifier(webView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByWebViewId[webViewId]
        let containerView = ensureContainerView(
            for: previousEntry ?? Entry(
                webView: nil,
                containerView: nil,
                anchorView: nil,
                visibleInUI: false,
                zPriority: 0,
                dropZone: nil,
                paneDropContext: nil,
                searchOverlay: nil,
                paneTopChromeHeight: 0,
                transientRecoveryReason: nil,
                transientRecoveryRetriesRemaining: 0
            ),
            webView: webView
        )

        if let previousWebViewId = webViewByAnchorId[anchorId], previousWebViewId != webViewId {
#if DEBUG
            let previousToken = entriesByWebViewId[previousWebViewId]
                .map { browserPortalDebugToken($0.webView) }
                ?? String(describing: previousWebViewId)
            dlog(
                "browser.portal.bind.replace anchor=\(browserPortalDebugToken(anchorView)) " +
                "oldWeb=\(previousToken) newWeb=\(browserPortalDebugToken(webView))"
            )
#endif
            detachWebView(withId: previousWebViewId)
        }

        if let oldEntry = entriesByWebViewId[webViewId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        webViewByAnchorId[anchorId] = webViewId
        entriesByWebViewId[webViewId] = Entry(
            webView: webView,
            containerView: containerView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            dropZone: previousEntry?.dropZone,
            paneDropContext: previousEntry?.paneDropContext,
            searchOverlay: previousEntry?.searchOverlay,
            paneTopChromeHeight: previousEntry?.paneTopChromeHeight ?? 0,
            transientRecoveryReason: previousEntry?.transientRecoveryReason,
            transientRecoveryRetriesRemaining: previousEntry?.transientRecoveryRetriesRemaining ?? 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil ||
            didChangeAnchor ||
            becameVisible ||
            priorityIncreased ||
            webView.superview !== containerView ||
            containerView.superview !== hostView {
            dlog(
                "browser.portal.bind web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "anchor=\(browserPortalDebugToken(anchorView)) prevAnchor=\(browserPortalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        if webView.superview !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=attachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "bind.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        } else {
            containerView.pinHostedWebView(webView)
        }

        if containerView.superview !== hostView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=attach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        }

        synchronizeWebView(
            withId: webViewId,
            source: "bind",
            forcePresentationRefresh: didChangeAnchor
        )
        pruneDeadEntries()
    }

    func synchronizeWebViewForAnchor(_ anchorView: NSView) {
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryWebViewId = webViewByAnchorId[anchorId]
        if let primaryWebViewId {
            synchronizeWebView(withId: primaryWebViewId, source: "anchorPrimary")
        }

        synchronizeAllWebViews(excluding: primaryWebViewId, source: "anchorSecondary")
        scheduleDeferredFullSynchronizeAll()
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
#if DEBUG
        dlog("browser.portal.sync.defer.schedule entries=\(entriesByWebViewId.count)")
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
#if DEBUG
            dlog("browser.portal.sync.defer.tick entries=\(self.entriesByWebViewId.count)")
#endif
            self.synchronizeAllWebViews(excluding: nil, source: "deferredTick")
        }
    }

    private func synchronizeAllWebViews(excluding webViewIdToSkip: ObjectIdentifier?, source: String) {
        guard ensureInstalled() else { return }
        pruneDeadEntries()
        let webViewIds = Array(entriesByWebViewId.keys)
        for webViewId in webViewIds {
            if webViewId == webViewIdToSkip { continue }
            synchronizeWebView(withId: webViewId, source: source)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forWebViewId webViewId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 || entry.transientRecoveryReason != nil else { return }
        entry.transientRecoveryReason = nil
        entry.transientRecoveryRetriesRemaining = 0
        entriesByWebViewId[webViewId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forWebViewId webViewId: ObjectIdentifier,
        entry: inout Entry,
        webView: WKWebView,
        reason: String
    ) -> Bool {
        if entry.transientRecoveryReason != reason {
            entry.transientRecoveryReason = reason
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
#if DEBUG
        if entry.transientRecoveryRetriesRemaining <= 0 {
            dlog(
                "browser.portal.sync.deferRecover.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) exhausted=1"
            )
        }
#endif
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByWebViewId[webViewId] = entry
#if DEBUG
        dlog(
            "browser.portal.sync.deferRecover web=\(browserPortalDebugToken(webView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    private func synchronizeWebView(
        withId webViewId: ObjectIdentifier,
        source: String,
        forcePresentationRefresh: Bool = false
    ) {
        guard ensureInstalled() else { return }
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard let webView = entry.webView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            return
        }
        guard let containerView = entry.containerView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            if let anchor = entry.anchorView {
                webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
            }
            return
        }
        func hideContainerView(reason: String) {
            containerView.setPaneTopChromeHeight(0)
            containerView.setSearchOverlay(nil)
            containerView.setDropZoneOverlay(zone: nil)
            if !containerView.isHidden, webView.superview === containerView {
                webView.browserPortalNotifyHidden(reason: reason)
            }
            containerView.isHidden = true
        }
        func scheduleTransientDetachRecovery(reason: String) -> Bool {
            guard entry.visibleInUI else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
        }
        func preserveVisibleDuringTransientDetach(reason: String) -> Bool {
            guard entry.visibleInUI, !containerView.isHidden else { return false }
            let didScheduleTransientRecovery = scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
            guard didScheduleTransientRecovery else { return false }
#if DEBUG
            dlog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) frame=\(browserPortalDebugFrame(containerView.frame))"
            )
#endif
            containerView.setDropZoneOverlay(zone: nil)
            return true
        }
        guard let anchorView = entry.anchorView, let window else {
            if preserveVisibleDuringTransientDetach(reason: "missingAnchorOrWindow") {
                return
            }
            if scheduleTransientDetachRecovery(reason: "missingAnchorOrWindow") {
                hideContainerView(reason: "missingAnchorOrWindow")
                return
            }
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 reason=missingAnchorOrWindow"
                )
            }
#endif
            hideContainerView(reason: "missingAnchorOrWindow")
            return
        }
        guard anchorView.window === window else {
            let isOffWindowReparent =
                entry.visibleInUI &&
                anchorView.window == nil &&
                anchorView.superview != nil
            if isOffWindowReparent {
                if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch.offWindow") {
                    return
                }
                if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                    hideContainerView(reason: "anchorWindowMismatch")
                    return
                }
            }
            if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch") {
                return
            }
            if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                hideContainerView(reason: "anchorWindowMismatch")
                return
            }
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(browserPortalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "anchorWindowMismatch")
            return
        }

        var refreshReasons: [String] = []
        if containerView.superview !== hostView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=syncAttach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
            refreshReasons.append("syncAttachContainer")
        }
        let shouldPreserveExternalHostForHiddenEntry =
            !entry.visibleInUI &&
            webView.superview !== containerView
        if shouldPreserveExternalHostForHiddenEntry {
#if DEBUG
            dlog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=hiddenEntryExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
        } else if webView.superview !== containerView {
#if DEBUG
            dlog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=syncAttachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "sync.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            refreshReasons.append("syncAttachWebView")
        } else {
            containerView.pinHostedWebView(webView)
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            dlog(
                "browser.portal.sync.defer container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) " +
                "reason=hostBoundsNotReady host=\(browserPortalDebugFrame(hostBounds)) " +
                "anchor=\(browserPortalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !containerView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forWebViewId: webViewId,
                        entry: &entry,
                        webView: webView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    dlog(
                        "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                        "reason=hostBoundsNotReady frame=\(browserPortalDebugFrame(containerView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "hostBoundsNotReady")
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forWebViewId: webViewId,
                    entry: &entry,
                    webView: webView,
                    reason: "hostBoundsNotReady"
                )
            } else {
                scheduleDeferredFullSynchronizeAll()
            }
            containerView.setPaneTopChromeHeight(0)
            return
        }
        let oldFrame = containerView.frame
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = hasVisibleIntersection ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame = targetFrame.width <= 1 || targetFrame.height <= 1
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let transientRecoveryReason: String? = {
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !containerView.isHidden
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            dlog(
                "browser.portal.frame.clamp container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "raw=\(browserPortalDebugFrame(frameInHost)) clamped=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            dlog(
                "browser.portal.frame.collapse container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            dlog(
                "browser.portal.frame.restore container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        }
#endif
        if shouldPreserveVisibleOnTransientGeometry {
            let hasExistingVisibleFrame =
                oldFrame.width > 1 &&
                oldFrame.height > 1 &&
                containerView.bounds.width > 1 &&
                containerView.bounds.height > 1
#if DEBUG
            dlog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(browserPortalDebugFrame(containerView.frame)) " +
                "keepFrame=\(hasExistingVisibleFrame ? 1 : 0)"
            )
#endif
            if hasExistingVisibleFrame {
                containerView.setDropZoneOverlay(zone: nil)
                containerView.setPaneDropContext(nil)
                return
            }
        }
        if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.frame = targetFrame
            CATransaction.commit()
            refreshReasons.append("frame")
        }

        let expectedContainerBounds = NSRect(origin: .zero, size: targetFrame.size)
        if !Self.rectApproximatelyEqual(containerView.bounds, expectedContainerBounds) {
            let oldContainerBounds = containerView.bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.bounds = expectedContainerBounds
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.bounds.normalize container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) old=\(browserPortalDebugFrame(oldContainerBounds)) " +
                "target=\(browserPortalDebugFrame(expectedContainerBounds))"
            )
#endif
            refreshReasons.append("bounds")
        }

        let containerOwnsWebView = webView.superview === containerView
        let containerBounds = containerView.bounds
        let preNormalizeWebFrame = containerOwnsWebView ? webView.frame : .zero
        let inspectorHeightFromInsets = max(0, containerBounds.height - preNormalizeWebFrame.height)
        let inspectorHeightFromOverflow = max(0, preNormalizeWebFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorHeightFromInsets, inspectorHeightFromOverflow)
#if DEBUG
        let inspectorSubviews = Self.inspectorSubviewCount(in: containerView)
#endif
        if containerOwnsWebView && Self.frameExtendsOutsideBounds(preNormalizeWebFrame, bounds: containerBounds) {
            let oldWebFrame = preNormalizeWebFrame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = containerBounds
            CATransaction.commit()
#if DEBUG
            dlog(
                "browser.portal.webframe.normalize web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) old=\(browserPortalDebugFrame(oldWebFrame)) " +
                "new=\(browserPortalDebugFrame(webView.frame)) bounds=\(browserPortalDebugFrame(containerBounds)) " +
                "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
                "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
                "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
                "inspectorSubviews=\(inspectorSubviews) " +
                "source=\(source)"
            )
#endif
            refreshReasons.append("webFrame")
        }

        let revealedForDisplay = !shouldHide && containerView.isHidden
        if shouldHide, !containerView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=\(shouldHide ? 1 : 0) " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                    "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                    "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            hideContainerView(reason: transientRecoveryReason ?? "geometryHidden")
        } else if !shouldHide, containerView.isHidden {
#if DEBUG
            dlog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            containerView.isHidden = false
        }
        containerView.setPaneTopChromeHeight(shouldHide ? 0 : entry.paneTopChromeHeight)
        containerView.setSearchOverlay(shouldHide ? nil : entry.searchOverlay)
        containerView.setDropZoneOverlay(zone: containerView.isHidden ? nil : entry.dropZone)
        if revealedForDisplay {
            refreshReasons.append("reveal")
        }
        if forcePresentationRefresh {
            refreshReasons.append("anchor")
        }
        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
        }
        let hostedInspectorAdjustedDuringSync =
            containerOwnsWebView &&
            hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync")
        if !shouldHide, containerOwnsWebView, !refreshReasons.isEmpty {
            if hostedInspectorAdjustedDuringSync {
#if DEBUG
                dlog(
                    "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                    "container=\(browserPortalDebugToken(containerView)) reason=\(source):" +
                    "\(refreshReasons.joined(separator: ",")) adjustedDuringSync=1"
                )
#endif
            } else {
                refreshHostedWebViewPresentation(
                    webView,
                    in: containerView,
                    reason: "\(source):" + refreshReasons.joined(separator: ",")
                )
            }
        }
        if containerOwnsWebView, !hostedInspectorAdjustedDuringSync {
            // Keep the existing post-sync pass for cases where the inspector candidate
            // appears only after WebKit settles, but avoid a second apply when sync already clamped it.
            _ = hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync.postRefresh")
        }
#if DEBUG
        dlog(
            "browser.portal.sync.result web=\(browserPortalDebugToken(webView)) source=\(source) " +
            "container=\(browserPortalDebugToken(containerView)) " +
            "anchor=\(browserPortalDebugToken(anchorView)) host=\(browserPortalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(browserPortalDebugFrame(oldFrame)) raw=\(browserPortalDebugFrame(frameInHost)) " +
            "target=\(browserPortalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) " +
            "containerOwnsWeb=\(containerOwnsWebView ? 1 : 0) " +
            "inspectorAdjusted=\(hostedInspectorAdjustedDuringSync ? 1 : 0) " +
            "containerHidden=\(containerView.isHidden ? 1 : 0) webHidden=\(webView.isHidden ? 1 : 0) " +
            "containerBounds=\(browserPortalDebugFrame(containerView.bounds)) " +
            "preWebFrame=\(browserPortalDebugFrame(preNormalizeWebFrame)) " +
            "webFrame=\(browserPortalDebugFrame(webView.frame)) webBounds=\(browserPortalDebugFrame(webView.bounds)) " +
            "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
            "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
            "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
            "inspectorSubviews=\(inspectorSubviews)"
        )
#endif
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadWebViewIds = entriesByWebViewId.compactMap { webViewId, entry -> ObjectIdentifier? in
            guard entry.webView != nil else { return webViewId }
            guard let container = entry.containerView else { return webViewId }
            guard let anchor = entry.anchorView else {
                // Workspace switching hides retiring browser portals before SwiftUI unmounts
                // their anchor views. Keep the hidden WKWebView/slot alive so switching back
                // can rebind the existing view instead of forcing a full WebKit reload.
                return nil
            }
            if container.superview == nil || !container.isDescendant(of: hostView) {
                return webViewId
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // Hidden browser portals can legitimately be off-tree between workspace
                // deactivation and the next rebind. Preserve them until an explicit detach
                // (panel close, window teardown, or web view replacement) says otherwise.
                return nil
            }
            return nil
        }

        for webViewId in deadWebViewIds {
            detachWebView(withId: webViewId)
        }

        let validAnchorIds = Set(entriesByWebViewId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        webViewByAnchorId = webViewByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func webViewIds() -> Set<ObjectIdentifier> {
        Set(entriesByWebViewId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for webViewId in Array(entriesByWebViewId.keys) {
            detachWebView(withId: webViewId)
        }
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    func debugEntryCount() -> Int {
        entriesByWebViewId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

    func debugSnapshot(forWebViewId webViewId: ObjectIdentifier) -> BrowserWindowPortalRegistry.DebugSnapshot? {
        guard let entry = entriesByWebViewId[webViewId] else { return nil }
        let frameInWindow: CGRect = {
            guard let container = entry.containerView, container.window != nil else { return .zero }
            return container.convert(container.bounds, to: nil)
        }()
        return BrowserWindowPortalRegistry.DebugSnapshot(
            visibleInUI: entry.visibleInUI,
            containerHidden: entry.containerView?.isHidden ?? true,
            frameInWindow: frameInWindow
        )
    }

    func webViewAtWindowPoint(_ windowPoint: NSPoint) -> WKWebView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)
        for subview in hostView.subviews.reversed() {
            guard let container = subview as? WindowBrowserSlotView else { continue }
            guard !container.isHidden else { continue }
            guard container.frame.contains(point) else { continue }
            guard let webView = entriesByWebViewId
                .first(where: { _, entry in entry.containerView === container })?
                .value
                .webView else { continue }
            return webView
        }
        return nil
    }
}

@MainActor
enum BrowserWindowPortalRegistry {
    struct DebugSnapshot {
        let visibleInUI: Bool
        let containerHidden: Bool
        let frameInWindow: CGRect
    }

    private static var portalsByWindowId: [ObjectIdentifier: WindowBrowserPortal] = [:]
    private static var webViewToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &cmuxWindowBrowserPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        webViewToWindowId = webViewToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneWebViewMappings(for windowId: ObjectIdentifier, validWebViewIds: Set<ObjectIdentifier>) {
        webViewToWindowId = webViewToWindowId.filter { webViewId, mappedWindowId in
            mappedWindowId != windowId || validWebViewIds.contains(webViewId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowBrowserPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowBrowserPortalKey) as? WindowBrowserPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowBrowserPortal(window: window)
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    static func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let webViewId = ObjectIdentifier(webView)
        let nextPortal = portal(for: window)

        if let oldWindowId = webViewToWindowId[webViewId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachWebView(withId: webViewId)
        }

        nextPortal.bind(webView: webView, to: anchorView, visibleInUI: visibleInUI, zPriority: zPriority)
        webViewToWindowId[webViewId] = windowId
        pruneWebViewMappings(for: windowId, validWebViewIds: nextPortal.webViewIds())
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeWebViewForAnchor(anchorView)
    }

    /// Update visibleInUI/zPriority on an existing portal entry without rebinding.
    /// Called when a bind is deferred because the new host is temporarily off-window.
    static func updateEntryVisibility(for webView: WKWebView, visibleInUI: Bool, zPriority: Int) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forWebViewId: webViewId, visibleInUI: visibleInUI, zPriority: zPriority)
    }

    static func isWebView(_ webView: WKWebView, boundTo anchorView: NSView) -> Bool {
        let webViewId = ObjectIdentifier(webView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard webViewToWindowId[webViewId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
        return portal.isWebViewBoundToAnchor(withId: webViewId, anchorView: anchorView)
    }

    static func hide(webView: WKWebView, source: String = "externalHide") {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideWebView(withId: webViewId, source: source)
    }

    static func updateDropZoneOverlay(for webView: WKWebView, zone: DropZone?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateDropZoneOverlay(forWebViewId: webViewId, zone: zone)
    }

    static func updatePaneDropContext(for webView: WKWebView, context: BrowserPaneDropContext?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneDropContext(forWebViewId: webViewId, context: context)
    }

    static func updateSearchOverlay(
        for webView: WKWebView,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateSearchOverlay(forWebViewId: webViewId, configuration: configuration)
    }

    static func searchOverlayPanelId(for responder: NSResponder, in window: NSWindow) -> UUID? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.searchOverlayPanelId(for: responder)
    }

    @discardableResult
    static func yieldSearchOverlayFocusIfOwned(by panelId: UUID, in window: NSWindow) -> Bool {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return false }
        return portal.yieldSearchOverlayFocusIfOwned(by: panelId)
    }

    static func updatePaneTopChromeHeight(for webView: WKWebView, height: CGFloat) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneTopChromeHeight(forWebViewId: webViewId, height: height)
    }

    static func detach(webView: WKWebView) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId) else { return }
        portalsByWindowId[windowId]?.detachWebView(withId: webViewId)
    }

    static func webViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> WKWebView? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.webViewAtWindowPoint(windowPoint)
    }

    static func refresh(webView: WKWebView, reason: String) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.forceRefreshWebView(withId: webViewId, reason: reason)
    }

    static func debugSnapshot(for webView: WKWebView) -> DebugSnapshot? {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return nil }
        return portal.debugSnapshot(forWebViewId: webViewId)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}
