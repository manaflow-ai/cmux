public import AppKit

/// AppKit asks this delegate for the screen-coordinate tracking bounds. Forward every other
/// callback to the menu's original delegate, including WebKit's action and dismissal handling.
private nonisolated final class MenuTrackingConfinement: NSObject, NSMenuDelegate {
    @MainActor static let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    let original: (any NSMenuDelegate)?
    let bounds: CGRect

    init(original: (any NSMenuDelegate)?, bounds: CGRect) {
        self.original = original
        self.bounds = bounds
    }

    override func responds(to selector: Selector?) -> Bool {
        guard let selector else { return false }
        return super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector?) -> Any? {
        guard let selector else { return nil }
        return original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    @MainActor
    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        guard let previous = original?.confinementRect?(for: menu, on: screen), !previous.isEmpty else { return bounds }
        let intersection = previous.intersection(bounds)
        return intersection.isEmpty ? previous : intersection
    }
}

extension NSMenu {
    /// WebKit presents its own NSMenu. Its public delegate hook lets the window choose the side
    /// before AppKit tracks it, preserving WebKit's menu items and their actions.
    @MainActor
    public func confineTracking(at event: NSEvent, in view: NSView) {
        guard let window = view.window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let screen = PopupPlacement.screen(for: CGRect(origin: point, size: .zero), fallback: window)?.visibleFrame ?? window.frame
        let viewport = PopupPlacement.pointerViewport(in: window, screen: screen)
        confineTracking(to: PopupPlacement.pointerConfinement(at: point, size: drawnSize, viewport: viewport))
    }

    @MainActor
    func confineTracking(to bounds: CGRect) {
        restoreTrackingDelegate()
        let proxy = MenuTrackingConfinement(original: delegate, bounds: bounds)
        objc_setAssociatedObject(self, MenuTrackingConfinement.key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        delegate = proxy
    }

    /// Release the temporary delegate when AppKit closes the menu.
    @MainActor
    public func restoreTrackingDelegate() {
        guard let proxy = objc_getAssociatedObject(self, MenuTrackingConfinement.key) as? MenuTrackingConfinement else { return }
        if delegate === proxy { delegate = proxy.original }
        objc_setAssociatedObject(self, MenuTrackingConfinement.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
