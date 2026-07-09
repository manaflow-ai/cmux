import AppKit
import Bonsplit
import CmuxTestSupport
import CmuxWindowing
import SwiftUI

private func windowDragHandleEventTypeDescription(_ eventType: NSEvent.EventType?) -> String {
    eventType.map { String(describing: $0) } ?? "nil"
}

private enum WindowDragHandleBreadcrumbLimiter {
    private static let lock = NSLock()
    private static var lastEmissionByKey: [String: CFAbsoluteTime] = [:]

    static func shouldEmit(key: String, minInterval: CFTimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        if let previous = lastEmissionByKey[key], (now - previous) < minInterval {
            return false
        }
        lastEmissionByKey[key] = now
        if lastEmissionByKey.count > 128 {
            let staleThreshold = now - max(minInterval * 4, 60)
            lastEmissionByKey = lastEmissionByKey.filter { _, timestamp in
                timestamp >= staleThreshold
            }
        }
        return true
    }
}

private func windowDragHandleEmitBreadcrumb(
    _ message: String,
    window: NSWindow?,
    eventType: NSEvent.EventType?,
    point: NSPoint,
    minInterval: CFTimeInterval = 10,
    extraData: [String: Any] = [:]
) {
    let windowNumber = window?.windowNumber ?? -1
    let key = "\(message):\(windowNumber)"
    guard WindowDragHandleBreadcrumbLimiter.shouldEmit(key: key, minInterval: minInterval) else {
        return
    }

    var data: [String: Any] = [
        "event_type": windowDragHandleEventTypeDescription(eventType),
        "point": point.titlebarDragPointDescription,
        "window_number": windowNumber,
        "window_present": window != nil
    ]
    for (name, value) in extraData {
        data[name] = value
    }
    sentryBreadcrumb(message, category: "titlebar.drag", data: data)
}

protocol MinimalModeTitlebarControlHitRegionProviding: AnyObject {
    func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool
}

protocol MinimalModeSidebarControlActionHitRegionProviding: MinimalModeTitlebarControlHitRegionProviding {
    func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot?
}

enum MinimalModeTitlebarControlHitRegionRegistry {
    private static let lock = NSLock()
    private static let registeredViews = NSHashTable<NSView>.weakObjects()

    static func register(_ view: NSView) {
        lock.lock()
        registeredViews.add(view)
        lock.unlock()
    }

    static func unregister(_ view: NSView) {
        lock.lock()
        registeredViews.remove(view)
        lock.unlock()
    }

    private static func snapshot() -> [NSView] {
        lock.lock()
        let views = registeredViews.allObjects
        lock.unlock()
        return views
    }

