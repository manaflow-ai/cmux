public import AppKit

extension NSWindow {
    /// Whether this is a Chromium page window: a CEF Views window (`CefNSWindow`) that shows a page
    /// or a docked DevTools. Extension popups and other bubbles are plain Chromium widget windows.
    public var isChromiumPageWindow: Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return isKind(of: pageClass)
    }
}
