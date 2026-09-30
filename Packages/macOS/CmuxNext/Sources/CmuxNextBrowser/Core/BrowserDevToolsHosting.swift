public import AppKit

/// A tab whose engine shows developer tools inside the pane (CEF). The
/// tools are a separate keyboard target inside the pane: the host's focus
/// model asks `devToolsContains(window:)` which one a key window is, and
/// moves keyboard focus with ``setDevToolsFocused(_:)``.
@MainActor
public protocol BrowserDevToolsHosting: AnyObject {
    var devTools: BrowserDevToolsState { get }
    func performDevTools(_ command: BrowserDevToolsCommand)
    /// Gives keyboard focus to the open tools (or takes it away).
    func setDevToolsFocused(_ focused: Bool)
    /// Whether `window` is this tab's docked tools window (a child window
    /// over the pane), so a key change there is focus on the tools.
    func devToolsContains(window: NSWindow) -> Bool
}

/// Tells the host what the tools of a tab did, for its focus model.
@MainActor
public protocol BrowserDevToolsObserving: AnyObject {
    /// The tools opened (`focused`: they take the keyboard, as in Chrome)
    /// or closed.
    func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool)
}
