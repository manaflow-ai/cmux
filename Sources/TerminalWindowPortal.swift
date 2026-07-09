import AppKit
import ObjectiveC
import CmuxAppKitSupportUI
import CmuxSidebar
import CmuxTerminal
#if DEBUG
import Bonsplit
#endif

private var cmuxWindowTerminalPortalKey: UInt8 = 0
private var cmuxWindowTerminalPortalCloseObserverKey: UInt8 = 0

final class WindowTerminalHostView: NSView {
    override var isOpaque: Bool { false }
    private var sidebarResizerPassThroughPolicy = PortalSidebarResizerPassThroughPolicy(
        bandPolicy: SidebarResizeInteraction.bandPolicy
    )
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: SplitDividerCursorKind?
    let paneDropRoutingSession = PaneDropRoutingSession()
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
        var regions: [SplitDividerRegion] = []
        rootView.collectSplitDividerRegions(into: &regions)
        let expansion: CGFloat = 4
        for region in regions {
            let rectInHost = convert(region.rectInWindow, from: nil)
            guard let candidate = PortalDividerCursorRect(
                rectInHost: rectInHost,
                isVertical: region.isVertical,
                hostBounds: bounds,
                expansion: expansion
            ) else { continue }
            guard !cursorRectIntersectsChromePassThrough(candidate.rect) else { continue }
            addCursorRect(candidate.rect, cursor: candidate.cursor)
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
                activeDividerCursorKind = kind
                kind.cursor.set()
                TerminalWindowPortalRegistry.noteSplitDividerInteraction(
                    in: window,
                    event: currentEvent
                )
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
        // and steal hover/mouse events. The view supplies the visible hosted
        // surface frames; the cached-divider inference lives in the policy.
        let hostedSurfaces = subviews.compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }
            .map {
                PortalSidebarResizerPassThroughPolicy.HostedSurfaceFrame(
                    frame: $0.frame,
                    isRightSidebarDockSurface: $0.isRightSidebarDockSurface
                )
            }
        return sidebarResizerPassThroughPolicy.shouldPassThrough(
            at: point,
            bounds: bounds,
            hostedSurfaces: hostedSurfaces
        )
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

    private func splitDividerCursorKind(at point: NSPoint) -> SplitDividerCursorKind? {
        guard let window else { return nil }
        let windowPoint = convert(point, to: nil)
        guard let rootView = window.contentView else { return nil }
        return rootView.splitDividerCursorKind(atWindowPoint: windowPoint)
    }

    static func hasSplitDivider(atScreenPoint screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return rootView.splitDividerCursorKind(atWindowPoint: windowPoint) != nil
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
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
        let entry = PortalDragRouteLogEntry(
            passThrough: passThrough,
            eventType: eventType,
            pasteboardTypes: pasteboardTypes,
            targetClass: targetClass
        )
        let signature = entry.signature
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        cmuxDebugLog(entry.message)
    }
#endif
}

@MainActor
final class WindowTerminalPortal: NSObject {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    private static let tinyHideThreshold: CGFloat = 1
    private static let minimumRevealWidth: CGFloat = 24
    private static let minimumRevealHeight: CGFloat = 18
    private static let transientRecoveryRetryBudget: Int = 12
#if CMUX_ISSUE_483_PORTAL_RECOVERY
    private static let transientRecoveryEnabled = true
#else
    private static let transientRecoveryEnabled = false
#endif

    private weak var window: NSWindow?
    private let hostView = WindowTerminalHostView(frame: .zero)
    private let dividerOverlayView = SplitDividerOverlayView(frame: .zero)
    private let chromeComposition = AppWindowChromeComposition()
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var installConstraints: [NSLayoutConstraint] = []
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    private var pendingExternalGeometrySyncRequiresImmediate = false
    private var externalGeometrySyncGeneration: UInt64 = 0
    private var geometryObservers: [NSObjectProtocol] = []
#if DEBUG
    private var lastLoggedBonsplitContainerSignature: String?
#endif

