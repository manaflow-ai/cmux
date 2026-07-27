import AppKit
import ObjectiveC
import CmuxAppKitSupportUI
import CmuxTerminal
#if DEBUG
import Bonsplit
#endif

private var cmuxWindowTerminalPortalKey: UInt8 = 0
private var cmuxWindowTerminalPortalCloseObserverKey: UInt8 = 0

final class WindowTerminalHostView: NSView {
    private typealias DividerRegion = PortalSplitDividerRegion
    private typealias DividerCursorKind = PortalDividerCursorKind

    override var isOpaque: Bool { false }
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var cachedSplitDividerRegions: [DividerRegion]?
    private var cachedSplitDividerRootSubviewIds: [ObjectIdentifier]?
    private let splitDividerCacheInvalidator = PortalSplitDividerCacheInvalidator()
    private var splitDividerResizeObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
    private let dividerCursorOcclusion = PortalDividerCursorOcclusion()
    let paneDropRoutingSession = PaneDropRoutingSession()
#if DEBUG
    private var lastDragRouteSignature: String?
#endif

    deinit {
        if let splitDividerResizeObserver { NotificationCenter.default.removeObserver(splitDividerResizeObserver) }
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
        updateSplitDividerResizeObserver()
        invalidateSplitDividerRegionCache()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateSplitDividerRegionCache()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        invalidateSplitDividerRegionCache()
        window?.invalidateCursorRects(for: self)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        invalidateSplitDividerRegionCache()
        window?.invalidateCursorRects(for: self)
    }

    override func willRemoveSubview(_ subview: NSView) {
        invalidateSplitDividerRegionCache()
        window?.invalidateCursorRects(for: self)
        super.willRemoveSubview(subview)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        invalidateSplitDividerRegionCache()
        let regions = splitDividerRegions()
        let expansion = PortalSplitDividerRegion.dividerHitExpansion
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
        updateDividerCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateDividerCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearActiveDividerCursor(restoreArrow: true)
    }

    // PERF: hitTest is called on EVERY event including keyboard. Keep non-pointer
    // path minimal. Do not add work outside the input-routing guard.
    override func hitTest(_ point: NSPoint) -> NSView? {
        performHitTest(at: point, currentEvent: NSApp.currentEvent)
    }

    // Test seam: production calls read `NSApp.currentEvent`; tests pass a
    // synthetic pointer event so the typing-latency guard doesn't gate them out.
    func performHitTest(at point: NSPoint, currentEvent: NSEvent?) -> NSView? {
        let routingContext = WindowInputRoutingContext(event: currentEvent)
        let eventType = routingContext.eventType

        if routingContext.allowsPortalPointerHitTesting {
            let resolveHostedTerminalHitView = hostedTerminalHitViewResolver(at: point)

            if shouldPassThroughToTitlebar(at: point, hostedTerminalHitView: resolveHostedTerminalHitView) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            if shouldPassThroughToPaneTabBar(at: point, eventType: currentEvent?.type, hostedTerminalHitView: resolveHostedTerminalHitView) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            if shouldPassThroughToSidebarResizer(at: point) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            if let kind = splitDividerCursorKind(at: point) {
                assertDividerCursor(kind)
                TerminalWindowPortalRegistry.noteSplitDividerInteraction(in: window, event: currentEvent)
                return nil
            }

            clearActiveDividerCursor(restoreArrow: true)
            if routingContext.allowsTerminalPortalDragRouting,
               routingContext.eventKind != .pointerUp || hasActivePaneDropDrag || AppDelegate.shared?.sidebarWorkspaceDragRegistry.currentWorkspaceId != nil {
                let dragPasteboardTypes = NSPasteboard(name: .drag).types
                let shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                    pasteboardTypes: dragPasteboardTypes,
                    eventType: eventType, hasActiveDropDrag: hasActivePaneDropDrag || AppDelegate.shared?.sidebarWorkspaceDragRegistry.currentWorkspaceId != nil
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

    private func shouldPassThroughToTitlebar(at point: NSPoint, hostedTerminalHitView: () -> NSView?) -> Bool {
        guard let window else { return false }
        let windowPoint = convert(point, to: nil)
        guard windowPoint.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window) else {
            return false
        }
        if isMinimalModeTitlebarControlHit(window: window, locationInWindow: windowPoint) { return true }

        // The portal can overlap the titlebar interaction band when terminal content
        // reaches the top of the viewport. In that case the terminal remains the
        // concrete UI target, so mouse reporting must reach Ghostty instead of
        // falling through to window chrome.
        return hostedTerminalHitView() == nil
    }

    private func shouldPassThroughToPaneTabBar(
        at point: NSPoint,
        eventType: NSEvent.EventType?,
        hostedTerminalHitView: () -> NSView?
    ) -> Bool {
        guard let decision = BonsplitTabBarPassThrough.passThroughDecision(
            at: point,
            in: self,
            eventType: eventType
        ) else { return false }
        guard decision.result else { return false }
        if decision.registryHit { return true }
        return hostedTerminalHitView() == nil
    }

    private func shouldPassThroughToChrome(at point: NSPoint, eventType: NSEvent.EventType?) -> Bool {
        let resolveHostedTerminalHitView = hostedTerminalHitViewResolver(at: point)

        return shouldPassThroughToTitlebar(at: point, hostedTerminalHitView: resolveHostedTerminalHitView)
            || shouldPassThroughToPaneTabBar(at: point, eventType: eventType, hostedTerminalHitView: resolveHostedTerminalHitView)
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
        assertDividerCursor(nextKind)
    }

    // A registry-latched divider drag owned by this window bypasses occlusion; a pressed button alone is not ownership.
    private func assertDividerCursor(_ kind: DividerCursorKind) {
        guard TerminalWindowPortalRegistry.isSplitDividerDragActive(in: window)
            || dividerCursorOcclusion.mayAssertDividerCursor(in: window) else {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }
        activeDividerCursorKind = kind
        kind.cursor.set()
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
        guard window != nil else { return nil }
        return Self.dividerCursorKind(at: convert(point, to: nil), in: splitDividerRegions(), checkLiveness: false)
    }

    static func hasSplitDivider(atScreenPoint screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let regions = PortalSplitDividerRegion.collect(in: rootView).regions
        return dividerCursorKind(at: windowPoint, in: regions) != nil
    }

    private func splitDividerRegions() -> [DividerRegion] {
        guard let window, let rootView = window.contentView else { cachedSplitDividerRegions = []; cachedSplitDividerRootSubviewIds = nil; return [] }
        let rootSubviewIds = rootView.subviews.map { ObjectIdentifier($0) }
        if let regions = cachedSplitDividerRegions, cachedSplitDividerRootSubviewIds == rootSubviewIds, PortalSplitDividerRegion.allLive(regions) { return regions }
        let collected = PortalSplitDividerRegion.collect(in: rootView)
        cachedSplitDividerRegions = collected.regions
        cachedSplitDividerRootSubviewIds = rootSubviewIds
        splitDividerCacheInvalidator.observe(
            geometryViews: collected.geometryObservedViews,
            structureViews: collected.structureObservedViews
        ) { [weak self] in
            guard let self else { return }
            self.invalidateSplitDividerRegionCache()
            self.window?.invalidateCursorRects(for: self)
        }
        return collected.regions
    }

    private func invalidateSplitDividerRegionCache() {
        cachedSplitDividerRegions = nil
        cachedSplitDividerRootSubviewIds = nil
        splitDividerCacheInvalidator.invalidate()
    }

    private func updateSplitDividerResizeObserver() {
        if let splitDividerResizeObserver {
            NotificationCenter.default.removeObserver(splitDividerResizeObserver)
            self.splitDividerResizeObserver = nil
        }
        guard let window else { return }
        splitDividerResizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self, weak window] notification in
            guard let self,
                  let window,
                  let splitView = notification.object as? NSSplitView,
                  splitView.window === window else { return }
            self.invalidateSplitDividerRegionCache()
            self.window?.invalidateCursorRects(for: self)
        }
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in regions: [DividerRegion], checkLiveness: Bool = true) -> DividerCursorKind? {
        for region in regions.reversed() {
            if checkLiveness, !region.isLive { continue }
            let hitRect = region.hitRectInWindow
            if !hitRect.isNull, hitRect.contains(windowPoint) {
                return region.isVertical ? .vertical : .horizontal
            }
        }
        return nil
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

private final class SplitDividerOverlayView: NSView {
    private struct DividerSegment {
        let rect: NSRect
        let color: NSColor
        let isVertical: Bool
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, let rootView = window.contentView else { return }

        var dividerSegments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &dividerSegments)
        guard !dividerSegments.isEmpty else { return }
        let hostedFrames = hostedFramesLikelyToOccludeDividers()
        let visibleSegments = dividerSegments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }
        guard !visibleSegments.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Keep separators visible above portal-hosted surfaces while matching each split view's
        // native divider color (avoids visible color shifts at tiny pane sizes).
        for segment in visibleSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            let rect = segment.rect
            let pixelAligned = NSRect(
                x: floor(rect.origin.x),
                y: floor(rect.origin.y),
                width: max(1, round(rect.size.width)),
                height: max(1, round(rect.size.height))
            )
            NSBezierPath(rect: pixelAligned).fill()
        }
    }

    private func collectDividerSegments(in view: NSView, into result: inout [DividerSegment]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            let dividerColor = overlayDividerColor(for: splitView)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let thickness = max(splitView.dividerThickness, 1)
                let dividerRectInSplit: NSRect
                if splitView.isVertical {
                    dividerRectInSplit = NSRect(
                        x: first.maxX,
                        y: 0,
                        width: thickness,
                        height: splitView.bounds.height
                    )
                } else {
                    dividerRectInSplit = NSRect(
                        x: 0,
                        y: first.maxY,
                        width: splitView.bounds.width,
                        height: thickness
                    )
                }

                let dividerRectInWindow = splitView.convert(dividerRectInSplit, to: nil)
                let dividerRectInOverlay = convert(dividerRectInWindow, from: nil)
                if dividerRectInOverlay.intersects(bounds) {
                    result.append(
                        DividerSegment(
                            rect: dividerRectInOverlay,
                            color: dividerColor,
                            isVertical: splitView.isVertical
                        )
                    )
                }
            }
        }

        for subview in view.subviews {
            collectDividerSegments(in: subview, into: &result)
        }
    }

    private func hostedFramesLikelyToOccludeDividers() -> [NSRect] {
        guard let hostView = superview else { return [] }
        return hostView.subviews.compactMap { subview -> NSRect? in
            guard let hosted = subview as? GhosttySurfaceScrollView else { return nil }
            guard !hosted.isHidden, hosted.window != nil else { return nil }
            return hosted.frame
        }
    }

    private func shouldRenderOverlay(for segment: DividerSegment, hostedFrames: [NSRect]) -> Bool {
        // Draw only when a hosted surface actually intrudes across the divider centerline.
        // This preserves tiny-pane visibility fixes without darkening regular dividers.
        let axisEpsilon: CGFloat = 0.01
        let axis = segment.isVertical ? segment.rect.midX : segment.rect.midY
        let extentRect = segment.rect.insetBy(
            dx: segment.isVertical ? 0 : -1,
            dy: segment.isVertical ? -1 : 0
        )

        for frame in hostedFrames where frame.intersects(extentRect) {
            if segment.isVertical {
                if frame.minX < axis - axisEpsilon && frame.maxX > axis + axisEpsilon {
                    return true
                }
            } else if frame.minY < axis - axisEpsilon && frame.maxY > axis + axisEpsilon {
                return true
            }
        }
        return false
    }

    private func overlayDividerColor(for splitView: NSSplitView) -> NSColor {
        let divider = splitView.dividerColor.usingColorSpace(.deviceRGB) ?? splitView.dividerColor
        let alpha = divider.alphaComponent
        guard alpha < 0.999 else { return divider }

        guard let bgColor = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
              let bgRGB = bgColor.usingColorSpace(.deviceRGB) else {
            return divider
        }

        let opaqueBG = bgRGB.withAlphaComponent(1)
        let opaqueDivider = divider.withAlphaComponent(1)
        return opaqueBG.blended(withFraction: alpha, of: opaqueDivider) ?? divider
    }
}

