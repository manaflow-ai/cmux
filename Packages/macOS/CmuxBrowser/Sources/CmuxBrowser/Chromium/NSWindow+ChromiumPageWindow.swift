public import AppKit

/// The cmux Chromium fork shows each page in its own `CefNSWindow`, placed as
/// a child window over the panel's host view. When the page has the
/// keyboard, AppKit's key window (and a key event's window) is that page
/// window, not the cmux window around it; every lookup that maps a window to
/// a workspace, a shortcut or a focused panel must act for the cmux window.
///
/// Without the Chromium runtime loaded `CefNSWindow` does not exist, so these
/// return the receiver unchanged: WebKit-only builds and sessions see no
/// difference.
///
/// Reference: cmux Next `CmuxNextApp/Focus/KeyWindowRole.swift` (a Chromium page
/// window inside a root acts for the root) and `ChildWindowKeyRule.swift`.
extension NSWindow {
    /// Whether this is a Chromium page window (`CefNSWindow`).
    public var isChromiumPageWindow: Bool {
        guard let pageClass = Self.chromiumPageWindowClass else { return false }
        return isKind(of: pageClass)
    }

    /// The window this one acts for: the top of a page window's parent chain,
    /// or `fallback` (normally the main window) for a page window Chromium
    /// showed before the fork placed it as a child. Any other window acts for
    /// itself.
    public func chromiumActingWindow(fallback: @autoclosure () -> NSWindow?) -> NSWindow? {
        guard isChromiumPageWindow else { return self }
        var root: NSWindow = self
        while let parent = root.parent {
            root = parent
        }
        guard root !== self else {
            let fallbackWindow = fallback()
            return fallbackWindow?.isChromiumPageWindow == true ? nil : fallbackWindow
        }
        return root
    }

    /// `CefNSWindow`, looked up until the Chromium runtime has loaded it.
    private static var chromiumPageWindowClass: AnyClass? {
        if let cached = cachedChromiumPageWindowClass { return cached }
        let resolved: AnyClass? = NSClassFromString("CefNSWindow")
        cachedChromiumPageWindowClass = resolved
        return resolved
    }

    /// Cached only once found: the class appears when the framework loads,
    /// which can be after the first lookup.
    private static var cachedChromiumPageWindowClass: AnyClass?
}
