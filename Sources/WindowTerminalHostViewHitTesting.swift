import AppKit

extension WindowTerminalHostView {
    func hostedTerminalHitView(at point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView,
                  !hostedView.isHidden,
                  hostedView.alphaValue > 0,
                  hostedView.frame.contains(point) else { continue }

            return hostedView.hitTest(point) ?? hostedView
        }
        return nil
    }

    func hostedTerminalHitViewResolver(at point: NSPoint) -> () -> NSView? {
        var cachedHitView: NSView?
        var didResolve = false
        return {
            if !didResolve {
                cachedHitView = self.hostedTerminalHitView(at: point)
                didResolve = true
            }
            return cachedHitView
        }
    }

    func hasHostedTerminal(at point: NSPoint) -> Bool {
        hasHostedTerminal(at: point, in: self)
    }

    private func hasHostedTerminal(at point: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }
        let pointInView = view.convert(point, from: self)
        guard view.bounds.contains(pointInView) else { return false }
        if view is GhosttySurfaceScrollView { return true }
        for subview in view.subviews.reversed() {
            if hasHostedTerminal(at: point, in: subview) { return true }
        }
        return false
    }

    static func hasHostedTerminal(atWindowPoint windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView?.superview ?? window.contentView else { return false }
        return hasHostedTerminal(atWindowPoint: windowPoint, in: rootView)
    }

    private static func hasHostedTerminal(atWindowPoint windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }
        let pointInView = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(pointInView) else { return false }

        if let hostView = view as? WindowTerminalHostView {
            let pointInHost = hostView.convert(windowPoint, from: nil)
            if hostView.hasHostedTerminal(at: pointInHost) {
                return true
            }
        }

        for subview in view.subviews.reversed() {
            if hasHostedTerminal(atWindowPoint: windowPoint, in: subview) {
                return true
            }
        }

        return false
    }
}

func minimalModeTitlebarDoubleClickShouldDefer(
    window: NSWindow,
    locationInWindow: NSPoint
) -> Bool {
    isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow)
        || WindowTerminalHostView.hasHostedTerminal(atWindowPoint: locationInWindow, in: window)
}