@MainActor
final class WindowTerminalPortal: NSObject {
#if DEBUG
    static var isPointerDragActiveForTesting = false
    /// Instance-scoped so a test drives only its own portal's live-resize
    /// path; a process-wide static latched interactive state across the shared
    /// app-host and made one test's setting leak into every later portal.
    var isWindowLiveResizeActiveOverrideForTesting = false
#endif
    static let tinyHideThreshold: CGFloat = 1
    private static let minimumRevealWidth: CGFloat = 24
    private static let minimumRevealHeight: CGFloat = 18
    private static let transientRecoveryRetryBudget: Int = 12
#if CMUX_ISSUE_483_PORTAL_RECOVERY
    private static let transientRecoveryEnabled = true
#else
    private static let transientRecoveryEnabled = false
#endif

    weak var window: NSWindow?
    let hostView = WindowTerminalHostView(frame: .zero)
    private let dividerOverlayView = SplitDividerOverlayView(frame: .zero)
    private let chromeComposition = AppWindowChromeComposition()
    private weak var installedContainerView: NSView?
    weak var installedReferenceView: NSView?
    private var referenceGeometryObservers: [NSObjectProtocol] = []
    private var hasDeferredFullSyncScheduled = false
    private var deferredFullSyncIncludesVisibleReconcile = false
    /// Set by ContentView's sidebar dispatcher — the flag's single
    /// evaluation site — when the AppKit sidebar branch mounts. The portal
    /// consumes a plain bool so the feature-flag lint's one-file rule holds.
    static var usesCoalescedAnchorFailsafe = false
    /// Surface redraws requested by a sync that ran inside someone else's
    /// layout/update pass (syncLayout == false). displayIfNeeded there reaches
    /// ghostty's Metal drawFrame while the window's transaction is still open,
    /// and waitUntilCompleted then waits on a present that only that
    /// transaction can commit — the main thread wedges permanently. These
    /// drain on the next main-queue turn instead.
    private var pendingDeferredSurfaceRefreshes: [ObjectIdentifier: String] = [:]
    private var hasDeferredSurfaceRefreshScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    private var pendingExternalGeometrySyncRequiresImmediate = false
    /// True while some request since the last executed pass asked for the
    /// non-immediate contract (one extra main-queue hop before the pass reads
    /// geometry) and has not yet received it. Requests fold into whichever
    /// pass is already scheduled, so this must be tracked across the fold:
    /// a non-immediate request folded into an immediately-scheduled pass
    /// (or flushed early by a folded immediate request) would otherwise lose
    /// its hop silently, leaving the portal parked at geometry read before a
    /// same-turn queued layout mutation landed.
    private var pendingExternalGeometrySyncHasDeferredRequest = false
    private var externalGeometrySyncGeneration: UInt64 = 0
    private var geometryObservers: [NSObjectProtocol] = []
    /// Nonzero while the portal itself writes a frame it owns (the host
    /// view, a hosted view's seed or target frame). NSView posts its
    /// frame/bounds notifications synchronously on the posting thread, so a
    /// geometry notification observed while this is held is the echo of the
    /// portal's own write — it must not re-arm the sync. The signature
    /// guard alone cannot end a stationary two-state disagreement (A,B,A,B
    /// never matches the last signature), so without this token the
    /// portal's own writes kept the sync loop fed forever.
    private var selfFrameWriteDepth = 0
#if DEBUG
    private var lastLoggedBonsplitContainerSignature: String?
    private var lastObservedWindowSize: NSSize?
    /// Every sync request this portal receives (including in-pass marks and
    /// follow-up re-schedules) — the re-arm observable for the self-write
    /// echo test: an external stomp must cost exactly one request, with the
    /// restoring write's own notifications buying zero more.
    var externalGeometrySyncRequestCountForTesting = 0
#endif

    struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var transientRecoveryRetriesRemaining: Int
    }

    var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]
    /// Hosted views arrive from SwiftUI hosting with a flexible autoresizing
    /// mask; adoption clears it (see bind) and detach restores this saved
    /// value so the view resumes its normal AppKit life.
    private var preAdoptionAutoresizingMaskByHostedId: [ObjectIdentifier: NSView.AutoresizingMask] = [:]

    deinit {
        // tearDown() removes these when a window closes normally, but a
        // portal can also die without ever seeing willCloseNotification (its
        // window is deallocated while open, or a test owns the portal
        // directly). NotificationCenter retains block observers until they
        // are removed, so a skipped removal leaks them permanently — and the
        // object:nil split-view observer among them then runs for every
        // split-view resize in the process, forever.
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in referenceGeometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // Adoption clears each hosted view's autoresizing mask (see bind) and
        // detach restores the saved one. A portal that dies without tearDown()
        // /detachHostedView never restores them, so a surviving hosted view is
        // left pinned at [] and the NEXT portal saves [] as its "original".
        // Restore inline — deinit cannot hop to the @MainActor detach path. Portal ownership
        // is main-actor-bound through the registry, NSWindow association, and test callers.
        MainActor.assumeIsolated {
            for (hostedId, mask) in preAdoptionAutoresizingMaskByHostedId {
                entriesByHostedId[hostedId]?.hostedView?.autoresizingMask = mask
            }
        }
    }

    init(window: NSWindow, syncLayout: Bool = true) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        // Frame-based on purpose (see ensureInstalled): the portal owns
        // hostView.frame and writes it from the reference's ACTUAL bounds.
        // Autoresizing keeps the host tracking container resizes within the
        // same layout pass (a window live-resize tick) — it reads actual
        // frames, so unlike the old edge constraints it cannot deliver a
        // layout-engine solution the reference refuses to hold.
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.autoresizingMask = [.width, .height]
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        installGeometryObservers(for: window)
        _ = ensureInstalled(syncLayout: syncLayout)
    }

    /// Runs `body` with the self-write token held, so the frame/bounds
    /// notifications the write posts (synchronously, same thread) cannot
    /// re-arm the portal's own sync. Only genuinely external geometry —
    /// notifications arriving with no portal write on the stack — schedules
    /// a pass.
    private func performSelfFrameWrite<T>(_ body: () -> T) -> T {
        selfFrameWriteDepth += 1
        defer { selfFrameWriteDepth -= 1 }
        return body()
    }

    private func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
