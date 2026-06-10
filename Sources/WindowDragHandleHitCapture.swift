import AppKit
import Bonsplit
import SwiftUI


// MARK: - Drag handle hit-capture decision and breadcrumb diagnostics
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

/// SwiftUI/AppKit hosting wrappers can appear as the top hit even for empty
/// titlebar space. Treat those as pass-through so explicit sibling checks decide.
///
/// Interactive titlebar controls are *not* identified here by their hit view.
/// They register their region with ``MinimalModeTitlebarControlHitRegionRegistry``
/// instead, which ``windowDragHandleShouldCaptureHit(_:in:eventType:eventWindow:)``
/// consults (via `isMinimalModeTitlebarControlHit`) before this sibling walk runs,
/// so a registered control already makes the drag handle yield.
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

    if let dragHandleWindow,
       eventType == .leftMouseDown {
        let windowPoint = dragHandleView.convert(point, to: nil)
        if BonsplitTabItemHitRegionRegistry.containsWindowPoint(windowPoint, in: dragHandleWindow) {
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTest capture=false reason=bonsplitPaneTab point=\(windowDragHandleFormatPoint(point))"
            )
            #endif
            return false
        }
    }

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

    if let dragHandleWindow {
        let locationInWindow = dragHandleView.convert(point, to: nil)
        if isMinimalModeTitlebarControlHit(window: dragHandleWindow, locationInWindow: locationInWindow) {
            #if DEBUG
            cmuxDebugLog("titlebar.dragHandle.hitTest capture=false reason=minimalTitlebarControl point=\(windowDragHandleFormatPoint(point))")
            #endif
            return false
        }
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

