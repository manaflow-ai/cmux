import Foundation

extension CEFTab {
    /// A left click at `x`, `y` (view points) as the person's own (`CefBrowserHost::SendMouseClickEvent`,
    /// fork API 29), with no DevTools session. False when the fork has no native click or the
    /// browser is gone; the caller then uses DevTools input.
    public func sendClick(x: Double, y: Double) -> Bool {
        guard runtime.forkFeatures.rendererPaths, let browserID, !isClosed, let click = runtime.shim?.tabSendClick else { return false }
        return click(browserID, x, y, 0, 0, 1) == 1
    }
}
