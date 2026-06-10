import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode titlebar control hit regions
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

