#if DEBUG
public import AppKit

extension AgentPaneView {
    /// DEBUG automation only (`debug.key`, `debug.agent_pane click`), for a window that is not
    /// key: AppKit sends a key to the key window and holds back a first click, so the app
    /// delivers that event itself, and first runs the handler that the local monitor runs for a
    /// real event. The gesture rule is the same; Release builds have no such entry.
    public func debugRunGestureMonitor(_ event: NSEvent) { monitored(event) }
}
#endif
