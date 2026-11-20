public import AppKit

public extension PageChromiumPage {
    /// Whether a key typed in `window`, the key window, reaches no view while this page is the one the person types into.
    ///
    /// The page takes keys in its own Chromium window, a child of the cmux window. Until that window is key
    /// (``hasKeys``), AppKit sends a typed key to the cmux window, which has no responder of its own then, or to another
    /// page's window (a page a workspace switch hid). Both lose the key: after Cmd-N, "hello world 123" typed at once left
    /// "llo world 123" (Lawrence 2026-11-19, "i did cmd n and started typing and it didnt have focus"). The key router
    /// queues such a key for the page's input instead (its type-ahead), which types it in with no key window.
    ///
    /// - Parameters:
    ///   - window: The window the key went to.
    ///   - appIsActive: Whether the app is active. An app that is not active has no key window, so this is false then.
    /// - Returns: True when the page does not have the keys, and `window` is the cmux window that shows the page with no
    ///   responder of its own, or another Chromium page window of that cmux window.
    func dropsKeys(typedIn window: NSWindow, appIsActive: Bool) -> Bool {
        guard appIsActive, !hasKeys, let owner = contentView.window else { return false }
        if window === owner { return window.firstResponder === window || window.firstResponder == nil }
        return window.parent === owner && NSClassFromString("CefNSWindow").map(window.isKind(of:)) == true
    }
}