#if DEBUG
                // Standing tripwire for PROGRAMMATIC window growth — the
                // ever-growing-terminal's signature. didResize posts
                // synchronously inside setFrame, so the stack names the
                // resizer. User-driven live resizes are skipped entirely:
                // symbolicating a stack per tick is exactly the kind of
                // observer-chain work that made live resizes sluggish.
                if let self, let resized = notification.object as? NSWindow, !resized.inLiveResize {
                    let old = self.lastObservedWindowSize
                    let new = resized.frame.size
                    if old == nil || abs(old!.width - new.width) > 0.5 || abs(old!.height - new.height) > 0.5 {
                        self.lastObservedWindowSize = new
                        if let old {
                            let stack = Thread.callStackSymbols.dropFirst(2).prefix(8).joined(separator: " | ")
                            cmuxDebugLog(
                                "window.resize.tripwire \(Int(old.width))x\(Int(old.height))->\(Int(new.width))x\(Int(new.height)) live=0 \(stack)"
                            )
                        }
                    }
                }
#endif
                guard let self, self.selfFrameWriteDepth == 0 else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selfFrameWriteDepth == 0 else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      self.selfFrameWriteDepth == 0,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      splitView.window === window else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selfFrameWriteDepth == 0 else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selfFrameWriteDepth == 0 else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
        removeReferenceGeometryObservers()
    }

    /// hostView is frame-managed by the portal (see ensureInstalled), so a
    /// reference resize that moves no anchor would otherwise leave hostView
    /// stale until the next unrelated sync. These observers are the
    /// notification form of the glue the old edge constraints provided —
    /// minus the engine coupling those constraints created.
    private func installReferenceGeometryObservers(reference: NSView) {
        removeReferenceGeometryObservers()
        reference.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        referenceGeometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: reference,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selfFrameWriteDepth == 0 else { return }
                self.scheduleExternalGeometrySynchronize(forceImmediate: false)
            }
        })
    }

    private func removeReferenceGeometryObservers() {
        for observer in referenceGeometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        referenceGeometryObservers.removeAll()
    }

    fileprivate func scheduleExternalGeometrySynchronize() {
        scheduleExternalGeometrySynchronize(forceImmediate: true)
    }

    /// True while the hosting window is in an interactive live resize
    /// (title-bar/edge drag). Split-divider drags are deliberately NOT
    /// window live resizes — they keep the immediate per-callback sync path.
    private var isWindowLiveResizeActive: Bool {
#if DEBUG
        if isWindowLiveResizeActiveOverrideForTesting { return true }
#endif
        return hostView.inLiveResize || window?.inLiveResize == true
    }

    /// The portal whose sync pass is currently on the stack, if any. A
    /// request arriving for THAT portal during its own pass is not dropped
    /// — a pass's layout can produce genuinely new geometry (an imposed
    /// divider correction rides the pass's layoutSubtreeIfNeeded, and its
    /// notification arrives mid-pass) — it marks a follow-up that the pass
    /// schedules on exit. Requests for OTHER portals proceed normally.
    /// Dropping mid-pass requests outright left the final correction
    /// unapplied forever: the last write predated the settle window and
    /// nothing ever scheduled again. Termination is unchanged: a follow-up
    /// whose geometry matches the fingerprint does no layout and emits no
    /// notifications, so the chain stops one pass after geometry stops.
    private static var currentlySynchronizingPortalId: ObjectIdentifier?
    private var resyncRequestedDuringPass = false

    fileprivate func scheduleExternalGeometrySynchronize(forceImmediate: Bool) {
#if DEBUG
        externalGeometrySyncRequestCountForTesting += 1
#endif
        if Self.currentlySynchronizingPortalId == ObjectIdentifier(self) {
            resyncRequestedDuringPass = true
            return
        }
        // Coalesce to the latest request so ancestor/frame churn (for example
        // sidebar toggles) doesn't resize the PTY at stale intermediate widths.
        externalGeometrySyncGeneration &+= 1
        let generation = externalGeometrySyncGeneration
        if !forceImmediate {
            pendingExternalGeometrySyncHasDeferredRequest = true
        }
        guard !hasExternalGeometrySyncScheduled else {
            pendingExternalGeometrySyncRequiresImmediate =
                pendingExternalGeometrySyncRequiresImmediate || forceImmediate
            return
        }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let performSync = {
                var shouldFlushLatestNow = forceImmediate
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.pendingExternalGeometrySyncRequiresImmediate
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.hostView.inLiveResize
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.window?.inLiveResize == true
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: self.window)
                }
                // During sidebar/split drags, new geometry requests can arrive
                // faster than this queued sync runs. Flush the latest visible
                // frame instead of rescheduling behind the drag stream.
                if self.externalGeometrySyncGeneration != generation, !shouldFlushLatestNow {
                    self.hasExternalGeometrySyncScheduled = false
                    let followUpRequiresImmediate = self.pendingExternalGeometrySyncRequiresImmediate
                    self.pendingExternalGeometrySyncRequiresImmediate = false
                    self.scheduleExternalGeometrySynchronize(forceImmediate: followUpRequiresImmediate)
                    return
                }
                self.hasExternalGeometrySyncScheduled = false
                self.pendingExternalGeometrySyncRequiresImmediate = false
                let hadDeferredRequest = self.pendingExternalGeometrySyncHasDeferredRequest
                self.pendingExternalGeometrySyncHasDeferredRequest = false
                self.synchronizeAllEntriesFromExternalGeometryChange()
                // A flushed pass ran without the extra hop some folded request
                // was promised, so its geometry may predate a same-turn queued
                // layout mutation. One follow-up pass honors that contract; if
                // the flush already saw final geometry the follow-up dies in
                // the fingerprint check as a no-op, so the chain stops one
                // pass after geometry stops.
                if hadDeferredRequest, shouldFlushLatestNow {
                    self.scheduleExternalGeometrySynchronize(forceImmediate: false)
                }
            }
            var shouldPerformNow = forceImmediate
            if !shouldPerformNow {
                shouldPerformNow = self.pendingExternalGeometrySyncRequiresImmediate
            }
            if !shouldPerformNow {
                shouldPerformNow = self.hostView.inLiveResize
            }
            if !shouldPerformNow {
                shouldPerformNow = self.window?.inLiveResize == true
            }
            if !shouldPerformNow {
                shouldPerformNow = TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: self.window)
            }
            if shouldPerformNow {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    private func synchronizeLayoutHierarchy() {
        // Idempotence at the choke point. Several paths funnel here (window
        // notifications, anchor geometry callbacks, deferred full syncs,
        // transient recovery), each forcing subtree layout — and each layout
        // pass emits the notifications and callbacks that re-enter those
        // same paths, possibly delivered after any in-pass flag is down.
        // When everything this pass reads and writes is unchanged since the
        // last completed pass, the pass is a no-op: skip the layout storm
        // and the echo dies here, whichever path carried it. AppKit still
        // runs pending inner layout before display on its own.
        let signature = externalGeometrySignature()
        if let last = lastHierarchySyncSignature, last == signature { return }
#if DEBUG
        RemoteTmuxSizingDiagnostics.fullHierarchySyncCount += 1
#endif
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
        lastHierarchySyncSignature = externalGeometrySignature()
    }

    private var lastHierarchySyncSignature: ExternalGeometrySignature?

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
            performSelfFrameWrite {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hostView.frame = frameInContainer
                CATransaction.commit()
            }
#if DEBUG
            cmuxDebugLog(
                "portal.hostFrame.update host=\(portalDebugToken(hostView)) " +
                "frame=\(portalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    fileprivate func synchronizeAllEntriesFromExternalGeometryChange() {
        if let activePortalId = Self.currentlySynchronizingPortalId {
            if activePortalId == ObjectIdentifier(self) {
                // Our own pass is on the stack (a re-entrant main-queue drain
                // during its layout fired the queued block). Mark the follow-up
                // the pass schedules on exit.
                resyncRequestedDuringPass = true
            } else {
                // A DIFFERENT portal's pass is on the stack. The scheduling
                // flag is already down by the time performSync calls here, so
                // returning without rescheduling would drop the request
                // forever and leave this portal parked at stale geometry.
                // Re-queue it to run after the current pass unwinds.
                scheduleExternalGeometrySynchronize(forceImmediate: false)
            }
            return
        }
        Self.currentlySynchronizingPortalId = ObjectIdentifier(self)
#if DEBUG
        RemoteTmuxSizingDiagnostics.externalGeometrySyncPassCount += 1
#endif
        defer {
            Self.currentlySynchronizingPortalId = nil
            if resyncRequestedDuringPass {
                resyncRequestedDuringPass = false
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleExternalGeometrySynchronize(forceImmediate: false)
                }
            }
        }
        // Content-based echo cut. A sync pass lays out hosted split views
        // and writes hostView.frame, and the notifications those emit can
        // be DELIVERED AFTER the pass ends (block observers on .main), so
        // no in-pass flag can catch them all — the sync then re-runs
        // forever on identical geometry, pinning the main thread. An echo
        // carries the exact geometry the last pass left behind, so it dies
        // here in one cheap comparison; any real change differs somewhere
        // and syncs fully.
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        synchronizeAllHostedViews(excluding: nil)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.externalGeometrySync")
    }