    private struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var transientRecoveryRetriesRemaining: Int
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow, syncLayout: Bool = true) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        // The hosted-surface type (GhosttySurfaceScrollView) is app-only, so the
        // overlay receives the occluding frames through this injected provider.
        dividerOverlayView.occludingHostedFramesProvider = { hostView in
            hostView.subviews.compactMap { subview -> NSRect? in
                guard let hosted = subview as? GhosttySurfaceScrollView else { return nil }
                guard !hosted.isHidden, hosted.window != nil else { return nil }
                return hosted.frame
            }
        }
        installGeometryObservers(for: window)
        _ = ensureInstalled(syncLayout: syncLayout)
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
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    fileprivate func scheduleExternalGeometrySynchronize() {
        scheduleExternalGeometrySynchronize(forceImmediate: true)
    }

    fileprivate func scheduleExternalGeometrySynchronize(forceImmediate: Bool) {
        // Coalesce to the latest request so ancestor/frame churn (for example
        // sidebar toggles) doesn't resize the PTY at stale intermediate widths.
        externalGeometrySyncGeneration &+= 1
        let generation = externalGeometrySyncGeneration
        guard !hasExternalGeometrySyncScheduled else {
            pendingExternalGeometrySyncRequiresImmediate =
                pendingExternalGeometrySyncRequiresImmediate || forceImmediate
            return
        }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let performSync = {
                let shouldFlushLatestNow = ExternalGeometrySyncFlushPolicy(
                    forceImmediate: forceImmediate,
                    pendingRequiresImmediate: self.pendingExternalGeometrySyncRequiresImmediate,
                    hostInLiveResize: self.hostView.inLiveResize,
                    windowInLiveResize: self.window?.inLiveResize == true,
                    interactiveResizeActive: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
                ).shouldFlushLatest
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
                self.synchronizeAllEntriesFromExternalGeometryChange()
            }
            let shouldPerformNow = ExternalGeometrySyncFlushPolicy(
                forceImmediate: forceImmediate,
                pendingRequiresImmediate: self.pendingExternalGeometrySyncRequiresImmediate,
                hostInLiveResize: self.hostView.inLiveResize,
                windowInLiveResize: self.window?.inLiveResize == true,
                interactiveResizeActive: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
            ).shouldFlushLatest
            if shouldPerformNow {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    private func synchronizeLayoutHierarchy() {
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
    }

    @discardableResult
    private func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame = frameInContainer.hasFiniteComponents
        guard hasFiniteFrame else { return false }

        if !hostView.frame.isApproximatelyEqual(to: frameInContainer, epsilon: 0.01) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
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
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        synchronizeAllHostedViews(excluding: nil)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.externalGeometrySync")
    }

    private func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== dividerOverlayView {
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }

        if !dividerOverlayView.frame.isApproximatelyEqual(to: hostView.bounds, epsilon: 0.01) {
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
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()

            hostView.removeFromSuperview()
            if let browserHost {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            } else {
                container.addSubview(hostView, positioned: .above, relativeTo: reference)
            }

            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
        } else if let browserHost {
            if !browserHost.isOrdered(above: hostView, in: container) {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            }
        } else if !hostView.isOrdered(above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !overlay.isOrdered(above: hostView, in: container) {
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

    private func seededFrameInHost(for anchorView: NSView) -> NSRect? {
        _ = synchronizeHostFrameToReference()
        let frameInWindow = anchorView.effectiveAnchorFrameInWindow(stoppingAt: installedReferenceView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = frameInHostRaw.pixelSnapped(in: hostView)
        let hasFiniteFrame = frameInHost.hasFiniteComponents
        guard hasFiniteFrame else { return nil }

        let hostBounds = hostView.bounds
        let hasFiniteHostBounds = hostBounds.hasFiniteComponents
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
        if let hostedView = entry.hostedView, hostedView.superview === hostView {
            hostedView.removeFromSuperview()
        }
    }

    /// Hide a portal entry without detaching it. Updates visibleInUI to false and
    /// sets isHidden = true so subsequent synchronizeHostedView calls keep it hidden.
    /// Used when a workspace is permanently unmounted (vs. transient bonsplit dismantles).
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
        entry.visibleInUI = visibleInUI
        if !visibleInUI {
            entry.transientRecoveryRetriesRemaining = 0
        }
        entriesByHostedId[hostedId] = entry
        return needsReattach
    }

    /// Whether the hosted terminal view must be re-attached into the portal
    /// before it can present visibly (ported from main: the Dock split-store
    /// pane-focus path uses the returned flag to request a portal reattach).
    func hostedViewNeedsPortalReattachForVisiblePresentation(withId hostedId: ObjectIdentifier) -> Bool {
        guard let entry = entriesByHostedId[hostedId], let hostedView = entry.hostedView, let anchor = entry.anchorView else { return true }
        return !entry.visibleInUI || anchor.window !== window || anchor.superview == nil || (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false) || hostedView.superview !== hostView || hostedView.window !== window
    }

    func isHostedViewBoundToAnchor(withId hostedId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByHostedId[hostedId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = seededFrame
            hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
            CATransaction.commit()
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = .zero
            hostedView.bounds = .zero
            CATransaction.commit()
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
        synchronizeAllHostedViews(excluding: primaryHostedId, syncLayout: syncLayout)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.anchorGeometrySync")
        scheduleDeferredFullSynchronizeAll()
    }

    private func reconcileVisibleHostedViewsAfterGeometrySync(reason: String) {
        for entry in entriesByHostedId.values {
            guard entry.visibleInUI, let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
            if hostedView.reconcileGeometryNow() {
                hostedView.refreshSurfaceNow(reason: reason)
            }
        }
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.synchronizeAllHostedViews(excluding: nil)
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
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
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
        let frameInWindow = anchorView.effectiveAnchorFrameInWindow(stoppingAt: installedReferenceView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = frameInHostRaw.pixelSnapped(in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
        let hostBounds = hostView.bounds
        let anchorHidden = anchorView.isHiddenOrAncestorHidden
        let geometry = PortalEntryGeometryResolution(
            frameInHost: frameInHost,
            hostBounds: hostBounds,
            visibleInUI: entry.visibleInUI,
            anchorHidden: anchorHidden,
            hostedViewIsHidden: hostedView.isHidden,
            tinyHideThreshold: Self.tinyHideThreshold,
            minimumRevealWidth: Self.minimumRevealWidth,
            minimumRevealHeight: Self.minimumRevealHeight
        )
        let hostBoundsReady = geometry.hostBoundsReady
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
        let hasFiniteFrame = geometry.hasFiniteFrame
        let targetFrame = geometry.targetFrame
        let tinyFrame = geometry.tinyFrame
        let revealReadyForDisplay = geometry.revealReadyForDisplay
        let outsideHostBounds = geometry.outsideHostBounds
        let shouldHide = geometry.shouldHide
        let shouldDeferReveal = geometry.shouldDeferReveal
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

        let oldFrame = hostedView.frame
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !frameInHost.isApproximatelyEqual(to: targetFrame, epsilon: 0.01)
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !oldFrame.isApproximatelyEqual(to: targetFrame, epsilon: 0.01) {
                hostedView.frame = targetFrame
                geometryChanged = true
            }
            if !hostedView.bounds.isApproximatelyEqual(to: expectedBounds, epsilon: 0.01) {
                hostedView.bounds = expectedBounds
                geometryChanged = true
            }
            CATransaction.commit()
            if geometryChanged {
                _ = hostedView.reconcileGeometryNow()
                // Hidden surfaces keep geometry bookkeeping and redraw on reveal.
                if entry.visibleInUI, !shouldHide, !hostedView.isHidden {
                    hostedView.refreshSurfaceNow(reason: "portal.frameChange")
                }
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !oldFrame.isApproximatelyEqual(to: frameInHost, epsilon: 0.01) {
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
            hostedView.refreshSurfaceNow(reason: "portal.reveal")
        }

        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }

#if DEBUG
        cmuxDebugLog(
            "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
            "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
            "hostBounds=\(portalDebugFrame(hostBounds))"
        )
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
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    struct DebugStats {
        let windowNumber: Int
        let entryCount: Int
        let hostSubviewCount: Int
        let terminalSubviewCount: Int
        let mappedTerminalSubviewCount: Int
        let orphanTerminalSubviewCount: Int
        let visibleOrphanTerminalSubviewCount: Int
        let staleEntryCount: Int
        let visibleInvalidAnchorEntryCount: Int
    }

    func debugStats() -> DebugStats {
        let terminalSubviews = hostView.subviews.compactMap { $0 as? GhosttySurfaceScrollView }
        var mappedTerminalSubviewCount = 0
        var orphanTerminalSubviewCount = 0
        var visibleOrphanTerminalSubviewCount = 0
        var visibleInvalidAnchorEntryCount = 0

        for hostedView in terminalSubviews {
            let hostedId = ObjectIdentifier(hostedView)
            if entriesByHostedId[hostedId] != nil {
                mappedTerminalSubviewCount += 1
            } else {
                orphanTerminalSubviewCount += 1
                if hostedView.window != nil,
                   !hostedView.isHidden,
                   hostedView.frame.width > Self.tinyHideThreshold,
                   hostedView.frame.height > Self.tinyHideThreshold {
                    visibleOrphanTerminalSubviewCount += 1
                }
            }
        }

        for entry in entriesByHostedId.values where entry.visibleInUI {
            guard let anchor = entry.anchorView else {
                visibleInvalidAnchorEntryCount += 1
                continue
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== window ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                visibleInvalidAnchorEntryCount += 1
            }
        }

        let staleEntryCount = entriesByHostedId.values.reduce(0) { partialResult, entry in
            guard let hostedView = entry.hostedView else { return partialResult + 1 }
            return hostedView.superview === hostView ? partialResult : partialResult + 1
        }

        return DebugStats(
            windowNumber: window?.windowNumber ?? -1,
            entryCount: entriesByHostedId.count,
            hostSubviewCount: hostView.subviews.count,
            terminalSubviewCount: terminalSubviews.count,
            mappedTerminalSubviewCount: mappedTerminalSubviewCount,
            orphanTerminalSubviewCount: orphanTerminalSubviewCount,
            visibleOrphanTerminalSubviewCount: visibleOrphanTerminalSubviewCount,
            staleEntryCount: staleEntryCount,
            visibleInvalidAnchorEntryCount: visibleInvalidAnchorEntryCount
        )
    }

    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

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
    // Interactive-resize / split-divider-drag tracking lives in its own owned
    // `@MainActor` instance (`Sources/Windowing/InteractiveGeometryResizeTracker.swift`).
    // This namespace-enum keeps a single composition-root instance and forwards;
    // the static forwarders preserve the existing call sites byte-for-byte.
    private static let interactiveResizeTracker = InteractiveGeometryResizeTracker()
#if DEBUG
    static var isPointerDragActiveForTesting: Bool {
        get { interactiveResizeTracker.isPointerDragActiveForTesting }
        set { interactiveResizeTracker.isPointerDragActiveForTesting = newValue }
    }
#endif
    private static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var hasPendingExternalGeometrySyncForAllWindows = false
    private static var externalGeometrySyncForAllWindowsGeneration: UInt64 = 0
#if DEBUG
    private static var blockedBindCount: Int = 0
    private static var blockedBindReasons: [String: Int] = [:]
#endif

    static var isInteractiveGeometryResizeActive: Bool {
        interactiveResizeTracker.isInteractiveGeometryResizeActive
    }

    fileprivate static func noteSplitDividerInteraction(in window: NSWindow?, event: NSEvent?) {
        interactiveResizeTracker.noteSplitDividerInteraction(in: window, event: event)
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
            let reason = PortalBindBlockReason(
                expectedSurfaceId: expectedSurfaceId,
                expectedGeneration: expectedGeneration,
                actual: guardState
            ).wireValue
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

    static func beginInteractiveGeometryResize() {
        interactiveResizeTracker.beginInteractiveGeometryResize()
    }

    static func endInteractiveGeometryResize() {
        interactiveResizeTracker.endInteractiveGeometryResize()
    }

    static func scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: Bool = true) {
        // Same latest-request-wins coalescing for callers that don't have a
        // concrete window handle yet.
        Self.externalGeometrySyncForAllWindowsGeneration &+= 1
        let generation = Self.externalGeometrySyncForAllWindowsGeneration
        guard !Self.hasPendingExternalGeometrySyncForAllWindows else { return }
        Self.hasPendingExternalGeometrySyncForAllWindows = true
        let isDragEvent = forceImmediate || Self.isInteractiveGeometryResizeActive
        DispatchQueue.main.async {
            let performSync = {
                var shouldFlushLatestNow = isDragEvent
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = Self.isInteractiveGeometryResizeActive
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
                shouldPerformNow = Self.isInteractiveGeometryResizeActive
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
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideEntry(forHostedId: hostedId)
    }

    /// Permanently detach a hosted terminal view from the window-level portal.
    /// Use this when a terminal panel is actually closing (not transient SwiftUI dismantle).
    static func detach(hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId.removeValue(forKey: hostedId) else { return }
        portalsByWindowId[windowId]?.detachHostedView(withId: hostedId)
    }

    /// Update the visibleInUI flag on an existing portal entry without rebinding.
    /// Called when a bind is deferred (host not yet in window) to prevent stale
    /// portal syncs from hiding a view that is about to become visible.
    @discardableResult
    static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return visibleInUI }
        return portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    static func isHostedView(_ hostedView: GhosttySurfaceScrollView, boundTo anchorView: NSView) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard hostedToWindowId[hostedId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
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

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }

    static func debugPortalStats() -> [String: Any] {
        var portals: [[String: Any]] = []
        var totals: [String: Int] = [
            "entry_count": 0,
            "host_subview_count": 0,
            "terminal_subview_count": 0,
            "mapped_terminal_subview_count": 0,
            "orphan_terminal_subview_count": 0,
            "visible_orphan_terminal_subview_count": 0,
            "stale_entry_count": 0,
            "visible_invalid_anchor_entry_count": 0,
            "mapped_hosted_count": 0,
        ]

        for (windowId, portal) in portalsByWindowId {
            let stats = portal.debugStats()
            let mappedHostedCount = hostedToWindowId.values.reduce(0) { partialResult, mappedWindowId in
                partialResult + (mappedWindowId == windowId ? 1 : 0)
            }
            let integrityOK =
                stats.orphanTerminalSubviewCount == 0 &&
                stats.visibleOrphanTerminalSubviewCount == 0 &&
                stats.staleEntryCount == 0 &&
                stats.visibleInvalidAnchorEntryCount == 0 &&
                mappedHostedCount == stats.entryCount

            portals.append([
                "window_number": stats.windowNumber,
                "entry_count": stats.entryCount,
                "mapped_hosted_count": mappedHostedCount,
                "host_subview_count": stats.hostSubviewCount,
                "terminal_subview_count": stats.terminalSubviewCount,
                "mapped_terminal_subview_count": stats.mappedTerminalSubviewCount,
                "orphan_terminal_subview_count": stats.orphanTerminalSubviewCount,
                "visible_orphan_terminal_subview_count": stats.visibleOrphanTerminalSubviewCount,
                "stale_entry_count": stats.staleEntryCount,
                "visible_invalid_anchor_entry_count": stats.visibleInvalidAnchorEntryCount,
                "integrity_ok": integrityOK,
            ])

            totals["entry_count", default: 0] += stats.entryCount
            totals["host_subview_count", default: 0] += stats.hostSubviewCount
            totals["terminal_subview_count", default: 0] += stats.terminalSubviewCount
            totals["mapped_terminal_subview_count", default: 0] += stats.mappedTerminalSubviewCount
            totals["orphan_terminal_subview_count", default: 0] += stats.orphanTerminalSubviewCount
            totals["visible_orphan_terminal_subview_count", default: 0] += stats.visibleOrphanTerminalSubviewCount
            totals["stale_entry_count", default: 0] += stats.staleEntryCount
            totals["visible_invalid_anchor_entry_count", default: 0] += stats.visibleInvalidAnchorEntryCount
            totals["mapped_hosted_count", default: 0] += mappedHostedCount
        }

        portals.sort {
            let lhs = ($0["window_number"] as? Int) ?? Int.min
            let rhs = ($1["window_number"] as? Int) ?? Int.min
            return lhs < rhs
        }

        return [
            "portal_count": portals.count,
            "hosted_mapping_count": hostedToWindowId.count,
            "guarded_bind_blocked_count": blockedBindCount,
            "guarded_bind_blocked_reasons": blockedBindReasons,
            "portals": portals,
            "totals": totals,
        ]
    }
#endif
}
