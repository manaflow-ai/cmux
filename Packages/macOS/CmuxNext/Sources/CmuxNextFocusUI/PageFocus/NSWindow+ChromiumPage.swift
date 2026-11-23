public import AppKit
import WebKit

extension NSWindow {
    /// Whether this is a Chromium page window: a CEF Views window (`CefNSWindow`) that shows a page
    /// or a docked DevTools. Extension popups and other bubbles are plain Chromium widget windows.
    public var isChromiumPageWindow: Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return isKind(of: pageClass)
    }

    /// Whether the person works in this window while `key` is the key window: `key` is this window or a
    /// Chromium page window inside it (a browser tab, the agent chat, Home), which takes the key while its
    /// page has the keyboard and leaves this window main (`ChromiumPageWindowMain`). The focus model's
    /// `windowKey` is false then (only the window AppKit made key holds it); a "does the person see this
    /// window" rule asks this. A page window with no parent yet acts for the main window, as
    /// ``KeyWindowRole`` resolves it. A panel, sheet or other window that holds the key does not count.
    @MainActor public func holdsKeyboard(key: NSWindow?) -> Bool {
        var current = key
        while let window = current, window !== self {
            guard window.isChromiumPageWindow, window.sheetParent == nil else { return false }
            guard let parent = window.parent else { return isMainWindow }
            current = parent
        }
        return current != nil
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
