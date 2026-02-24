import AppKit
import ObjectiveC
import WebKit
#if DEBUG
import Bonsplit
#endif

private var cmuxWindowBrowserPortalKey: UInt8 = 0
private var cmuxWindowBrowserPortalCloseObserverKey: UInt8 = 0

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

final class WindowBrowserHostView: NSView {
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
        updateDividerCursor(at: point)

        if shouldPassThroughToSidebarResizer(at: point) {
            return nil
        }
        if shouldPassThroughToSplitDivider(at: point) {
            return nil
        }
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
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

    private func updateDividerCursor(at point: NSPoint) {
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

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in view: NSView) -> DividerCursorKind? {
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

}

final class WindowBrowserSlotView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class WindowBrowserPortal: NSObject {
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
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
            installedContainerView = container
            installedReferenceView = reference
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
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

    private func ensureContainerView(for entry: Entry, webView: WKWebView) -> WindowBrowserSlotView {
        if let existing = entry.containerView {
            return existing
        }
        let created = WindowBrowserSlotView(frame: .zero)
#if DEBUG
        dlog(
            "browser.portal.container.create web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(created))"
        )
#endif
        return created
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
            return String(describing: type(of: view)).contains("WK")
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
        entry.webView?.removeFromSuperview()
        entry.containerView?.removeFromSuperview()
    }

    /// Update the visibleInUI/zPriority state on an existing entry without rebinding.
    /// Used when a bind is deferred (host not yet in window) so stale portal syncs
    /// do not keep an old anchor visible.
    func updateEntryVisibility(forWebViewId webViewId: ObjectIdentifier, visibleInUI: Bool, zPriority: Int) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        entry.visibleInUI = visibleInUI
        entry.zPriority = zPriority
        entriesByWebViewId[webViewId] = entry
    }

    func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let webViewId = ObjectIdentifier(webView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByWebViewId[webViewId]
        let containerView = ensureContainerView(
            for: previousEntry ?? Entry(webView: nil, containerView: nil, anchorView: nil, visibleInUI: false, zPriority: 0),
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
            zPriority: zPriority
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
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = containerView.bounds
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
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

        synchronizeWebView(withId: webViewId, source: "bind")
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

    private func synchronizeWebView(withId webViewId: ObjectIdentifier, source: String) {
        guard ensureInstalled() else { return }
        guard let entry = entriesByWebViewId[webViewId] else { return }
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
        guard let anchorView = entry.anchorView, let window else {
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 reason=missingAnchorOrWindow"
                )
            }
#endif
            containerView.isHidden = true
            return
        }
        guard anchorView.window === window else {
#if DEBUG
            if !containerView.isHidden {
                dlog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(browserPortalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            containerView.isHidden = true
            return
        }

        if containerView.superview !== hostView {
#if DEBUG
            dlog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=syncAttach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        }
        if webView.superview !== containerView {
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
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = containerView.bounds
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
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
            containerView.isHidden = true
            scheduleDeferredFullSynchronizeAll()
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
        if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.frame = targetFrame
            CATransaction.commit()
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
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
        }

        let containerBounds = containerView.bounds
        let preNormalizeWebFrame = webView.frame
        let inspectorHeightFromInsets = max(0, containerBounds.height - preNormalizeWebFrame.height)
        let inspectorHeightFromOverflow = max(0, preNormalizeWebFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorHeightFromInsets, inspectorHeightFromOverflow)
#if DEBUG
        let inspectorSubviews = Self.inspectorSubviewCount(in: containerView)
#endif
        if Self.frameExtendsOutsideBounds(preNormalizeWebFrame, bounds: containerBounds) {
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
        }

        if containerView.isHidden != shouldHide {
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
            containerView.isHidden = shouldHide
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
            guard let anchor = entry.anchorView else { return webViewId }
            if container.superview == nil || !container.isDescendant(of: hostView) {
                return webViewId
            }
            if anchor.window !== currentWindow || anchor.superview == nil {
                return webViewId
            }
            if let reference = installedReferenceView,
               !anchor.isDescendant(of: reference) {
                return webViewId
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

    static func detach(webView: WKWebView) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId) else { return }
        portalsByWindowId[windowId]?.detachWebView(withId: webViewId)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}
