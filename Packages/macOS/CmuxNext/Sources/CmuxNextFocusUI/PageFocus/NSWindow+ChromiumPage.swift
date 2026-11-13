public import AppKit
import WebKit

extension NSWindow {
    /// Whether this is a Chromium page window: a CEF Views window (`CefNSWindow`) that shows a page
    /// or a docked DevTools. Extension popups and other bubbles are plain Chromium widget windows.
    public var isChromiumPageWindow: Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return isKind(of: pageClass)
    }

    /// Whether web content has the keyboard here: a `WKWebView` (or a view inside one) is the first
    /// responder, or this is a Chromium page window. Decided by class, not by host, so a new web view
    /// host is covered without opting in (the native palette keys, `KeyRouter.routesNativePaletteKey`).
    public var webContentHasKeys: Bool {
        if isChromiumPageWindow { return true }
        var view = firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