    private static func isVisibleInHierarchy(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alphaValue > 0 else { return false }
            current = candidate.superview
        }
        return true
    }

    static func containsWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in snapshot() {
            guard view.window === window, isVisibleInHierarchy(view) else { continue }
            let localPoint = view.convert(windowPoint, from: nil)
            let localBounds = view.bounds.insetBy(dx: -epsilon, dy: -epsilon)
            guard localBounds.contains(localPoint) else { continue }
            if let provider = view as? MinimalModeTitlebarControlHitRegionProviding {
                if provider.containsMinimalModeTitlebarControlHit(localPoint: localPoint) {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    static func containsSidebarControlHostWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in snapshot() {
            guard view.window === window,
                  view is MinimalModeSidebarControlActionHitRegionProviding,
                  isVisibleInHierarchy(view) else { continue }
            let localPoint = view.convert(windowPoint, from: nil)
            guard view.bounds.insetBy(dx: -epsilon, dy: -epsilon).contains(localPoint) else { continue }
            return true
        }
        return false
    }

    static func minimalModeSidebarControlActionSlot(
        forWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> MinimalModeSidebarControlActionSlot? {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in snapshot() {
            guard view.window === window,
                  let provider = view as? MinimalModeSidebarControlActionHitRegionProviding,
                  isVisibleInHierarchy(view) else { continue }
            let localPoint = view.convert(windowPoint, from: nil)
            guard view.bounds.insetBy(dx: -epsilon, dy: -epsilon).contains(localPoint) else { continue }
            if let slot = provider.minimalModeSidebarControlActionSlot(localPoint: localPoint) {
                return slot
            }
        }
        return nil
    }
}

/// Marks the region occupied by an interactive titlebar control so window-drag,
/// resize-drag, and double-click-zoom routing yields to the control's own clicks.
///
/// This is the backing of `titlebarInteractiveControl()`. It is applied as a
/// `.background(...)` of the control, so it matches the control's frame but never
/// reparents the control out of its SwiftUI host. The view is transparent to
/// hit-testing (`hitTest` returns `nil`) — it exists only to register its bounds
/// with ``MinimalModeTitlebarControlHitRegionRegistry``. Every titlebar
/// drag/double-click surface consults that registry (via
/// `isMinimalModeTitlebarControlHit`) and skips any registered region, so the
/// control keeps receiving mouse-downs in place.
///
/// Reparenting interactive controls into a nested `NSHostingView` instead (the
/// previous approach) silently dropped their clicks when the control lived in the
/// full-size-content titlebar band, e.g. the right-sidebar mode bar (issue #5099).
struct TitlebarInteractiveControlRegion: NSViewRepresentable {
    final class RegisteredView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
            } else {
                MinimalModeTitlebarControlHitRegionRegistry.register(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var mouseDownCanMoveWindow: Bool { false }

        deinit {
            MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
        }
    }

    func makeNSView(context: Context) -> NSView {
        RegisteredView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MinimalModeTitlebarControlHitRegionRegistry.register(nsView)
    }
}

func isMinimalModeTitlebarControlHit(window: NSWindow, locationInWindow: NSPoint) -> Bool {
    if isMinimalModeSidebarTitlebarControlButtonHit(window: window, locationInWindow: locationInWindow) {
        return true
    }
    return MinimalModeTitlebarControlHitRegionRegistry.containsWindowPoint(locationInWindow, in: window)
}

final class MinimalModeSidebarChromeHoverState: ObservableObject {
    static let shared = MinimalModeSidebarChromeHoverState()

    @Published private(set) var hoveredWindowNumber: Int?

    private init() {}

    func setHovering(_ isHovering: Bool, windowNumber: Int) {
        if isHovering {
            guard hoveredWindowNumber != windowNumber else { return }
            hoveredWindowNumber = windowNumber
        } else if hoveredWindowNumber == windowNumber {
            hoveredWindowNumber = nil
        }
    }

    func clear() {
        guard hoveredWindowNumber != nil else { return }
        hoveredWindowNumber = nil
    }
}

func isMinimalModeSidebarChromeHoverCandidate(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    let isMinimalMode = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = window.isMainWorkspaceWindow
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return false
    }
    guard window.minimalModeSidebarTitlebarControlsAreAvailable else {
        return false
    }

    if MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
        locationInWindow,
        in: window
    ) {
        return true
    }

    guard MinimalModeTitlebarBand(
        isEnabled: true,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ).contains(locationInWindow) else { return false }

    let minX = MinimalModeSidebarTitlebarControlsMetrics(defaults: defaults).leadingInset
    let maxX = minX + MinimalModeSidebarTitlebarControlsMetrics.hostWidth
    return locationInWindow.x >= minX && locationInWindow.x <= maxX
}

private func titlebarControlsStyleConfig(defaults: UserDefaults) -> TitlebarControlsStyleConfig {
    let style = TitlebarControlsStyle(rawValue: defaults.integer(forKey: "titlebarControlsStyle")) ?? .classic
    return style.config
}

