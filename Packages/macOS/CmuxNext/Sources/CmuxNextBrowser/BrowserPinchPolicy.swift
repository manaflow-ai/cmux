public import AppKit

/// Pinch zoom belongs to browser documents, including their separate Chromium input windows.
@MainActor
public enum BrowserPinchPolicy {
    public static func allows(_ event: NSEvent) -> Bool {
        guard event.type == .magnify else { return true }
        guard let window = event.window else { return false }
        return allows(in: window, at: event.locationInWindow)
    }

    public static func allows(in window: NSWindow, at point: NSPoint) -> Bool {
        for tab in CEFRuntime.shared.tabsByBrowser.values where tab.isPageWindow(window) {
            return tab.pageThemeSurface == nil
        }
        guard let content = window.contentView else { return false }
        var view = content.hitTest(content.convert(point, from: nil))
        while let current = view {
            if current is WebKitWebView { return true }
            if let host = current as? CEFHostView {
                return CEFRuntime.shared.tabsByBrowser.values.contains {
                    $0.host.hostView === host && $0.host.visibleTab === $0 && $0.pageThemeSurface == nil
                }
            }
            view = current.superview
        }
        return false
    }
}
