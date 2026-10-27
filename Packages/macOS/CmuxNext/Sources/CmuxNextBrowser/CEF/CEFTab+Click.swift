import Foundation

extension CEFTab {
    /// A left click at `x`, `y` (view points) as the person's own (`CefBrowserHost::SendMouseClickEvent`,
    /// fork API 29), with no DevTools session. False when the fork has no native click or the
    /// browser is gone; the caller then uses DevTools input.
    public func sendClick(x: Double, y: Double) -> Bool {
        guard runtime.forkFeatures.rendererPaths, let browserID, !isClosed, let click = runtime.shim?.tabSendClick else { return false }
        return click(browserID, x, y, 0, 0, 1) == 1
    }

    /// The mouse moves to `x`, `y` (view points) with no button held, as the person's own
    /// (`CefBrowserHost::SendMouseMoveEvent`, ``CEFForkFeatures/mouseMove``), with no DevTools session: the page
    /// gets real `:hover` and enter events. False when the fork has no native move or the browser is gone; the
    /// caller then uses DevTools input.
    public func sendMouseMove(x: Double, y: Double) -> Bool {
        guard runtime.forkFeatures.mouseMove, let browserID, !isClosed, let move = runtime.shim?.tabSendMouseMove else { return false }
        return move(browserID, x, y, 0) == 1
    }
}