func minimalModeSidebarControlActionSlot(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> MinimalModeSidebarControlActionSlot? {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    let isMinimalMode = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = window.isMainWorkspaceWindow
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return nil
    }
    guard window.minimalModeSidebarTitlebarControlsAreAvailable else {
        return nil
    }

    if let registeredSlot = MinimalModeTitlebarControlHitRegionRegistry.minimalModeSidebarControlActionSlot(
        forWindowPoint: locationInWindow,
        in: window
    ) {
        return registeredSlot
    }

    guard MinimalModeTitlebarBand(
        isEnabled: true,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ).contains(locationInWindow) else { return nil }

    let leadingInset = MinimalModeSidebarTitlebarControlsMetrics(defaults: defaults).leadingInset
    let localPoint = NSPoint(
        x: locationInWindow.x - leadingInset,
        y: MinimalModeSidebarTitlebarControlsMetrics.hostHeight / 2
    )
    return TitlebarControlsHitRegions.sidebarActionSlot(
        at: localPoint,
        config: titlebarControlsStyleConfig(defaults: defaults)
    )
}

func isMinimalModeSidebarTitlebarControlButtonHit(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> Bool {
    minimalModeSidebarControlActionSlot(
        window: window,
        locationInWindow: locationInWindow,
        defaults: defaults
    ) != nil
}

#if DEBUG
func recordMinimalModeSidebarChromeHoverForUITest(
    window: NSWindow,
    locationInWindow: NSPoint,
    isHovering: Bool,
    eventType: NSEvent.EventType
) {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
    let defaults = UserDefaults.standard
    let isMinimal = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = window.isMainWorkspaceWindow
    let sidebarControlsAvailable = window.minimalModeSidebarTitlebarControlsAreAvailable
    let contentBounds = window.contentView?.bounds ?? .zero
    let inTitlebarBand = MinimalModeTitlebarBand.isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: isMinimal,
        isFullScreen: isFullScreen,
        isMainWindow: isMainWindow,
        locationInWindow: locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: MinimalModeChromeMetrics.titlebarHeight
    )
    let minX = MinimalModeSidebarTitlebarControlsMetrics(defaults: defaults).leadingInset
    let maxX = minX + MinimalModeSidebarTitlebarControlsMetrics.hostWidth
    let inXRange = (locationInWindow.x >= minX && locationInWindow.x <= maxX)
        || MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
            locationInWindow,
            in: window
        )
    _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
        let count = (payload["minimalSidebarHoverEventCount"] as? String).flatMap(Int.init) ?? 0
        payload["minimalSidebarHoverEventCount"] = String(count + 1)
        payload["minimalSidebarHoverEventType"] = String(describing: eventType)
        payload["minimalSidebarHoverWindowNumber"] = String(window.windowNumber)
        payload["minimalSidebarHoverPoint"] = locationInWindow.titlebarDragPointDescription
        payload["minimalSidebarHoverIsCandidate"] = String(isHovering)
        payload["minimalSidebarHoverIsMinimal"] = String(isMinimal)
        payload["minimalSidebarHoverIsFullScreen"] = String(isFullScreen)
        payload["minimalSidebarHoverIsMainWindow"] = String(isMainWindow)
        payload["minimalSidebarHoverSidebarControlsAvailable"] = String(sidebarControlsAvailable)
        payload["minimalSidebarHoverInTitlebarBand"] = String(inTitlebarBand)
        payload["minimalSidebarHoverInXRange"] = String(inXRange)
        payload["minimalSidebarHoverContentBounds"] = NSStringFromRect(contentBounds)
    }
}
#endif

/// Re-entrancy guard for the sibling hit-test walk. When `sibling.hitTest()`
/// triggers SwiftUI view-body evaluation, AppKit can call back into this
/// function before the outer invocation finishes, causing a Swift
/// exclusive-access violation (SIGABRT). Scope it per window so one window's
/// active walk does not disable hit resolution in another window.
/// Main-thread only, no lock needed.
private var _windowDragHandleResolvingSiblingHitScopes = Set<ObjectIdentifier>()

private func windowDragHandleSiblingHitResolutionScope(
    window: NSWindow?,
    superview: NSView
) -> ObjectIdentifier {
    if let window {
        return ObjectIdentifier(window)
    }
    return ObjectIdentifier(superview)
}