#if DEBUG
    /// Stomp forensics for the frame ping-pong class: when the portal finds
    /// a hosted view moved off the portal's own last write, some other
    /// writer re-applied a different solution between portal passes. The
    /// engine is the usual suspect, and which constraints fed its solution
    /// is the fact the post-mortems keep having to infer — so capture it
    /// live, at the moment of the miss, rate-limited.
    private var lastPortalTargetByHostedId: [ObjectIdentifier: NSRect] = [:]
    private var stompDiagnosticsBudget = 12

    private func logStompDiagnostics(
        hostedView: GhosttySurfaceScrollView,
        oldFrame: NSRect,
        lastTarget: NSRect,
        targetFrame: NSRect
    ) {
        guard stompDiagnosticsBudget > 0 else { return }
        stompDiagnosticsBudget -= 1
        let engineWidthConstant = hostedView.superview?.constraints.first {
            String(describing: type(of: $0)) == "NSAutoresizingMaskLayoutConstraint"
                && $0.firstItem === hostedView
                && $0.firstAttribute == .width
        }?.constant
        cmuxDebugLog(
            "portal.stomp.diag hosted=\(portalDebugToken(hostedView)) " +
            "lastTarget=\(portalDebugFrame(lastTarget)) stompedTo=\(portalDebugFrame(oldFrame)) " +
            "newTarget=\(portalDebugFrame(targetFrame)) " +
            "engineWidthConstant=\(engineWidthConstant.map { String(format: "%.1f", $0) } ?? "nil") " +
            "ambiguous=\(hostedView.hasAmbiguousLayout ? 1 : 0) budget=\(stompDiagnosticsBudget)"
        )
        for constraint in hostedView.constraintsAffectingLayout(for: .horizontal) {
            cmuxDebugLog(
                "portal.stomp.diag.h hosted=\(portalDebugToken(hostedView)) \(constraint)"
            )
        }
    }
#endif

    private struct HostedGeometrySignature: Equatable {
        let hostedFrame: NSRect?
        let expectedFrame: NSRect?
    }

    private struct ExternalGeometrySignature: Equatable {
        // The window contributes its SIZE and backing scale, never its
        // origin. Every other field is window-relative, so this signature —
        // the sole terminator of the sync echo chain — must not change when
        // the window merely moves. It once held the full window frame, and
        // during a titlebar drag the changing origin made every echoed sync
        // escalate to a full layout pass whose own notifications scheduled
        // the next: a per-tick layout storm while dragging a window full of
        // mirrored panes. The backing scale is the one legitimate
        // origin-correlated effect (crossing to a different-DPI screen
        // re-snaps pixel geometry), so it stays.
        let windowSize: CGSize?
        let backingScale: CGFloat?
        let hostFrame: NSRect
        let containerFrame: NSRect?
        let referenceFrame: NSRect?
        let entries: [ObjectIdentifier: HostedGeometrySignature]
    }

    /// Raw-rect snapshot of everything a sync pass reads or writes.
    private func externalGeometrySignature() -> ExternalGeometrySignature {
        var entries: [ObjectIdentifier: HostedGeometrySignature] = [:]
        entries.reserveCapacity(entriesByHostedId.count)
        for (id, entry) in entriesByHostedId {
            let expected = entry.anchorView.flatMap { anchor in
                anchor.window == nil ? nil : expectedHostedFrameInHost(for: anchor)
            }
            entries[id] = HostedGeometrySignature(
                hostedFrame: entry.hostedView?.frame,
                expectedFrame: expected
            )
        }
        return ExternalGeometrySignature(
            windowSize: window?.frame.size,
            backingScale: window?.backingScaleFactor,
            hostFrame: hostView.frame,
            containerFrame: installedContainerView?.frame,
            referenceFrame: installedReferenceView?.frame,
            entries: entries
        )
    }

    private func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== dividerOverlayView {
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }

        if !Self.rectApproximatelyEqual(dividerOverlayView.frame, hostView.bounds) {
            dividerOverlayView.frame = hostView.bounds
        }
        dividerOverlayView.needsDisplay = true
    }

    @discardableResult
    private func ensureInstalled(syncLayout: Bool = true) -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installedTargetIfStillValid(for: window) ?? installationTarget(for: window)
        else { return false }
        let browserHost = preferredBrowserHost(in: container)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            hostView.removeFromSuperview()
            if let browserHost {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            } else {
                container.addSubview(hostView, positioned: .above, relativeTo: reference)
            }

            // The portal owns hostView.frame — synchronizeHostFrameToReference
            // writes it from the reference's ACTUAL bounds on every sync pass,
            // install, and geometry notification. It is deliberately NOT
            // edge-constrained to the reference: constraints read the layout
            // ENGINE's solution for the reference, and when a hosted AppKit
            // subtree carries a required width demand beyond the window, the
            // engine's solution for the hosting view exceeds the frame the
            // hosting view actually holds (its frame setter refuses oversize).
            // Edge constraints then stomped hostView to the oversized engine
            // solution on every layout pass, stretched every hosted terminal
            // view by the same delta through autoresizing, and the sync pass
            // that undid it forced the next layout pass — a display-rate
            // hierarchy-sync storm that never converged (seen live: hosted
            // views pinned at plan+175pt for minutes, full_hierarchy_sync in
            // the thousands per settle window). Frames written manually from
            // actual bounds cannot diverge from actual bounds.
            installedContainerView = container
            installedReferenceView = reference
            installReferenceGeometryObservers(reference: reference)
        } else if let browserHost {
            if !Self.isView(browserHost, above: hostView, in: container) {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            }
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !Self.isView(overlay, above: hostView, in: container) {
            container.addSubview(overlay, positioned: .above, relativeTo: hostView)
        }

        if syncLayout {
            synchronizeLayoutHierarchy()
        }
        _ = synchronizeHostFrameToReference()
        ensureDividerOverlayOnTop()

        return true
    }

    private func installedTargetIfStillValid(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return nil
        }

        guard hostView.superview === container,
              container.window === window,
              reference.window === window,
              reference.superview === container else {
            return nil
        }

        return (container, reference)
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let target = chromeComposition
            .contentOverlayTargetResolver
            .installationTarget(for: window) else { return nil }
        return (target.container, target.reference)
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

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    private func preferredBrowserHost(in container: NSView) -> WindowBrowserHostView? {
        container.subviews.last(where: { $0 is WindowBrowserHostView }) as? WindowBrowserHostView
    }

#if DEBUG
    private func nearestBonsplitContainer(from anchorView: NSView) -> NSView? {
        var current: NSView? = anchorView
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className.contains("PaneDragContainerView") || className.contains("Bonsplit") {
                return view
            }
            current = view.superview
        }
        return installedReferenceView
    }

    private func logBonsplitContainerFrameIfNeeded(anchorView: NSView, hostedView: GhosttySurfaceScrollView) {
        guard let container = nearestBonsplitContainer(from: anchorView) else { return }
        let containerFrame = container.convert(container.bounds, to: nil)
        let signature = "\(ObjectIdentifier(container)):\(portalDebugFrame(containerFrame))"
        guard signature != lastLoggedBonsplitContainerSignature else { return }
        lastLoggedBonsplitContainerSignature = signature

        let containerClass = NSStringFromClass(type(of: container))
        cmuxDebugLog(
            "portal.bonsplit.container hosted=\(portalDebugToken(hostedView)) " +
            "class=\(containerClass) frame=\(portalDebugFrame(containerFrame)) " +
            "host=\(portalDebugFrameInWindow(hostView)) anchor=\(portalDebugFrameInWindow(anchorView))"
        )
    }
#endif

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor clipping.
    /// SwiftUI/AppKit hosting layers can report an anchor bounds wider than its split pane when
    /// intrinsic-size content overflows; intersecting through ancestor bounds gives the effective
    /// visible rect that should drive portal geometry.
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

    /// THE geometry truth for a hosted view: its anchor's effective
    /// (ancestor-clipped) rect, converted into host coordinates and snapped
    /// to device pixels. The frame writer, the sync fingerprint, and the
    /// misplacement judge must all use this one computation — they briefly
    /// used three, and a clipped anchor then judged its own correct write
    /// as misplaced while keeping the fingerprint permanently unsettled.
    func expectedHostedFrameInHost(for anchorView: NSView) -> NSRect {
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let intersection = frameInHost.intersection(hostView.bounds)
        guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else {
            return frameInHost
        }
        return intersection
    }

    private func seededFrameInHost(for anchorView: NSView) -> NSRect? {
        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        guard hasFiniteFrame else { return nil }

        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        if hasFiniteHostBounds {
            let clampedFrame = frameInHost.intersection(hostBounds)
            if !clampedFrame.isNull, clampedFrame.width > 1, clampedFrame.height > 1 {
                return clampedFrame
            }
        }

        return frameInHost
    }

    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
