import AppKit
import Bonsplit
import SwiftUI

enum WindowMouseMovedEventsCoordinator {
    private struct Record {
        weak var window: NSWindow?
        let previousValue: Bool
        var owners: Set<ObjectIdentifier>
    }

    private nonisolated(unsafe) static var records: [ObjectIdentifier: Record] = [:]
    private nonisolated static let lock = NSLock()

    static func enable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        let ownerKey = ObjectIdentifier(owner)
        if var record = records[windowKey] {
            record.owners.insert(ownerKey)
            records[windowKey] = record
        } else {
            records[windowKey] = Record(
                window: window,
                previousValue: window.acceptsMouseMovedEvents,
                owners: [ownerKey]
            )
        }
        window.acceptsMouseMovedEvents = true
    }

    static func disable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        guard var record = records[windowKey] else { return }
        record.owners.remove(ObjectIdentifier(owner))
        if record.owners.isEmpty {
            record.window?.acceptsMouseMovedEvents = record.previousValue
            records.removeValue(forKey: windowKey)
        } else {
            records[windowKey] = record
        }
    }

    static func disableOwner(_ owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let ownerKey = ObjectIdentifier(owner)
        for windowKey in Array(records.keys) {
            guard var record = records[windowKey] else { continue }
            record.owners.remove(ownerKey)
            if record.owners.isEmpty {
                record.window?.acceptsMouseMovedEvents = record.previousValue
                records.removeValue(forKey: windowKey)
            } else {
                records[windowKey] = record
            }
        }
    }
}

func windowDragHandleFormatPoint(_ point: NSPoint) -> String {
    String(format: "(%.1f,%.1f)", point.x, point.y)
}

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
        "point": windowDragHandleFormatPoint(point),
        "window_number": windowNumber,
        "window_present": window != nil
    ]
    for (name, value) in extraData {
        data[name] = value
    }
    sentryBreadcrumb(message, category: "titlebar.drag", data: data)
}

private func windowDragHandleShouldResolveActiveHitCapture(
    for eventType: NSEvent.EventType?,
    eventWindow: NSWindow?,
    dragHandleWindow: NSWindow?
) -> Bool {
    // We only need active hit resolution for titlebar mouse-down handling.
    // During launch, NSApp.currentEvent can transiently point at a stale
    // leftMouseDown from outside this window (for example Finder/Dock
    // activation). Treat those as passive events so we never walk SwiftUI/
    // AppKit hierarchy while initial layout is mutating it.
    guard eventType == .leftMouseDown else {
        return false
    }
    guard let dragHandleWindow else {
        // Test-only views may not be attached to a window.
        return true
    }
    guard let eventWindow else {
        return false
    }
    return eventWindow === dragHandleWindow
}

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
enum StandardTitlebarDoubleClickAction: Equatable {
    case miniaturize
    case zoom
    case none
}

enum TitlebarDoubleClickBehavior: Equatable {
    case standardAction
    case suppress
}

enum TitlebarDoubleClickHandlingResult: Equatable {
    case ignored
    case suppressed
    case performed(StandardTitlebarDoubleClickAction)

    var consumesEvent: Bool {
        self != .ignored
    }
}