/// Returns whether the titlebar drag handle should capture a hit at `point`.
/// We only claim the hit when no sibling view already handles it, so interactive
/// controls layered in the titlebar (e.g. proxy folder icon) keep their gestures.
@MainActor
func windowDragHandleShouldCaptureHit(
    _ point: NSPoint,
    in dragHandleView: NSView,
    eventType: NSEvent.EventType?,
    eventWindow: NSWindow? = nil
) -> Bool {
    let dragHandleWindow = dragHandleView.window

    if let dragHandleWindow,
       eventType == .leftMouseDown {
        let windowPoint = dragHandleView.convert(point, to: nil)
        if BonsplitTabItemHitRegionRegistry.containsWindowPoint(windowPoint, in: dragHandleWindow) {
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false reason=bonsplitPaneTab point=\(point.titlebarDragPointDescription)"
            )
            #endif
            return false
        }
    }

    // Suppression recovery runs first so stale depth is cleared even for
    // passive events — the associated-object reads/writes here are pure ObjC
    // runtime calls and cannot trigger Swift exclusive-access violations.
    if dragHandleWindow?.isWindowDragSuppressed == true {
        // Recover from stale suppression if a prior interaction missed cleanup.
        // We only keep suppression active while the left mouse button is down.
        if (NSEvent.pressedMouseButtons & 0x1) == 0 {
            let clearedDepth = dragHandleWindow?.clearWindowDragSuppression() ?? 0
            windowDragHandleEmitBreadcrumb(
                "titlebar.dragHandle.suppression.recovered",
                window: dragHandleWindow,
                eventType: eventType,
                point: point,
                minInterval: 20,
                extraData: [
                    "cleared_depth": clearedDepth
                ]
            )
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest suppressionRecovered clearedDepth=\(clearedDepth) point=\(point.titlebarDragPointDescription)"
            )
            #endif
        } else {
        #if DEBUG
            let depth = dragHandleWindow?.windowDragSuppressionDepth ?? 0
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false reason=suppressed depth=\(depth) point=\(point.titlebarDragPointDescription)"
            )
        #endif
            return false
        }
    }

    // Bail out before the view-hierarchy walk so we never re-enter SwiftUI
    // views during a layout pass — which causes exclusive-access crashes (#490).
    if !WindowDragHandleActiveHitResolution(
        eventType: eventType,
        eventWindow: eventWindow,
        dragHandleWindow: dragHandleWindow
    ).shouldResolveActiveHitCapture {
        #if DEBUG
        let eventTypeDescription = eventType.map { String(describing: $0) } ?? "nil"
        let eventWindowNumber = eventWindow?.windowNumber ?? -1
        let dragWindowNumber = dragHandleWindow?.windowNumber ?? -1
        cmuxDebugLog(
            "titlebar.dragHandle.hitTest capture=false reason=passiveEvent eventType=\(eventTypeDescription) eventWindow=\(eventWindowNumber) dragWindow=\(dragWindowNumber) point=\(point.titlebarDragPointDescription)"
        )
        #endif
        return false
    }

    guard dragHandleView.bounds.contains(point) else {
        #if DEBUG
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=outside point=\(point.titlebarDragPointDescription)")
        #endif
        return false
    }

    if let dragHandleWindow {
        let locationInWindow = dragHandleView.convert(point, to: nil)
        if isMinimalModeTitlebarControlHit(window: dragHandleWindow, locationInWindow: locationInWindow) {
            #if DEBUG
            cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=minimalTitlebarControl point=\(point.titlebarDragPointDescription)")
            #endif
            return false
        }
    }

    guard let superview = dragHandleView.superview else {
        #if DEBUG
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=true reason=noSuperview point=\(point.titlebarDragPointDescription)")
        #endif
        return true
    }

    // Bail out if we're already inside a sibling hit-test walk. This happens
    // when sibling.hitTest() re-enters SwiftUI layout, which calls hitTest on
    // this drag handle again. Proceeding would trigger an exclusive-access
    // violation in the Swift runtime.
    let hitResolutionScope = windowDragHandleSiblingHitResolutionScope(
        window: dragHandleWindow,
        superview: superview
    )
    guard !_windowDragHandleResolvingSiblingHitScopes.contains(hitResolutionScope) else {
        #if DEBUG
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=reentrant point=\(point.titlebarDragPointDescription)")
        #endif
        return false
    }

    _windowDragHandleResolvingSiblingHitScopes.insert(hitResolutionScope)
    defer {
        _windowDragHandleResolvingSiblingHitScopes.remove(hitResolutionScope)
    }

    let siblingSnapshot = Array(superview.subviews.reversed())

    #if DEBUG
    let siblingCount = siblingSnapshot.count
    #endif

    for sibling in siblingSnapshot {
        guard sibling !== dragHandleView else { continue }
        guard !sibling.isHidden, sibling.alphaValue > 0 else { continue }

        let pointInSibling = dragHandleView.convert(point, to: sibling)
        if let hitView = sibling.hitTest(pointInSibling) {
            let passiveHostHit = hitView.isWindowDragHandlePassiveHost
            if passiveHostHit {
                #if DEBUG
                cmuxDebugLog(
                    "titlebar.dragHandle.hitTest capture=defer point=\(point.titlebarDragPointDescription) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=true"
                )
                #endif
                continue
            }
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false point=\(point.titlebarDragPointDescription) siblingCount=\(siblingCount) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=false"
            )
            #endif
            windowDragHandleEmitBreadcrumb(
                "titlebar.dragHandle.hitTest.blockedBySiblingHit",
                window: dragHandleWindow,
                eventType: eventType,
                point: point,
                minInterval: 8,
                extraData: [
                    "sibling_type": String(describing: type(of: sibling)),
                    "hit_type": String(describing: type(of: hitView))
                ]
            )
            return false
        }
    }

    #if DEBUG
    cmuxDebugLog("titlebar.dragHandle.hitTest capture=true point=\(point.titlebarDragPointDescription) siblingCount=\(siblingCount)")
    #endif
    return true
}

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarDragHandle")

    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    func makeNSView(context: Context) -> NSView {
        DraggableView(doubleClickBehavior: doubleClickBehavior)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DraggableView)?.doubleClickBehavior = doubleClickBehavior
    }

    private final class DraggableView: NSView {
        var doubleClickBehavior: TitlebarDoubleClickBehavior

        init(doubleClickBehavior: TitlebarDoubleClickBehavior) {
            self.doubleClickBehavior = doubleClickBehavior
            super.init(frame: .zero)
            identifier = WindowDragHandleView.viewIdentifier
        }

        required init?(coder: NSCoder) {
            self.doubleClickBehavior = .standardAction
            super.init(coder: coder)
            identifier = WindowDragHandleView.viewIdentifier
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let currentEvent = NSApp.currentEvent
            // Fast bail-out: only claim hits for left-mouse-down events.
            // For mouseMoved / mouseEntered / etc., return nil immediately
            // to avoid re-entering SwiftUI view state during layout passes,
            // which causes exclusive-access crashes.
            guard currentEvent?.type == .leftMouseDown else {
                return nil
            }
            let shouldCapture = windowDragHandleShouldCaptureHit(
                point,
                in: self,
                eventType: currentEvent?.type,
                eventWindow: currentEvent?.window
            )
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTestResult capture=\(shouldCapture) point=\(point.titlebarDragPointDescription) window=\(window != nil)"
            )
            #endif
            return shouldCapture ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            #if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            let depth = window?.windowDragSuppressionDepth ?? 0
            cmuxDebugLog(
                "titlebar.dragHandle.mouseDown point=\(point.titlebarDragPointDescription) clickCount=\(event.clickCount) depth=\(depth)"
            )
            #endif

            if event.clickCount >= 2 {
                let result = TitlebarDoubleClickHandlingResult.handle(
                    window: window,
                    behavior: doubleClickBehavior
                )
                #if DEBUG
                cmuxDebugLog("titlebar.dragHandle.mouseDownDoubleClick result=\(String(describing: result))")
                #endif
                if result.consumesEvent {
                    return
                }
            }

            guard window?.isWindowDragSuppressed != true else {
                #if DEBUG
                cmuxDebugLog("titlebar.dragHandle.mouseDownIgnored reason=suppressed")
                #endif
                return
            }

            if let window {
                let previousMovableState = window.withTemporaryWindowMovableEnabled {
                    window.performDrag(with: event)
                }
                #if DEBUG
                let restored = previousMovableState.map { String($0) } ?? "nil"
                cmuxDebugLog("titlebar.dragHandle.mouseDownComplete restoredMovable=\(restored) nowMovable=\(window.isMovable)")
                #endif
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

/// Local monitor that guarantees double-clicks in custom titlebar surfaces trigger
/// the standard macOS titlebar action even when the visible strip is hosted by
/// higher-level SwiftUI/AppKit container views.
struct TitlebarDoubleClickMonitorView: NSViewRepresentable {
    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction
        var lastClick: MinimalModeTitlebarClickRecord?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.doubleClickBehavior = doubleClickBehavior

        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak coordinator] event in
            guard let coordinator, let view = coordinator.view, let window = view.window else { return event }
            guard event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else {
                coordinator.lastClick = nil
                return event
            }
            guard !minimalModeTitlebarDoubleClickShouldDefer(
                window: window,
                locationInWindow: event.locationInWindow
            ) else {
                coordinator.lastClick = nil
                return event
            }
            let currentClick = MinimalModeTitlebarClickRecord(
                windowNumber: window.windowNumber,
                timestamp: event.timestamp,
                locationInWindow: event.locationInWindow
            )
            let isDoubleClick = currentClick.formsDoubleClick(
                clickCount: event.clickCount,
                previous: coordinator.lastClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: MinimalModeTitlebarClickRecord.syntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                coordinator.lastClick = currentClick
                return event
            }
            coordinator.lastClick = nil

            let result = TitlebarDoubleClickHandlingResult.handle(
                window: window,
                behavior: coordinator.doubleClickBehavior
            )
            #if DEBUG
            cmuxDebugLog("titlebar.monitor.doubleClick result=\(String(describing: result))")
            #endif
            return result.consumesEvent ? nil : event
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.doubleClickBehavior = doubleClickBehavior
    }
}