#if DEBUG
        lastPortalTargetByHostedId.removeValue(forKey: hostedId)
#endif
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadSuperview = (entry.hostedView?.superview === hostView) ? 1 : 0
        cmuxDebugLog(
            "portal.detach hosted=\(portalDebugToken(entry.hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) hadSuperview=\(hadSuperview)"
        )
#endif
        if let hostedView = entry.hostedView {
            if let restoredMask = preAdoptionAutoresizingMaskByHostedId.removeValue(forKey: hostedId) {
                hostedView.autoresizingMask = restoredMask
            }
            if hostedView.superview === hostView {
                hostedView.removeFromSuperview()
            }
        } else {
            preAdoptionAutoresizingMaskByHostedId.removeValue(forKey: hostedId)
        }
    }

    /// Hide a portal entry for permanent workspace unmounts without detaching it.
    func hideEntry(forHostedId hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = false
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
        entry.hostedView?.isHidden = true
#if DEBUG
        cmuxDebugLog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=workspaceUnmount")
#endif
    }

    /// Update the visibleInUI flag on an existing entry without rebinding.
    /// Used when a deferred bind is pending — this ensures synchronizeHostedView
    /// won't hide a view that updateNSView has already marked as visible.
    @discardableResult
    func updateEntryVisibility(forHostedId hostedId: ObjectIdentifier, visibleInUI: Bool) -> Bool {
        let needsReattach = visibleInUI && hostedViewNeedsPortalReattachForVisiblePresentation(withId: hostedId)
        guard var entry = entriesByHostedId[hostedId] else { return needsReattach }
        let becameVisible = visibleInUI && !entry.visibleInUI
        let becameHidden = !visibleInUI && entry.visibleInUI
        entry.visibleInUI = visibleInUI
        if !visibleInUI { entry.transientRecoveryRetriesRemaining = 0 }
        entriesByHostedId[hostedId] = entry
        // A view that just became visible may still hold the frame it was
        // born with (bind can seed from a pre-settle anchor reading, and a
        // hidden entry's frame is deliberately left alone). Visibility is a
        // sizing input like any other: it schedules a pass rather than
        // trusting that some earlier one already ran.
        //
        // A flip to invisible must schedule the same pass: the hide is applied
        // by synchronizeHostedView (shouldHide reads entry.visibleInUI), and a
        // selection-only tab switch produces no window geometry churn that
        // would run one otherwise. An unscheduled hide left the deselected
        // terminal's layer rendering above SwiftUI chrome — the previous
        // terminal's content filled the browser omnibar band until unrelated
        // churn (sidebar toggle, window resize) healed it.
        if becameVisible || becameHidden {
            scheduleExternalGeometrySynchronize(forceImmediate: false)
        }
        return needsReattach
    }

    func isHostedViewBoundToAnchor(withId hostedId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByHostedId[hostedId], let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func hostedViewNeedsPortalReattachForVisiblePresentation(withId hostedId: ObjectIdentifier) -> Bool {
        guard let entry = entriesByHostedId[hostedId], let hostedView = entry.hostedView, let anchor = entry.anchorView else { return true }
        return !entry.visibleInUI || anchor.window !== window || anchor.superview == nil || (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false) || hostedView.superview !== hostView || hostedView.window !== window
    }

    func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        deferLayoutSynchronization: Bool = false
    ) {
        guard ensureInstalled(syncLayout: !deferLayoutSynchronization) else { return }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        // The portal is the sole writer of a hosted view's geometry, and the
        // autoresizing mask the view arrives with breaks that: the layout
        // engine translates a flexible mask into EDGE pins — a minX constant
        // plus a trailing margin to the host, no width at all — frozen at
        // the last constraint pass. Every host resize then re-derives the
        // view's size from those stale margins against the new host bounds
        // and stomps the portal's write (panes re-inflated to a previous
        // generation's geometry, hierarchy syncs in the thousands per settle
        // window). An empty mask translates to rigid position+size constants
        // that always equal the last portal write, so the engine can only
        // ever re-apply portal truth. Detach restores the saved mask.
        if preAdoptionAutoresizingMaskByHostedId[hostedId] == nil {
            preAdoptionAutoresizingMaskByHostedId[hostedId] = hostedView.autoresizingMask
        }
        hostedView.autoresizingMask = []

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
#if DEBUG
            let previousToken = entriesByHostedId[previousHostedId]
                .map { portalDebugToken($0.hostedView) }
                ?? String(describing: previousHostedId)
            cmuxDebugLog(
                "portal.bind.replace anchor=\(portalDebugToken(anchorView)) " +
                "oldHosted=\(previousToken) newHosted=\(portalDebugToken(hostedView))"
            )
#endif
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            transientRecoveryRetriesRemaining: 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil || didChangeAnchor || becameVisible || priorityIncreased || hostedView.superview !== hostView {
            cmuxDebugLog(
                "portal.bind hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) prevAnchor=\(portalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        _ = synchronizeHostFrameToReference()

        // Seed frame/bounds before entering the window so a freshly reparented
        // surface doesn't do a transient 800x600 size update on viewDidMoveToWindow.
        if let seededFrame = seededFrameInHost(for: anchorView),
           seededFrame.width > 0,
           seededFrame.height > 0 {
            performSelfFrameWrite {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hostedView.frame = seededFrame
                hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
                CATransaction.commit()
            }
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            performSelfFrameWrite {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hostedView.frame = .zero
                hostedView.bounds = .zero
                CATransaction.commit()
            }
            hostedView.isHidden = true
        }
        // Keep inner scroll/surface geometry in sync with the seeded outer frame
        // before the hosted view enters a window.
        hostedView.reconcileGeometryNow()

        if hostedView.superview !== hostView {
#if DEBUG
            cmuxDebugLog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) " +
                "reason=attach super=\(portalDebugToken(hostedView.superview))"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only when a view becomes visible or gets a higher priority.
            // Anchor-only churn is common during split tree updates; forcing remove/add there
            // causes transient inWindow=0 -> 1 bounces that can flash black.
#if DEBUG
            cmuxDebugLog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        ensureDividerOverlayOnTop()

        if deferLayoutSynchronization {
            // Bind calls from SwiftUI NSViewRepresentable update/layout callbacks
            // must not force ancestor layout synchronously. Still reconcile the
            // portal entry from already-current host geometry so resize/visibility
            // does not lag until a later external observer turn.
            synchronizeHostedView(withId: hostedId, syncLayout: false)
            scheduleDeferredFullSynchronizeAll()
        } else {
            synchronizeHostedView(withId: hostedId)
            scheduleDeferredFullSynchronizeAll()
        }
        pruneDeadEntries()
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView, syncLayout: Bool = true) {
        // Anchor geometry callbacks fire for every layout pass — including
        // the passes our own syncs run — and treating each one as a
        // synchronous full-portal sync (hierarchy layout + every hosted
        // view + a deferred follow-up) kept the display cycle busy
        // indefinitely under churn. Outside a split-divider drag they
        // coalesce into the scheduled pass like every other trigger; during
        // a divider drag the immediate path below keeps the dragged split
        // visually glued.
        //
        // A live WINDOW resize takes the coalesced path too, on purpose.
        // Unlike a divider drag (one or two anchors move), a window resize
        // fires this callback for EVERY visible pane in the same layout
        // pass, so the full-portal fan-out below did panes × callbacks
        // work per display frame. Syncing just this anchor's hosted view
        // keeps the pane glued to the geometry the layout pass produced;
        // the per-tick scheduled pass (windowDidResize) catches panes whose
        // window-relative position changed without their own frame
        // changing, and the end-of-resize sync (windowDidEndLiveResize →
        // scheduleExternalGeometrySynchronize) stays unconditional.
        guard TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window) else {
            if !isWindowLiveResizeActive {
                pruneDeadEntries()
            }
            let anchorId = ObjectIdentifier(anchorView)
            if let hostedId = hostedByAnchorId[anchorId] {
                synchronizeHostedView(withId: hostedId, syncLayout: false)
            }
            scheduleExternalGeometrySynchronize(forceImmediate: false)
            return
        }
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(withId: primaryHostedId, syncLayout: syncLayout)
        }

        // Failsafe: during aggressive divider drags/structural churn, one anchor can miss a
        // geometry callback while another fires. Reconcile all mapped hosted views so no stale
        // frame remains "stuck" onscreen until the next interaction.
        //
        // With the AppKit sidebar experiment on (value pushed from
        // ContentView's dispatcher, the flag's single evaluation site), the
        // failsafe is coalesced to one pass per main-queue turn. Inline it
        // ran per anchor callback, so one divider width commit cost panes x
        // (all-hosted sync + all-visible reconcile) — 57% of drag-loop time
        // in a Time Profiler capture. The deferred pass still runs within
        // the same drag tick (the tracking loop spins the runloop per
        // event), so the missed-callback window is unchanged. Experiment off
        // keeps the existing per-callback fan-out.
        if Self.usesCoalescedAnchorFailsafe {
            scheduleDeferredFullSynchronizeAll(includeVisibleReconcile: true)
        } else {
            synchronizeAllHostedViews(excluding: primaryHostedId, syncLayout: syncLayout)
            reconcileVisibleHostedViewsAfterGeometrySync(
                reason: "portal.anchorGeometrySync", syncLayout: syncLayout
            )
            scheduleDeferredFullSynchronizeAll()
        }
    }

    private func reconcileVisibleHostedViewsAfterGeometrySync(reason: String, syncLayout: Bool = true) {
        // During a live window resize this pass would re-reconcile every
        // visible surface once per resize tick, right after
        // synchronizeHostedView already reconciled the ones whose geometry
        // changed — and then force a redraw per surface per frame. Skip it
        // mid-resize; the end-of-resize sync (windowDidEndLiveResize →
        // scheduleExternalGeometrySynchronize) runs it unconditionally once
        // live resize is over.
        guard !isWindowLiveResizeActive else { return }
        for (hostedId, entry) in entriesByHostedId {
            guard entry.visibleInUI, let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
            if hostedView.reconcileGeometryNow() {
                // Same rule as the primary sync: when this pass runs inside a
                // layout callback (syncLayout == false, every divider or
                // sidebar drag tick), a synchronous display here wedges in
                // Metal. Defer to the next main-queue turn.
                if syncLayout {
                    hostedView.refreshSurfaceNow(reason: reason)
                } else {
                    deferSurfaceRefresh(forHostedId: hostedId, reason: reason + ".deferred")
                }
            }
        }
    }

    private func scheduleDeferredFullSynchronizeAll(includeVisibleReconcile: Bool = false) {
        if includeVisibleReconcile {
            deferredFullSyncIncludesVisibleReconcile = true
        }
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            let reconcileVisible = self.deferredFullSyncIncludesVisibleReconcile
            self.deferredFullSyncIncludesVisibleReconcile = false
            self.synchronizeAllHostedViews(excluding: nil)
            if reconcileVisible {
                // syncLayout false: this runs off a layout callback during
                // divider/sidebar drags, where a synchronous display wedges
                // in Metal (same rule as the per-anchor sync).
                self.reconcileVisibleHostedViewsAfterGeometrySync(
                    reason: "portal.deferredFullSync", syncLayout: false
                )
            }
        }
    }

    private func deferSurfaceRefresh(forHostedId hostedId: ObjectIdentifier, reason: String) {
        pendingDeferredSurfaceRefreshes[hostedId] = reason
        guard !hasDeferredSurfaceRefreshScheduled else { return }
        hasDeferredSurfaceRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredSurfaceRefreshScheduled = false
            let pending = self.pendingDeferredSurfaceRefreshes
            self.pendingDeferredSurfaceRefreshes = [:]
            for (pendingId, pendingReason) in pending {
                guard let entry = self.entriesByHostedId[pendingId],
                      entry.visibleInUI,
                      let hostedView = entry.hostedView,
                      !hostedView.isHidden else { continue }
                hostedView.refreshSurfaceNow(reason: pendingReason)
            }
        }
    }

    private func synchronizeAllHostedViews(excluding hostedIdToSkip: ObjectIdentifier?, syncLayout: Bool = true) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            if hostedId == hostedIdToSkip { continue }
            // An already-hidden entry for a hidden tab is a no-op here by
            // design: its frame is deliberately left alone while hidden, and
            // becoming visible schedules its own sync (updateEntryVisibility).
            // Skipping it matters — a session of mirrored tmux windows keeps
            // dozens of hidden surfaces, and computing every one's
            // ancestor-clipped frame on every geometry tick made live window
            // resizes visibly sluggish.
            if let entry = entriesByHostedId[hostedId],
               !entry.visibleInUI, entry.hostedView?.isHidden == true {
                continue
            }
            synchronizeHostedView(withId: hostedId, syncLayout: syncLayout)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forHostedId hostedId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 else { return }
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forHostedId hostedId: ObjectIdentifier,
        entry: inout Entry,
        hostedView: GhosttySurfaceScrollView,
        reason: String
    ) -> Bool {
        guard Self.transientRecoveryEnabled else { return false }
        // 0 = idle (a fresh episode may begin), -1 = EXHAUSTED. Without the
        // sentinel, an exhausted budget decayed back to 0, looked idle, and
        // refilled — so an entry that stays not-ready (a hosted view
        // mid-teardown during workspace churn) drove one full sync and
        // relayout per runloop turn indefinitely, pinning the main thread.
        // Only a successful sync (resetTransientRecoveryRetryIfNeeded)
        // returns an exhausted entry to idle.
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = -1
        }
        entriesByHostedId[hostedId] = entry
