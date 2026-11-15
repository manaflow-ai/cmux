public import AppKit

/// Pinch zoom belongs to browser documents, including their separate Chromium input windows.
@MainActor
extension NSEvent {
    public var cmuxAllowsPinchZoom: Bool {
        guard type == .magnify else { return true }
        guard let window else { return false }
        return window.cmuxAllowsPinchZoom(at: locationInWindow)
    }
}

@MainActor
extension NSWindow {
    public func cmuxAllowsPinchZoom(at point: NSPoint) -> Bool {
        for tab in CEFRuntime.shared.tabsByBrowser.values where tab.isPageWindow(self) {
            return tab.pageThemeSurface == nil
        }
        guard let content = contentView else { return false }
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
