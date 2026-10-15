public import AppKit

/// The cmux Chromium fork shows each page in its own `CefNSWindow`, placed as
/// a child window over the panel's host view. When the page has the
/// keyboard, AppKit's key window (and a key event's window) is that page
/// window, not the cmux window around it; every lookup that maps a window to
/// a workspace, a shortcut or a focused panel must act for the cmux window.
///
/// Without the Chromium runtime loaded `CefNSWindow` does not exist, so every
/// call here returns its input unchanged: WebKit-only builds and sessions see
/// no difference.
///
/// Reference: cmux Next `CmuxNextApp/Focus/KeyWindowRole.swift` (a Chromium page
/// window inside a root acts for the root) and `ChildWindowKeyRule.swift`.
@MainActor
public enum ChromiumPageWindow {
    /// Whether `window` is a Chromium page window (`CefNSWindow`).
    public static func isPageWindow(_ window: NSWindow?) -> Bool {
        guard let window, let pageClass = pageWindowClass else { return false }
        return window.isKind(of: pageClass)
    }

    /// The window `window` acts for: the top of a page window's parent chain,
    /// or `fallback` (normally the main window) for a page window Chromium
    /// showed before the fork placed it as a child. Any other window is
    /// returned unchanged.
    public static func actingWindow(for window: NSWindow?, fallback: @autoclosure () -> NSWindow?) -> NSWindow? {
        guard let window, isPageWindow(window) else { return window }
        var root = window
        while let parent = root.parent {
            root = parent
        }
        guard root !== window else {
            let fallbackWindow = fallback()
            return isPageWindow(fallbackWindow) ? nil : fallbackWindow
        }
        return root
    }

    /// `CefNSWindow`, looked up once the Chromium runtime has loaded it.
    private static var pageWindowClass: AnyClass? {
        if let cached = cachedPageWindowClass { return cached }
        let resolved: AnyClass? = NSClassFromString("CefNSWindow")
        cachedPageWindowClass = resolved
        return resolved
    }

    /// Cached only once found: the class appears when the framework loads,
    /// which can be after the first lookup.
    private static var cachedPageWindowClass: AnyClass?
}