#if DEBUG
        cmuxDebugLog(
            "portal.sync.deferRecover hosted=\(portalDebugToken(hostedView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    private func synchronizeHostedView(withId hostedId: ObjectIdentifier, syncLayout: Bool = true) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "missingAnchorOrWindow"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=missingAnchorOrWindow frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
#if DEBUG
            if !hostedView.isHidden {
                cmuxDebugLog("portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 reason=missingAnchorOrWindow")
            }
#endif
            hostedView.isHidden = true
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "missingAnchorOrWindow"
                )
            }
            return
        }
        guard anchorView.window === window else {
#if DEBUG
            if !hostedView.isHidden {
                cmuxDebugLog(
                    "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(portalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "anchorWindowMismatch"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=anchorWindowMismatch frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "anchorWindowMismatch"
                )
            }
            return
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            cmuxDebugLog(
                "portal.sync.defer hosted=\(portalDebugToken(hostedView)) " +
                "reason=hostBoundsNotReady host=\(portalDebugFrame(hostBounds)) " +
                "anchor=\(portalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=hostBoundsNotReady frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                if Self.transientRecoveryEnabled {
                    _ = scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                } else {
                    scheduleDeferredFullSynchronizeAll()
                }
            }
            return
        }
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
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame =
            targetFrame.width <= Self.tinyHideThreshold ||
            targetFrame.height <= Self.tinyHideThreshold
        let revealReadyForDisplay =
            targetFrame.width >= Self.minimumRevealWidth &&
            targetFrame.height >= Self.minimumRevealHeight
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let shouldDeferReveal = !shouldHide && hostedView.isHidden && !revealReadyForDisplay
        let transientRecoveryReason: String? = {
            guard Self.transientRecoveryEnabled else { return nil }
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            if shouldDeferReveal { return "deferReveal" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forHostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !hostedView.isHidden

        // Reparenting churn can hand the view back through hosting plumbing
        // that re-applies a flexible mask; portal geometry only holds while
        // the mask stays empty, so re-assert it on every sync.
        if hostedView.autoresizingMask != [] {
#if DEBUG
            cmuxDebugLog(
                "portal.autoresizingMask.reassert hosted=\(portalDebugToken(hostedView)) " +
                "mask=\(hostedView.autoresizingMask.rawValue)"
            )
#endif
            hostedView.autoresizingMask = []
        }

        let oldFrame = hostedView.frame
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            cmuxDebugLog(
                "portal.frame.clamp hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) " +
                "raw=\(portalDebugFrame(frameInHost)) clamped=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            cmuxDebugLog(
                "portal.frame.collapse hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            cmuxDebugLog(
                "portal.frame.restore hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        }
#endif

        // Hide before updating the frame when this entry should not be visible.
        // This avoids a one-frame flash of unrendered terminal background when a portal
        // briefly transitions through offscreen/tiny geometry during rapid split churn.
        if shouldHide, !hostedView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = true
        }
        if shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(portalDebugFrame(hostedView.frame))"
            )
#endif
        }

        if hasFiniteFrame {
            let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
            var geometryChanged = false
#if DEBUG
            if let lastTarget = lastPortalTargetByHostedId[hostedId],
               !Self.rectApproximatelyEqual(oldFrame, lastTarget),
               !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
                logStompDiagnostics(
                    hostedView: hostedView,
                    oldFrame: oldFrame,
                    lastTarget: lastTarget,
                    targetFrame: targetFrame
                )
            }
            lastPortalTargetByHostedId[hostedId] = targetFrame
#endif
            performSelfFrameWrite {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
                    hostedView.frame = targetFrame
                    geometryChanged = true
                }
                if !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) {
                    hostedView.bounds = expectedBounds
                    geometryChanged = true
                }
                CATransaction.commit()
            }
            if geometryChanged {
                _ = hostedView.reconcileGeometryNow()
                // Hidden surfaces keep geometry bookkeeping and redraw on reveal.
                // Mid window live-resize, skip the synchronous redraw for visible
                // ones too: reconcileGeometryNow already pushed the new size into
                // the runtime (a ghostty size change schedules its own repaint),
                // and forcing displayIfNeeded plus an extra surface refresh for
                // every visible pane on every resize tick — sometimes before the
                // pane's Metal layer was even realized — is what made resizing a
                // window full of mirrored panes drag. The end-of-resize sync runs
                // after live resize is over and takes this branch normally.
                if entry.visibleInUI, !shouldHide, !hostedView.isHidden, !isWindowLiveResizeActive {
                    if syncLayout {
                        hostedView.refreshSurfaceNow(reason: "portal.frameChange")
                    } else {
                        deferSurfaceRefresh(forHostedId: hostedId, reason: "portal.frameChange.deferred")
                    }
                }
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
                cmuxDebugLog(
                    "portal.hidden.deferReveal hosted=\(portalDebugToken(hostedView)) " +
                    "frame=\(portalDebugFrame(frameInHost)) min=\(Int(Self.minimumRevealWidth))x\(Int(Self.minimumRevealHeight))"
                )
            }