func resolvedStandardTitlebarDoubleClickAction(globalDefaults: [String: Any]) -> StandardTitlebarDoubleClickAction {
    if let action = (globalDefaults["AppleActionOnDoubleClick"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() {
        switch action {
        case "minimize", "miniaturize":
            return .miniaturize
        case "maximize", "zoom", "fill":
            return .zoom
        case "none", "no action":
            return .none
        default:
            break
        }
    }

    if let miniaturizeOnDoubleClick = globalDefaults["AppleMiniaturizeOnDoubleClick"] as? Bool,
       miniaturizeOnDoubleClick {
        return .miniaturize
    }

    return .zoom
}

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
@MainActor
@discardableResult
func performStandardTitlebarDoubleClick(window: NSWindow?) -> StandardTitlebarDoubleClickAction? {
    guard let window else { return nil }

    let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    let action = resolvedStandardTitlebarDoubleClickAction(globalDefaults: globalDefaults)
    switch action {
    case .miniaturize:
        window.miniaturize(nil)
    case .zoom:
        window.zoom(nil)
    case .none:
        break
    }
    return action
}

@discardableResult
@MainActor
func handleTitlebarDoubleClick(
    window: NSWindow?,
    behavior: TitlebarDoubleClickBehavior
) -> TitlebarDoubleClickHandlingResult {
    switch behavior {
    case .standardAction:
        guard let action = performStandardTitlebarDoubleClick(window: window) else {
            return .ignored
        }
        return .performed(action)
    case .suppress:
        return .suppressed
    }
}

private enum WindowDragHandleAssociatedObjectKeys {
    private static let suppressionDepthToken = NSObject()

    static let suppressionDepth = UnsafeRawPointer(Unmanaged.passUnretained(suppressionDepthToken).toOpaque())
}

func beginWindowDragSuppression(window: NSWindow?) -> Int? {
    guard let window else { return nil }
    let current = windowDragSuppressionDepth(window: window)
    let next = current + 1
    objc_setAssociatedObject(
        window,
        WindowDragHandleAssociatedObjectKeys.suppressionDepth,
        NSNumber(value: next),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return next
}

@discardableResult
func endWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    let current = windowDragSuppressionDepth(window: window)
    let next = max(0, current - 1)
    if next == 0 {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    } else {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    return next
}

func windowDragSuppressionDepth(window: NSWindow?) -> Int {
    guard let window,
          let value = objc_getAssociatedObject(window, WindowDragHandleAssociatedObjectKeys.suppressionDepth) as? NSNumber else {
        return 0
    }
    return value.intValue
}

func isWindowDragSuppressed(window: NSWindow?) -> Bool {
    windowDragSuppressionDepth(window: window) > 0
}

@discardableResult
func clearWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    var depth = windowDragSuppressionDepth(window: window)
    while depth > 0 {
        depth = endWindowDragSuppression(window: window)
    }
    return depth
}

/// Temporarily enables window movability for explicit drag-handle drags, then
/// restores the previous movability state after `body` finishes.
@discardableResult
func withTemporaryWindowMovableEnabled(window: NSWindow?, _ body: () -> Void) -> Bool? {
    guard let window else {
        body()
        return nil
    }

    let previousMovableState = window.isMovable
    if !previousMovableState {
        window.isMovable = true
    }
    defer {
        if window.isMovable != previousMovableState {
            window.isMovable = previousMovableState
        }
    }

    body()
    return previousMovableState
}

/// SwiftUI/AppKit hosting wrappers can appear as the top hit even for empty
/// titlebar space. Treat those as pass-through so explicit sibling checks decide.
func windowDragHandleShouldTreatTopHitAsPassiveHost(_ view: NSView) -> Bool {
    let className = String(describing: type(of: view))
    if className.contains("HostContainerView")
        || className.contains("AppKitWindowHostingView")
        || className.contains("NSHostingView") {
        return true
    }
    if let window = view.window, view === window.contentView {
        return true
    }
    return false
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

struct MinimalModeTitlebarControlHitRegionView: NSViewRepresentable {
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

enum MinimalModeSidebarTitlebarControlsMetrics {
    static let leadingInset: CGFloat = 72
    static let hostWidth: CGFloat = 124
    static let hostHeight: CGFloat = 28
}

enum MinimalModeSidebarControlActionSlot: Int {
    case toggleSidebar
    case showNotifications
    case newTab

    var accessibilityIdentifier: String {
        switch self {
        case .toggleSidebar:
            return "titlebarControl.toggleSidebar"
        case .showNotifications:
            return "titlebarControl.showNotifications"
        case .newTab:
            return "titlebarControl.newTab"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .toggleSidebar:
            return String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar")
        case .showNotifications:
            return String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications")
        case .newTab:
            return String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace")
        }
    }

    var debugName: String {
        switch self {
        case .toggleSidebar:
            return "toggleSidebar"
        case .showNotifications:
            return "showNotifications"
        case .newTab:
            return "newTab"
        }
    }
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

private enum MinimalModeSidebarTitlebarControlAssociatedKeys {
    private static let sidebarVisibleToken = NSObject()

    static let sidebarVisible = UnsafeRawPointer(Unmanaged.passUnretained(sidebarVisibleToken).toOpaque())
}

func setMinimalModeSidebarTitlebarControlsAvailable(_ isAvailable: Bool, in window: NSWindow?) {
    guard let window else { return }
    objc_setAssociatedObject(
        window,
        MinimalModeSidebarTitlebarControlAssociatedKeys.sidebarVisible,
        NSNumber(value: isAvailable),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

func minimalModeSidebarTitlebarControlsAreAvailable(in window: NSWindow) -> Bool {
    guard let value = objc_getAssociatedObject(
        window,
        MinimalModeSidebarTitlebarControlAssociatedKeys.sidebarVisible
    ) as? NSNumber else {
        return true
    }
    return value.boolValue
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
    let isMainWindow = isMainWorkspaceWindow(window)
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return false
    }
    guard minimalModeSidebarTitlebarControlsAreAvailable(in: window) else {
        return false
    }

    if MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
        locationInWindow,
        in: window
    ) {
        return true
    }

    guard isPointInMinimalModeTitlebarBand(
        isEnabled: true,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ) else { return false }

    let minX = MinimalModeSidebarTitlebarControlsMetrics.leadingInset
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
    let isMainWindow = isMainWorkspaceWindow(window)
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return nil
    }
    guard minimalModeSidebarTitlebarControlsAreAvailable(in: window) else {
        return nil
    }

    if let registeredSlot = MinimalModeTitlebarControlHitRegionRegistry.minimalModeSidebarControlActionSlot(
        forWindowPoint: locationInWindow,
        in: window
    ) {
        return registeredSlot
    }

    guard isPointInMinimalModeTitlebarBand(
        isEnabled: true,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ) else { return nil }

    let localPoint = NSPoint(
        x: locationInWindow.x - MinimalModeSidebarTitlebarControlsMetrics.leadingInset,
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
    let isMainWindow = isMainWorkspaceWindow(window)
    let sidebarControlsAvailable = minimalModeSidebarTitlebarControlsAreAvailable(in: window)
    let contentBounds = window.contentView?.bounds ?? .zero
    let inTitlebarBand = isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: isMinimal,
        isFullScreen: isFullScreen,
        isMainWindow: isMainWindow,
        locationInWindow: locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: MinimalModeChromeMetrics.titlebarHeight
    )
    let minX = MinimalModeSidebarTitlebarControlsMetrics.leadingInset
    let maxX = minX + MinimalModeSidebarTitlebarControlsMetrics.hostWidth
    let inXRange = (locationInWindow.x >= minX && locationInWindow.x <= maxX)
        || MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
            locationInWindow,
            in: window
        )
    _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
        let count = (payload["minimalSidebarHoverEventCount"] as? String).flatMap(Int.init) ?? 0
        payload["minimalSidebarHoverEventCount"] = String(count + 1)
        payload["minimalSidebarHoverEventType"] = String(describing: eventType)
        payload["minimalSidebarHoverWindowNumber"] = String(window.windowNumber)
        payload["minimalSidebarHoverPoint"] = windowDragHandleFormatPoint(locationInWindow)
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
func windowDragHandleShouldCaptureHit(
    _ point: NSPoint,
    in dragHandleView: NSView,
    eventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    eventWindow: NSWindow? = NSApp.currentEvent?.window
) -> Bool {
    let dragHandleWindow = dragHandleView.window

    // Suppression recovery runs first so stale depth is cleared even for
    // passive events — the associated-object reads/writes here are pure ObjC
    // runtime calls and cannot trigger Swift exclusive-access violations.
    if isWindowDragSuppressed(window: dragHandleWindow) {
        // Recover from stale suppression if a prior interaction missed cleanup.
        // We only keep suppression active while the left mouse button is down.
        if (NSEvent.pressedMouseButtons & 0x1) == 0 {
            let clearedDepth = clearWindowDragSuppression(window: dragHandleWindow)
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
                "titlebar.dragHandle.hitTest suppressionRecovered clearedDepth=\(clearedDepth) point=\(windowDragHandleFormatPoint(point))"
            )
            #endif
        } else {
        #if DEBUG
            let depth = windowDragSuppressionDepth(window: dragHandleWindow)
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false reason=suppressed depth=\(depth) point=\(windowDragHandleFormatPoint(point))"
            )
        #endif
            return false
        }
    }

    // Bail out before the view-hierarchy walk so we never re-enter SwiftUI
    // views during a layout pass — which causes exclusive-access crashes (#490).
    if !windowDragHandleShouldResolveActiveHitCapture(
        for: eventType,
        eventWindow: eventWindow,
        dragHandleWindow: dragHandleWindow
    ) {
        #if DEBUG
        let eventTypeDescription = eventType.map { String(describing: $0) } ?? "nil"
        let eventWindowNumber = eventWindow?.windowNumber ?? -1
        let dragWindowNumber = dragHandleWindow?.windowNumber ?? -1
        cmuxDebugLog(
            "titlebar.dragHandle.hitTest capture=false reason=passiveEvent eventType=\(eventTypeDescription) eventWindow=\(eventWindowNumber) dragWindow=\(dragWindowNumber) point=\(windowDragHandleFormatPoint(point))"
        )
        #endif
        return false
    }

    guard dragHandleView.bounds.contains(point) else {
        #if DEBUG
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=outside point=\(windowDragHandleFormatPoint(point))")
        #endif
        return false
    }

    guard let superview = dragHandleView.superview else {
        #if DEBUG
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=true reason=noSuperview point=\(windowDragHandleFormatPoint(point))")
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
        cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=reentrant point=\(windowDragHandleFormatPoint(point))")
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
            let passiveHostHit = windowDragHandleShouldTreatTopHitAsPassiveHost(hitView)
            if passiveHostHit {
                #if DEBUG
                cmuxDebugLog(
                    "titlebar.dragHandle.hitTest capture=defer point=\(windowDragHandleFormatPoint(point)) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=true"
                )
                #endif
                continue
            }
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=false"
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
    cmuxDebugLog("titlebar.dragHandle.hitTest capture=true point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount)")
    #endif
    return true
}

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
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
        }

        required init?(coder: NSCoder) {
            self.doubleClickBehavior = .standardAction
            super.init(coder: coder)
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
                "titlebar.dragHandle.hitTestResult capture=\(shouldCapture) point=\(windowDragHandleFormatPoint(point)) window=\(window != nil)"
            )
            #endif
            return shouldCapture ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            #if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            let depth = windowDragSuppressionDepth(window: window)
            cmuxDebugLog(
                "titlebar.dragHandle.mouseDown point=\(windowDragHandleFormatPoint(point)) clickCount=\(event.clickCount) depth=\(depth)"
            )
            #endif

            if event.clickCount >= 2 {
                let result = handleTitlebarDoubleClick(
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

            guard !isWindowDragSuppressed(window: window) else {
                #if DEBUG
                cmuxDebugLog("titlebar.dragHandle.mouseDownIgnored reason=suppressed")
                #endif
                return
            }

            if let window {
                let previousMovableState = withTemporaryWindowMovableEnabled(window: window) {
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
            guard !isMinimalModeTitlebarControlHit(window: window, locationInWindow: event.locationInWindow) else {
                coordinator.lastClick = nil
                return event
            }
            let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                locationInWindow: event.locationInWindow,
                windowNumber: window.windowNumber,
                previous: coordinator.lastClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: minimalModeTitlebarSyntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                coordinator.lastClick = MinimalModeTitlebarClickRecord(
                    windowNumber: window.windowNumber,
                    timestamp: event.timestamp,
                    locationInWindow: event.locationInWindow
                )
                return event
            }
            coordinator.lastClick = nil

            let result = handleTitlebarDoubleClick(
                window: window,
                behavior: coordinator.doubleClickBehavior
            )
            return result.consumesEvent ? nil : event
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.doubleClickBehavior = doubleClickBehavior
    }
}

func shouldHandleMinimalModeTitlebarDoubleClick(
    isEnabled: Bool,
    clickCount: Int,
    point: NSPoint,
    bounds: NSRect,
    topStripHeight: CGFloat
) -> Bool {
    guard clickCount >= 2 else {
        return false
    }
    return isPointInMinimalModeTitlebarBand(
        isEnabled: isEnabled,
        point: point,
        bounds: bounds,
        topStripHeight: topStripHeight
    )
}

func isPointInMinimalModeTitlebarBand(
    isEnabled: Bool,
    point: NSPoint,
    bounds: NSRect,
    topStripHeight: CGFloat
) -> Bool {
    guard isEnabled, topStripHeight > 0, bounds.contains(point) else {
        return false
    }
    let clampedHeight = min(max(0, topStripHeight), bounds.height)
    return point.y >= bounds.maxY - clampedHeight
}

struct MinimalModeTitlebarClickRecord: Equatable {
    let windowNumber: Int
    let timestamp: TimeInterval
    let locationInWindow: NSPoint
}

func minimalModeTitlebarClickFormsDoubleClick(
    clickCount: Int,
    timestamp: TimeInterval,
    locationInWindow: NSPoint,
    windowNumber: Int,
    previous: MinimalModeTitlebarClickRecord?,
    doubleClickInterval: TimeInterval,
    doubleClickIntervalTolerance: TimeInterval = 0,
    maxDistance: CGFloat = 4
) -> Bool {
    if clickCount >= 2 {
        return true
    }
    let allowedInterval = max(0, doubleClickInterval) + max(0, doubleClickIntervalTolerance)
    guard let previous,
          previous.windowNumber == windowNumber,
          timestamp - previous.timestamp >= 0,
          timestamp - previous.timestamp <= allowedInterval else {
        return false
    }

    let dx = locationInWindow.x - previous.locationInWindow.x
    let dy = locationInWindow.y - previous.locationInWindow.y
    return hypot(dx, dy) <= maxDistance
}

let minimalModeTitlebarSyntheticDoubleClickTolerance: TimeInterval = {
    #if DEBUG
    0.15
    #else
    0
    #endif
}()

func minimalModeTitlebarDoubleClickBandHeight(for window: NSWindow) -> CGFloat {
    MinimalModeChromeMetrics.titlebarHeight
}

func isMainWorkspaceWindow(_ window: NSWindow) -> Bool {
    guard let raw = window.identifier?.rawValue else { return false }
    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
}

func shouldHandleMinimalModeWindowTitlebarDoubleClick(
    isMinimalMode: Bool,
    isFullScreen: Bool,
    isMainWindow: Bool,
    clickCount: Int,
    locationInWindow: NSPoint,
    contentBounds: NSRect,
    titlebarBandHeight: CGFloat
) -> Bool {
    shouldHandleMinimalModeTitlebarDoubleClick(
        isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
        clickCount: clickCount,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: titlebarBandHeight
    )
}

func isMinimalModeWindowTitlebarClickCandidate(
    isMinimalMode: Bool,
    isFullScreen: Bool,
    isMainWindow: Bool,
    locationInWindow: NSPoint,
    contentBounds: NSRect,
    titlebarBandHeight: CGFloat
) -> Bool {
    isPointInMinimalModeTitlebarBand(
        isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: titlebarBandHeight
    )
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
    return shouldHandleMinimalModeWindowTitlebarDoubleClick(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: isMainWorkspaceWindow(window),
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
    return isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: isMainWorkspaceWindow(window),
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
            WindowMouseMovedEventsCoordinator.enable(for: window, owner: self)
            mouseMovedWindow = window
            isTrackingMouseMovedEvents = true
            refreshTitlebarClickMonitor()
        }

        private func stopMouseMovedTracking() {
            if let mouseMovedWindow {
                WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
            } else {
                WindowMouseMovedEventsCoordinator.disableOwner(self)
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
            guard isMinimalModeWindowTitlebarClickCandidate(
                isMinimalMode: WorkspacePresentationModeSettings.isMinimal(),
                isFullScreen: window.styleMask.contains(.fullScreen),
                isMainWindow: isMainWorkspaceWindow(window),
                locationInWindow: locationInWindow,
                contentBounds: contentBounds,
                titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
            ) else {
                lastTitlebarClick = nil
                return event
            }
            guard !isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow) else {
                lastTitlebarClick = nil
                return event
            }

            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
                _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    let count = (payload["minimalTitlebarEventSurfaceMouseDownCount"] as? String).flatMap(Int.init) ?? 0
                    payload["minimalTitlebarEventSurfaceMouseDownCount"] = String(count + 1)
                    payload["minimalTitlebarEventSurfaceLastPoint"] = windowDragHandleFormatPoint(locationInWindow)
                    payload["minimalTitlebarEventSurfaceLastClickCount"] = String(event.clickCount)
                }
            }
            #endif

            let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                locationInWindow: locationInWindow,
                windowNumber: window.windowNumber,
                previous: lastTitlebarClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: minimalModeTitlebarSyntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                lastTitlebarClick = MinimalModeTitlebarClickRecord(
                    windowNumber: window.windowNumber,
                    timestamp: event.timestamp,
                    locationInWindow: locationInWindow
                )
                return event
            }
            lastTitlebarClick = nil
            let result = handleTitlebarDoubleClick(window: window, behavior: .standardAction)
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
