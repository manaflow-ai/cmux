import AppKit
import Bonsplit
import SwiftUI

private func windowDragHandleFormatPoint(_ point: NSPoint) -> String {
    String(format: "(%.1f,%.1f)", point.x, point.y)
}

/// Runs the same action macOS titlebars use for double-click:
/// zoom by default, or minimize when the user preference is set.
@discardableResult
func performStandardTitlebarDoubleClick(window: NSWindow?) -> Bool {
    guard let window else { return false }

    let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    if let action = (globalDefaults["AppleActionOnDoubleClick"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() {
        switch action {
        case "minimize":
            window.miniaturize(nil)
            return true
        case "none":
            return false
        case "maximize", "zoom":
            window.zoom(nil)
            return true
        default:
            break
        }
    }

    if let miniaturizeOnDoubleClick = globalDefaults["AppleMiniaturizeOnDoubleClick"] as? Bool,
       miniaturizeOnDoubleClick {
        window.miniaturize(nil)
        return true
    }

    window.zoom(nil)
    return true
}

private var windowDragSuppressionDepthKey: UInt8 = 0
private var windowDragTopHitResolutionDepthKey: UInt8 = 0

func beginWindowDragSuppression(window: NSWindow?) -> Int? {
    guard let window else { return nil }
    let current = windowDragSuppressionDepth(window: window)
    let next = current + 1
    objc_setAssociatedObject(
        window,
        &windowDragSuppressionDepthKey,
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
        objc_setAssociatedObject(window, &windowDragSuppressionDepthKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    } else {
        objc_setAssociatedObject(
            window,
            &windowDragSuppressionDepthKey,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    return next
}

func windowDragSuppressionDepth(window: NSWindow?) -> Int {
    guard let window,
          let value = objc_getAssociatedObject(window, &windowDragSuppressionDepthKey) as? NSNumber else {
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

private enum WindowDragHandleHitTestState {
    static func depth(window: NSWindow?) -> Int {
        guard let window,
              let value = objc_getAssociatedObject(window, &windowDragTopHitResolutionDepthKey) as? NSNumber else {
            return 0
        }
        return value.intValue
    }

    static func begin(window: NSWindow?) {
        guard let window else { return }
        let next = depth(window: window) + 1
        objc_setAssociatedObject(
            window,
            &windowDragTopHitResolutionDepthKey,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @discardableResult
    static func end(window: NSWindow?) -> Int {
        guard let window else { return 0 }
        let current = depth(window: window)
        let next = max(0, current - 1)
        if next == 0 {
            objc_setAssociatedObject(
                window,
                &windowDragTopHitResolutionDepthKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                window,
                &windowDragTopHitResolutionDepthKey,
                NSNumber(value: next),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        return next
    }

    static func isResolvingTopHit(window: NSWindow?) -> Bool {
        depth(window: window) > 0
    }
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

/// Returns whether the titlebar drag handle should capture a hit at `point`.
/// We only claim the hit when no sibling view already handles it, so interactive
/// controls layered in the titlebar (e.g. proxy folder icon) keep their gestures.
func windowDragHandleShouldCaptureHit(_ point: NSPoint, in dragHandleView: NSView) -> Bool {
    if isWindowDragSuppressed(window: dragHandleView.window) {
        // Recover from stale suppression if a prior interaction missed cleanup.
        // We only keep suppression active while the left mouse button is down.
        if (NSEvent.pressedMouseButtons & 0x1) == 0 {
            let clearedDepth = clearWindowDragSuppression(window: dragHandleView.window)
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTest suppressionRecovered clearedDepth=\(clearedDepth) point=\(windowDragHandleFormatPoint(point))"
            )
            #endif
        } else {
        #if DEBUG
            let depth = windowDragSuppressionDepth(window: dragHandleView.window)
            dlog(
                "titlebar.dragHandle.hitTest capture=false reason=suppressed depth=\(depth) point=\(windowDragHandleFormatPoint(point))"
            )
        #endif
            return false
        }
    }

    guard dragHandleView.bounds.contains(point) else {
        #if DEBUG
        dlog("titlebar.dragHandle.hitTest capture=false reason=outside point=\(windowDragHandleFormatPoint(point))")
        #endif
        return false
    }

    guard let superview = dragHandleView.superview else {
        #if DEBUG
        dlog("titlebar.dragHandle.hitTest capture=true reason=noSuperview point=\(windowDragHandleFormatPoint(point))")
        #endif
        return true
    }

    if let window = dragHandleView.window,
       let contentView = window.contentView,
       !WindowDragHandleHitTestState.isResolvingTopHit(window: window) {
        let pointInWindow = dragHandleView.convert(point, to: nil)
        let pointInContent = contentView.convert(pointInWindow, from: nil)

        WindowDragHandleHitTestState.begin(window: window)
        defer {
            WindowDragHandleHitTestState.end(window: window)
        }
        let topHit = contentView.hitTest(pointInContent)

        if let topHit {
            let ownsTopHit = topHit === dragHandleView || topHit.isDescendant(of: dragHandleView)
            let topHitBelongsToTitlebarOverlay = topHit === superview || topHit.isDescendant(of: superview)
            let isPassiveHostHit = windowDragHandleShouldTreatTopHitAsPassiveHost(topHit)
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTest capture=\(ownsTopHit) strategy=windowTopHit point=\(windowDragHandleFormatPoint(point)) top=\(type(of: topHit)) inTitlebarOverlay=\(topHitBelongsToTitlebarOverlay) passiveHost=\(isPassiveHostHit)"
            )
            #endif
            if ownsTopHit {
                return true
            }
            // Underlay content can transiently overlap titlebar space (notably browser
            // chrome/webview layers). Only let top-hits block capture when they belong
            // to this titlebar overlay stack.
            if topHitBelongsToTitlebarOverlay && !isPassiveHostHit {
                return false
            }
        }
    }

    #if DEBUG
    let siblingCount = superview.subviews.count
    #endif

    for sibling in superview.subviews.reversed() {
        guard sibling !== dragHandleView else { continue }
        guard !sibling.isHidden, sibling.alphaValue > 0 else { continue }

        let pointInSibling = dragHandleView.convert(point, to: sibling)
        if let hitView = sibling.hitTest(pointInSibling) {
            let passiveHostHit = windowDragHandleShouldTreatTopHitAsPassiveHost(hitView)
            if passiveHostHit {
                #if DEBUG
                dlog(
                    "titlebar.dragHandle.hitTest capture=defer point=\(windowDragHandleFormatPoint(point)) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=true"
                )
                #endif
                continue
            }
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTest capture=false point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount) sibling=\(type(of: sibling)) hit=\(type(of: hitView)) passiveHost=false"
            )
            #endif
            return false
        }
    }

    #if DEBUG
    dlog("titlebar.dragHandle.hitTest capture=true point=\(windowDragHandleFormatPoint(point)) siblingCount=\(siblingCount)")
    #endif
    return true
}

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op
    }

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let shouldCapture = windowDragHandleShouldCaptureHit(point, in: self)
            #if DEBUG
            dlog(
                "titlebar.dragHandle.hitTestResult capture=\(shouldCapture) point=\(windowDragHandleFormatPoint(point)) window=\(window != nil)"
            )
            #endif
            return shouldCapture ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            #if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            let depth = windowDragSuppressionDepth(window: window)
            dlog(
                "titlebar.dragHandle.mouseDown point=\(windowDragHandleFormatPoint(point)) clickCount=\(event.clickCount) depth=\(depth)"
            )
            #endif

            if event.clickCount >= 2 {
                let handled = performStandardTitlebarDoubleClick(window: window)
                #if DEBUG
                dlog("titlebar.dragHandle.mouseDownDoubleClick handled=\(handled ? 1 : 0)")
                #endif
                if handled {
                    return
                }
            }

            guard !isWindowDragSuppressed(window: window) else {
                #if DEBUG
                dlog("titlebar.dragHandle.mouseDownIgnored reason=suppressed")
                #endif
                return
            }

            if let window {
                let previousMovableState = withTemporaryWindowMovableEnabled(window: window) {
                    window.performDrag(with: event)
                }
                #if DEBUG
                let restored = previousMovableState.map { String($0) } ?? "nil"
                dlog("titlebar.dragHandle.mouseDownComplete restoredMovable=\(restored) nowMovable=\(window.isMovable)")
                #endif
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