#endif
        }

        if !shouldHide, hostedView.isHidden, revealReadyForDisplay {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = false
            // A reveal can happen without any frame delta (same targetFrame), which means the
            // normal frame-change refresh path won't run. Nudge geometry + redraw so newly
            // revealed terminals don't sit on a stale/blank IOSurface until later focus churn.
            hostedView.reconcileGeometryNow()
            if syncLayout {
                hostedView.refreshSurfaceNow(reason: "portal.reveal")
            } else {
                deferSurfaceRefresh(forHostedId: hostedId, reason: "portal.reveal.deferred")
            }
        }

        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }

#if DEBUG
        // Log only syncs that DID something. During a live window resize this
        // runs per hosted view per geometry tick; unconditional logging wrote
        // thousands of no-op lines a minute (old == target, hide unchanged)
        // and the file I/O alone dragged on the resize.
        if !Self.rectApproximatelyEqual(oldFrame, targetFrame) || shouldHide != hostedView.isHidden {
            cmuxDebugLog(
                "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
                "hostWin=\(hostView.window?.windowNumber ?? -1) " +
                "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
                "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
                "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
                "hostBounds=\(portalDebugFrame(hostBounds))"
            )
        }
#endif

        ensureDividerOverlayOnTop()
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else {
                return entry.visibleInUI ? nil : hostedId
            }

            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // During aggressive tab drag/reorder churn, SwiftUI/AppKit can briefly
                // detach/rehome anchor hosts while the terminal should stay visible.
                // Avoid pruning those visible entries so sync/bind recovery can reattach.
                return entry.visibleInUI ? nil : hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

    private func hostedScrollViewAtWindowPoint(_ windowPoint: NSPoint) -> (view: GhosttySurfaceScrollView, point: NSPoint)? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView,
                  entriesByHostedId[ObjectIdentifier(hostedView)] != nil,
                  !hostedView.isHidden,
                  hostedView.frame.contains(point) else { continue }
            return (hostedView, hostedView.convert(point, from: hostView))
        }

        return nil
    }

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.hitTest(hit.point) ?? hit.view
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.terminalViewForDrop(at: hit.point)
    }

    func terminalPaneDropTargetAtWindowPoint(_ windowPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.paneDropTargetForDrop(at: hit.point)
    }
}

@MainActor
enum TerminalWindowPortalRegistry {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var hasPendingExternalGeometrySyncForAllWindows = false
    private static var externalGeometrySyncForAllWindowsGeneration: UInt64 = 0
    private static var interactiveGeometryResizeCountsByWindowId: [ObjectIdentifier: Int] = [:]
    private static var unscopedInteractiveGeometryResizeCount = 0
    private static var interactiveGeometryResizeOwnerWindowIds: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var unscopedInteractiveGeometryResizeOwnerIds: Set<ObjectIdentifier> = []
    private static var activeSplitDividerDragWindowId: ObjectIdentifier?
    private static var activeSplitDividerDragEventNumber: Int?
#if DEBUG
    static var blockedBindCount: Int = 0
    static var blockedBindReasons: [String: Int] = [:]
#endif

    static func isInteractiveGeometryResizeActive(in window: NSWindow?) -> Bool {
#if DEBUG
        if Self.isPointerDragActiveForTesting { return true }
#endif
        if Self.unscopedInteractiveGeometryResizeCount > 0 { return true }
        if let window,
           Self.interactiveGeometryResizeCountsByWindowId[ObjectIdentifier(window), default: 0] > 0 {
            return true
        }
        return isSplitDividerDragActive(in: window)
    }

    private static var isAnyInteractiveGeometryResizeActive: Bool {
#if DEBUG
        if Self.isPointerDragActiveForTesting { return true }
#endif
        if Self.unscopedInteractiveGeometryResizeCount > 0 { return true }
        if Self.interactiveGeometryResizeCountsByWindowId.values.contains(where: { $0 > 0 }) { return true }
        return isCurrentEventSplitDividerDrag()
    }

    private static func isCurrentEventSplitDividerDrag() -> Bool {
        let isLeftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard isLeftButtonDown else {
            clearActiveSplitDividerDrag()
            return false
        }

        guard let event = NSApp.currentEvent else { return false }

        switch event.type {
        case .leftMouseUp:
            clearActiveSplitDividerDrag()
            return false
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return false
        }

        if let activeSplitDividerDragWindowId, let activeSplitDividerDragEventNumber {
            let hasActiveWindow = NSApp.windows.contains { ObjectIdentifier($0) == activeSplitDividerDragWindowId }
            if hasActiveWindow, event.eventNumber == activeSplitDividerDragEventNumber {
                return true
            }
            clearActiveSplitDividerDrag()
        }

        guard event.type == .leftMouseDown else { return false }

        let candidateWindows = currentSplitDividerDragCandidateWindows(for: event)
        let mouseLocation = NSEvent.mouseLocation
        for window in candidateWindows {
            if WindowTerminalHostView.hasSplitDivider(atScreenPoint: mouseLocation, in: window) {
                activeSplitDividerDragWindowId = ObjectIdentifier(window)
                activeSplitDividerDragEventNumber = event.eventNumber
                return true
            }
        }

        return false
    }

    fileprivate static func isSplitDividerDragActive(in window: NSWindow?) -> Bool {
        guard let window, isCurrentEventSplitDividerDrag() else { return false }
        return activeSplitDividerDragWindowId == ObjectIdentifier(window)
    }

    private static func clearActiveSplitDividerDrag() {
        activeSplitDividerDragWindowId = nil
        activeSplitDividerDragEventNumber = nil
    }

    // Only the event's own window may latch drag ownership: a foreign drag routed through an occluded host must not self-authorize its cursor.
    fileprivate static func noteSplitDividerInteraction(in window: NSWindow?, event: NSEvent?) {
        guard let window, let event, event.window === window,
              (NSEvent.pressedMouseButtons & 1) != 0 else { return }

        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            activeSplitDividerDragWindowId = ObjectIdentifier(window)
            activeSplitDividerDragEventNumber = event.eventNumber
        default:
            break
        }
    }

    private static func currentSplitDividerDragCandidateWindows(for event: NSEvent) -> [NSWindow] {
        var candidateWindows: [NSWindow] = []
        if let eventWindow = event.window {
            candidateWindows.append(eventWindow)
        }
        if let keyWindow = NSApp.keyWindow, !candidateWindows.contains(where: { $0 === keyWindow }) {
            candidateWindows.append(keyWindow)
        }
        if let mainWindow = NSApp.mainWindow, !candidateWindows.contains(where: { $0 === mainWindow }) {
            candidateWindows.append(mainWindow)
        }
        return candidateWindows
    }

    private static func bindBlockReason(
        expectedSurfaceId: UUID?,
        expectedGeneration: UInt64?,
        actual: (surfaceId: UUID?, generation: UInt64?, state: String)
    ) -> String {
        if actual.surfaceId == nil {
            return "missingSurface"
        }
        if actual.state != "live" {
            return "state_\(actual.state)"
        }
        if let expectedSurfaceId, actual.surfaceId != expectedSurfaceId {
            return "surfaceMismatch"
        }
        if let expectedGeneration, actual.generation != expectedGeneration {
            return "generationMismatch"
        }
        return "guardRejected"
    }

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) == nil else { return }
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
            &cmuxWindowTerminalPortalCloseObserverKey,
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
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }
        interactiveGeometryResizeCountsByWindowId.removeValue(forKey: windowId)
        interactiveGeometryResizeOwnerWindowIds = interactiveGeometryResizeOwnerWindowIds.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneHostedMappings(for windowId: ObjectIdentifier, validHostedIds: Set<ObjectIdentifier>) {
        hostedToWindowId = hostedToWindowId.filter { hostedId, mappedWindowId in
            mappedWindowId != windowId || validHostedIds.contains(hostedId)
        }
    }

    private static func portal(for window: NSWindow, syncLayout: Bool = true) -> WindowTerminalPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowTerminalPortal(window: window, syncLayout: syncLayout)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    private static func existingPortal(for window: NSWindow) -> WindowTerminalPortal? {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }
        return portalsByWindowId[ObjectIdentifier(window)]
    }

    static func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        expectedSurfaceId: UUID? = nil,
        expectedGeneration: UInt64? = nil,
        deferLayoutSynchronization: Bool = false
    ) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)
        let guardState = hostedView.portalBindingGuardState()
        guard hostedView.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        ) else {
            if let oldWindowId = hostedToWindowId.removeValue(forKey: hostedId) {
                portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
            }
#if DEBUG
            let reason = bindBlockReason(
                expectedSurfaceId: expectedSurfaceId,
                expectedGeneration: expectedGeneration,
                actual: guardState
            )
            blockedBindCount += 1
            blockedBindReasons[reason, default: 0] += 1
            cmuxDebugLog(
                "portal.bind.blocked hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(reason) expectedSurface=\(expectedSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                "expectedGeneration=\(expectedGeneration.map { String($0) } ?? "nil") " +
                "actualSurface=\(guardState.surfaceId?.uuidString.prefix(5) ?? "nil") " +
                "actualGeneration=\(guardState.generation.map { String($0) } ?? "nil") " +
                "actualState=\(guardState.state)"
            )
#endif
            return
        }

        let nextPortal = portal(for: window, syncLayout: !deferLayoutSynchronization)

        if let oldWindowId = hostedToWindowId[hostedId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
        }

        nextPortal.bind(
            hostedView: hostedView,
            to: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            deferLayoutSynchronization: deferLayoutSynchronization
        )
        hostedToWindowId[hostedId] = windowId
        pruneHostedMappings(for: windowId, validHostedIds: nextPortal.hostedIds())
    }

    static func synchronizeForAnchor(_ anchorView: NSView, syncLayout: Bool = true) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window, syncLayout: syncLayout)
        portal.synchronizeHostedViewForAnchor(anchorView, syncLayout: syncLayout)
    }

    static func scheduleExternalGeometrySynchronize(for window: NSWindow, forceImmediate: Bool = true) {
        existingPortal(for: window)?.scheduleExternalGeometrySynchronize(forceImmediate: forceImmediate)
    }

