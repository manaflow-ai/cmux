import AppKit

extension WindowTerminalHostView {
    func hasHostedTerminal(at point: NSPoint) -> Bool {
        for subview in subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView,
                  !hostedView.isHidden,
                  hostedView.alphaValue > 0,
                  hostedView.frame.contains(point) else { continue }
            return true
        }
        return false
    }

    static func hasHostedTerminal(atWindowPoint windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let rootView = window.contentView?.superview ?? window.contentView else { return false }
        return hasHostedTerminal(atWindowPoint: windowPoint, in: rootView)
    }

    private static func hasHostedTerminal(atWindowPoint windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }

        if let hostView = view as? WindowTerminalHostView {
            let pointInHost = hostView.convert(windowPoint, from: nil)
            if hostView.bounds.contains(pointInHost), hostView.hasHostedTerminal(at: pointInHost) {
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
