/// The find/search actions the focused-terminal command surface falls back to
/// when no terminal panel is focused but a browser panel is.
///
/// The find shortcuts (Cmd+F / find-next / find-previous / hide) are shared
/// across terminal and browser panels. When no terminal is focused,
/// ``FocusedTerminalCommandCoordinator`` routes the same command to the focused
/// browser panel through this seam. The browser panel lives in the app target
/// (it owns the WebKit `WKWebView`), so it conforms to this protocol and the
/// coordinator forwards through it.
///
/// `@MainActor` because every action mutates WebKit/AppKit state on the main
/// thread; the protocol exists where its callers live.
@MainActor
public protocol FocusedTerminalFindFallback: AnyObject {
    /// Whether this browser panel currently has a find overlay visible.
    var isSearchVisible: Bool { get }

    /// Starts or focuses the find overlay for this browser.
    func startFind()

    /// Advances to the next find match.
    func findNext()

    /// Moves to the previous find match.
    func findPrevious()

    /// Hides the find overlay for this browser.
    func hideFind()
}