func minimalModeTitlebarDoubleClickBandHeight(for window: NSWindow) -> CGFloat {
    MinimalModeChromeMetrics.titlebarHeight
}

func shouldHandleMinimalModeWindowTitlebarDoubleClick(
    window: NSWindow,
    event: NSEvent,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    return MinimalModeTitlebarBand.shouldHandleMinimalModeWindowTitlebarDoubleClick(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: window.isMainWorkspaceWindow,
        clickCount: event.clickCount,
        locationInWindow: event.locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
    )
}

func isMinimalModeWindowTitlebarClickCandidate(
    window: NSWindow,
    event: NSEvent,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    return MinimalModeTitlebarBand.isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: window.isMainWorkspaceWindow,
        locationInWindow: event.locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
    )
}

struct MinimalModeTitlebarEventSurfaceView: NSViewRepresentable {
    var isEnabled: Bool

    private final class PassthroughView: NSView {
        var isEnabled = false
        private weak var mouseMovedWindow: NSWindow?
        private var isTrackingMouseMovedEvents = false
        private var titlebarClickMonitor: Any?
        private var lastTitlebarClick: MinimalModeTitlebarClickRecord?

        deinit {
            stopMouseMovedTracking()
            stopTitlebarClickMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshMouseMovedTracking()
            refreshTitlebarClickMonitor()
        }

