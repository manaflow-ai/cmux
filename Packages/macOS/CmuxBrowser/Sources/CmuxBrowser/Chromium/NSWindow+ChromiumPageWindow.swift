public import AppKit

/// The cmux Chromium fork shows each page in its own `CefNSWindow`, placed as
/// a child window over the panel's host view. When the page has the
/// keyboard, AppKit's key window (and a key event's window) is that page
/// window, not the cmux window around it; every lookup that maps a window to
/// a workspace, a shortcut or a focused panel must act for the cmux window.
///
/// Until the app reports that the Chromium runtime loaded
/// (`noteChromiumRuntimeLoaded()`), no window is a page window and these
/// return the receiver unchanged at the cost of one nil check: WebKit-only
/// sessions, the default, see no difference, and the keyDown path does no
/// class lookup.
///
/// Reference: cmux Next `CmuxNextApp/Focus/KeyWindowRole.swift` (a Chromium page
/// window inside a root acts for the root) and `ChildWindowKeyRule.swift`.
extension NSWindow {
    /// Called once the Chromium runtime is loaded (before its first page can
    /// show): page windows are recognized from then on.
    public static func noteChromiumRuntimeLoaded() {
        guard chromiumPageWindowClass == nil else { return }
        chromiumPageWindowClass = NSClassFromString("CefNSWindow")
    }

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

    /// `CefNSWindow`, once the runtime loaded it.
    private static var chromiumPageWindowClass: AnyClass?

    #if DEBUG
    /// Forgets the runtime (tests that need "Chromium not loaded").
    static func resetChromiumRuntimeForTesting() {
        chromiumPageWindowClass = nil
    }
    #endif
}
