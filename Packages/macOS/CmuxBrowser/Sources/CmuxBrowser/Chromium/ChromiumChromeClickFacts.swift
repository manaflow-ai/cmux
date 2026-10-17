/// What a cmux window knows about a mouse press into its own content (the
/// pane tab bar, the sidebar, the address bar), and whether it takes the
/// keyboard before AppKit dispatches the press.
///
/// While a Chromium page has the keyboard, the key window is that page's
/// `CefNSWindow`, a child of the cmux window, so the cmux window is not key
/// although the person is using it. AppKit spends a press into a non-key
/// window on making it key and only delivers it when the view under it
/// accepts the first mouse; the SwiftUI pane tab bar does not, so a tab
/// click after using a Chromium page was lost (a WebKit page keeps the cmux
/// window key, so its tab bar never sees this). The window takes the keys
/// first, and the press lands as it does in a key window.
///
/// Pure. cmux Next reaches the same result by having its tab strip and
/// sidebar accept the first mouse (`CmuxNextTabs/TabStripView.swift`).
public struct ChromiumChromeClickFacts: Equatable, Sendable {
    /// The app's key window, relative to the cmux window that got the press.
    public enum KeyWindow: Equatable, Sendable {
        /// A Chromium page window placed in this cmux window (or a parentless
        /// one acting for it).
        case ownChromiumPage
        /// The app is not active, or nothing has the keys.
        case noKeyWindow
        /// Any other window, including this cmux window itself.
        case other
    }

    /// A primary-button press (a secondary press opens a context menu
    /// without changing the key window).
    public var isLeftMouseDown: Bool
    public var windowIsKey: Bool
    public var keyWindow: KeyWindow
    /// A sheet on the window or an app-modal session owns the keyboard.
    public var isBlockedByModal: Bool

    public init(isLeftMouseDown: Bool, windowIsKey: Bool, keyWindow: KeyWindow, isBlockedByModal: Bool = false) {
        self.isLeftMouseDown = isLeftMouseDown
        self.windowIsKey = windowIsKey
        self.keyWindow = keyWindow
        self.isBlockedByModal = isBlockedByModal
    }

    /// Whether the cmux window makes itself key before dispatching the press.
    public var takesKeysBeforeDispatch: Bool {
        isLeftMouseDown && !windowIsKey && keyWindow == .ownChromiumPage && !isBlockedByModal
    }
}