        func refreshMouseMovedTracking() {
            guard isEnabled, let window else {
                stopMouseMovedTracking()
                stopTitlebarClickMonitor()
                return
            }
            guard !isTrackingMouseMovedEvents || mouseMovedWindow !== window else { return }
            stopMouseMovedTracking()
            WindowMouseMovedEventsCoordinator.shared.enable(for: window, owner: self)
            mouseMovedWindow = window
            isTrackingMouseMovedEvents = true
            refreshTitlebarClickMonitor()
        }

        private func stopMouseMovedTracking() {
            if let mouseMovedWindow {
                WindowMouseMovedEventsCoordinator.shared.disable(for: mouseMovedWindow, owner: self)
            } else {
                WindowMouseMovedEventsCoordinator.shared.disableOwner(self)
            }
            mouseMovedWindow = nil
            isTrackingMouseMovedEvents = false
        }

        private func refreshTitlebarClickMonitor() {
            guard isEnabled, window != nil else {
                stopTitlebarClickMonitor()
                return
            }
            guard titlebarClickMonitor == nil else { return }
            titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handleTitlebarMouseDown(event) ?? event
            }
        }

        private func stopTitlebarClickMonitor() {
            if let titlebarClickMonitor {
                NSEvent.removeMonitor(titlebarClickMonitor)
            }
            titlebarClickMonitor = nil
            lastTitlebarClick = nil
        }

