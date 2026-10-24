import AppKit

/// One Chromium focus grant at a time for a page (`CEFTab.grantFocus`).
///
/// CEF's `SetFocus(true)` makes the page's window key (`makeKeyAndOrderFront`); the key change
/// posts `didBecomeKey`, which runs the focus model again, which asks the same page for focus
/// again: a grant from inside a grant. On macOS 14 and 15 those nested key changes hung main for
/// 10 s (#24913). A grant asked for while one runs is the same request: it is dropped. A page whose
/// window is already the key window has the keys: no window-level change is asked for.
struct CEFFocusGrant {
    /// A grant's CEF call is running (CEF asks back through `chromiumRequestsFocus` inside it).
    private(set) var isGranting = false
    /// Grants that reached CEF (tests, `debug.cef`).
    private(set) var grants = 0

    /// Runs `setFocus` unless a grant runs already or the page's window is already key.
    ///
    /// - Parameters:
    ///   - pageWindowIsKey: the page's own window is the key window now.
    ///   - setFocus: CEF's `SetFocus(true)` for the page.
    /// - Returns: Whether `setFocus` ran.
    mutating func grant(pageWindowIsKey: Bool, setFocus: () -> Void) -> Bool {
        guard !isGranting, !pageWindowIsKey else { return false }
        isGranting = true
        defer { isGranting = false }
        grants += 1
        setFocus()
        return true
    }
}
