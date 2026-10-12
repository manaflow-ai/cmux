#if DEBUG
public import AppKit

extension AgentPaneView {
    /// DEBUG automation only (`debug.key`, `debug.agent_pane click`), for a window that is not
    /// key: AppKit sends a key to the key window and holds back a first click, so the app
    /// delivers that event itself, and first runs the handler that the local monitor runs for a
    /// real event. The gesture rule is the same; Release builds have no such entry.
    public func debugRunGestureMonitor(_ event: NSEvent) { monitored(event) }

    /// The left mouse downs and ups the page's web view has received (DEBUG automation).
    public var debugWebViewMouseCounts: (down: Int, up: Int) {
        guard let view = webView as? AgentPaneWKWebView else { return (0, 0) }
        return (view.debugMouseDowns, view.debugMouseUps)
    }
}
#endif