        private func handleTitlebarMouseDown(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window else { return event }
            guard let locationInWindow = locationInWindow(for: event, window: window) else {
                lastTitlebarClick = nil
                return event
            }
            let contentBounds = window.contentView?.bounds ?? NSRect(
                x: 0,
                y: 0,
                width: window.frame.width,
                height: window.frame.height
            )
            guard MinimalModeTitlebarBand.isMinimalModeWindowTitlebarClickCandidate(
                isMinimalMode: WorkspacePresentationModeSettings.isMinimal(),
                isFullScreen: window.styleMask.contains(.fullScreen),
                isMainWindow: window.isMainWorkspaceWindow,
                locationInWindow: locationInWindow,
                contentBounds: contentBounds,
                titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
            ) else {
                lastTitlebarClick = nil
                return event
            }
            guard !minimalModeTitlebarDoubleClickShouldDefer(
                window: window,
                locationInWindow: locationInWindow
            ) else {
                lastTitlebarClick = nil
                return event
            }

            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
                _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    let count = (payload["minimalTitlebarEventSurfaceMouseDownCount"] as? String).flatMap(Int.init) ?? 0
                    payload["minimalTitlebarEventSurfaceMouseDownCount"] = String(count + 1)
                    payload["minimalTitlebarEventSurfaceLastPoint"] = locationInWindow.titlebarDragPointDescription
                    payload["minimalTitlebarEventSurfaceLastClickCount"] = String(event.clickCount)
                }
            }
            #endif

            let currentClick = MinimalModeTitlebarClickRecord(
                windowNumber: window.windowNumber,
                timestamp: event.timestamp,
                locationInWindow: locationInWindow
            )
            let isDoubleClick = currentClick.formsDoubleClick(
                clickCount: event.clickCount,
                previous: lastTitlebarClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: MinimalModeTitlebarClickRecord.syntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                lastTitlebarClick = currentClick
                return event
            }
            lastTitlebarClick = nil
            let result = TitlebarDoubleClickHandlingResult.handle(window: window, behavior: .standardAction)
            return result.consumesEvent ? nil : event
        }

        private func locationInWindow(for event: NSEvent, window: NSWindow) -> NSPoint? {
            if event.window === window {
                return event.locationInWindow
            }
            guard event.window == nil else { return nil }
            let screenPoint = NSEvent.mouseLocation
            guard window.frame.insetBy(dx: -1, dy: -1).contains(screenPoint) else { return nil }
            return window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PassthroughView else { return }
        view.isEnabled = isEnabled
        view.refreshMouseMovedTracking()
    }
}
