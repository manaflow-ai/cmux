/// Where something opened from a tab starts: the pane a window shows the tab in, the tab's own
/// workspace when no window shows it, or the active window's focused pane when no tab is named.
///
/// A link a terminal program opens (`browser.open_link`, gh's "Press Enter to open ... in your
/// browser") names the caller's tab. When no window shows that tab's workspace, the link must open
/// there, behind, never in the pane the person is looking at in another workspace.
///
/// ```swift
/// switch LinkSourceRoute.resolve(key: tab, shown: paneShowing, exists: tabExists, focused: { focusedPane }) {
/// case .shown(let pane), .focused(let pane): open(url, from: pane)
/// case .hidden(let tab): openBehind(url, in: tab)
/// case .none: openInDefaultBrowser(url)
/// }
/// ```
public enum LinkSourceRoute<Pane> {
    /// A window shows the tab: open from `Pane`.
    case shown(Pane)
    /// The tab exists but no window shows its workspace: open in that workspace, behind.
    case hidden(tab: String)
    /// No tab was named: the active window's focused pane.
    case focused(Pane)
    /// Nowhere in cmux: the named tab is gone, or no tab was named and no pane has focus.
    case none

    /// Resolves the start of an open from tab `key`.
    ///
    /// - Parameter key: the tab's id or resource id; nil when the open names no tab.
    /// - Parameter shown: the pane a window shows the tab in, or nil.
    /// - Parameter exists: whether a store lists the tab at all.
    /// - Parameter focused: the active window's focused pane, or nil.
    /// - Returns: where the open starts.
    public static func resolve(key: String?, shown: (String) -> Pane?, exists: (String) -> Bool, focused: () -> Pane?) -> Self {
        guard let key else { return focused().map(Self.focused) ?? .none }
        if let pane = shown(key) { return .shown(pane) }
        return exists(key) ? .hidden(tab: key) : .none
    }

    /// The pane the open starts from (``shown(_:)`` or ``focused(_:)``); nil for ``hidden(tab:)`` and ``none``.
    public var pane: Pane? {
        switch self {
        case .shown(let pane), .focused(let pane): pane
        case .hidden, .none: nil
        }
    }
}