#if DEBUG
    static func synchronizeExternalGeometryNow(for window: NSWindow) {
        existingPortal(for: window)?.synchronizeAllEntriesFromExternalGeometryChange()
    }
#endif

    static func beginInteractiveGeometryResize(in window: NSWindow?) {
        beginInteractiveGeometryResize(windowId: window.map(ObjectIdentifier.init))
    }

    static func endInteractiveGeometryResize(in window: NSWindow?) {
        endInteractiveGeometryResize(windowId: window.map(ObjectIdentifier.init))
    }

    static func beginInteractiveGeometryResize(owner: AnyObject, in window: NSWindow?) {
        let ownerId = ObjectIdentifier(owner)
        guard interactiveGeometryResizeOwnerWindowIds[ownerId] == nil,
              !unscopedInteractiveGeometryResizeOwnerIds.contains(ownerId) else { return }
        if let windowId = window.map(ObjectIdentifier.init) {
            interactiveGeometryResizeOwnerWindowIds[ownerId] = windowId
            beginInteractiveGeometryResize(windowId: windowId)
        } else {
            unscopedInteractiveGeometryResizeOwnerIds.insert(ownerId)
            beginInteractiveGeometryResize(windowId: nil)
        }
    }

    static func endInteractiveGeometryResize(owner: AnyObject) {
        let ownerId = ObjectIdentifier(owner)
        if let windowId = interactiveGeometryResizeOwnerWindowIds.removeValue(forKey: ownerId) {
            endInteractiveGeometryResize(windowId: windowId)
        } else if unscopedInteractiveGeometryResizeOwnerIds.remove(ownerId) != nil {
            endInteractiveGeometryResize(windowId: nil)
        }
    }

    private static func beginInteractiveGeometryResize(windowId: ObjectIdentifier?) {
        guard let windowId else {
            unscopedInteractiveGeometryResizeCount += 1
            return
        }
        interactiveGeometryResizeCountsByWindowId[windowId, default: 0] += 1
#if DEBUG
        if interactiveGeometryResizeCountsByWindowId[windowId] == 1 {
            cmuxDebugLog("portal.geometryResize.begin")
        }
#endif
    }

    private static func endInteractiveGeometryResize(windowId: ObjectIdentifier?) {
        guard let windowId else {
            guard unscopedInteractiveGeometryResizeCount > 0 else { return }
            unscopedInteractiveGeometryResizeCount -= 1
            if unscopedInteractiveGeometryResizeCount == 0 {
                for (portalWindowId, portal) in portalsByWindowId
                where interactiveGeometryResizeCountsByWindowId[portalWindowId, default: 0] == 0 {
                    portal.scheduleExternalGeometrySynchronize(forceImmediate: false)
                }
            }
            return
        }

        guard let count = interactiveGeometryResizeCountsByWindowId[windowId], count > 0 else { return }
        if count == 1 {
            interactiveGeometryResizeCountsByWindowId.removeValue(forKey: windowId)
            // Apply the final exact renderer and PTY dimensions only in the
            // window whose pixel-only coalescing gate just cleared.
            if unscopedInteractiveGeometryResizeCount == 0 {
                portalsByWindowId[windowId]?.scheduleExternalGeometrySynchronize(forceImmediate: false)
            }
            // Single choke point every drag-end path funnels through (tracker
            // onEnded, legacy gesture onEnded, cursor failsafe): observers
            // that deferred work during the drag settle NOW instead of on a
            // trailing timer.
            NotificationCenter.default.post(
                name: .cmuxInteractiveGeometryResizeDidEnd,
                object: nil
            )
#if DEBUG
            cmuxDebugLog("portal.geometryResize.end")
#endif
        } else {
            interactiveGeometryResizeCountsByWindowId[windowId] = count - 1
        }
    }

#if DEBUG
    /// Test support: clears interactive geometry state after a failed test
    /// whose balancing end call may not have run.
    static func resetInteractiveGeometryStateForTesting() {
        interactiveGeometryResizeCountsByWindowId.removeAll()
        unscopedInteractiveGeometryResizeCount = 0
        interactiveGeometryResizeOwnerWindowIds.removeAll()
        unscopedInteractiveGeometryResizeOwnerIds.removeAll()
        clearActiveSplitDividerDrag()
        isPointerDragActiveForTesting = false
    }
#endif

    static func scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: Bool = true) {
        // Same latest-request-wins coalescing for callers that don't have a
        // concrete window handle yet.
        Self.externalGeometrySyncForAllWindowsGeneration &+= 1
        let generation = Self.externalGeometrySyncForAllWindowsGeneration
        guard !Self.hasPendingExternalGeometrySyncForAllWindows else { return }
        Self.hasPendingExternalGeometrySyncForAllWindows = true
        let isDragEvent = forceImmediate || Self.isAnyInteractiveGeometryResizeActive
        DispatchQueue.main.async {
            let performSync = {
                var shouldFlushLatestNow = isDragEvent
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = Self.isAnyInteractiveGeometryResizeActive
                }
                if Self.externalGeometrySyncForAllWindowsGeneration != generation, !shouldFlushLatestNow {
                    Self.hasPendingExternalGeometrySyncForAllWindows = false
                    Self.scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: forceImmediate)
                    return
                }
                Self.hasPendingExternalGeometrySyncForAllWindows = false
                for portal in Self.portalsByWindowId.values {
                    portal.synchronizeAllEntriesFromExternalGeometryChange()
                }
            }
            var shouldPerformNow = isDragEvent
            if !shouldPerformNow {
                shouldPerformNow = Self.isAnyInteractiveGeometryResizeActive
            }
            if shouldPerformNow {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    static func hideHostedView(_ hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId], let portal = portalsByWindowId[windowId] else { return }
        portal.hideEntry(forHostedId: hostedId)
    }

    /// Permanently detach a hosted terminal view from the window-level portal.
    static func detach(hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId.removeValue(forKey: hostedId) else { return }
        portalsByWindowId[windowId]?.detachHostedView(withId: hostedId)
    }

    /// Update visibleInUI on an existing portal entry without rebinding.
    @discardableResult
    static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId], let portal = portalsByWindowId[windowId] else { return visibleInUI }
        return portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    static func isHostedView(_ hostedView: GhosttySurfaceScrollView, boundTo anchorView: NSView) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard hostedToWindowId[hostedId] == windowId, let portal = portalsByWindowId[windowId] else { return false }
        return portal.isHostedViewBoundToAnchor(withId: hostedId, anchorView: anchorView)
    }

    static func viewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        let portal = portal(for: window)
        return portal.viewAtWindowPoint(windowPoint)
    }

    static func terminalViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> GhosttyNSView? {
        let portal = portal(for: window)
        return portal.terminalViewAtWindowPoint(windowPoint)
    }

    static func terminalPaneDropTargetAtWindowPoint(
        _ windowPoint: NSPoint,
        in window: NSWindow
    ) -> TerminalPaneDropTargetView? {
        let portal = portal(for: window)
        return portal.terminalPaneDropTargetAtWindowPoint(windowPoint)
    }

}

extension Notification.Name {
    /// Posted when the last interactive geometry resize session in a window
    /// ends (sidebar/split divider drags). Fired from the registry's single
    /// end path so every drag-end route (tracker, legacy gesture, failsafe)
    /// reaches observers.
    static let cmuxInteractiveGeometryResizeDidEnd =
        Notification.Name("cmux.interactiveGeometryResizeDidEnd")
}
