public import CoreGraphics

/// A ``BrowserPage`` whose engine shows developer tools inside the pane and can dock them
/// (Chromium). WebKit pages do not conform; their inspector stays owned by the panel.
///
/// The panel checks for this protocol and routes every DevTools entry point (shortcuts, menus,
/// the command palette, automation) through ``performDevTools(_:)``, so dock changes, the
/// divider and the separate window behave the same whatever started them.
@MainActor
public protocol BrowserPageDevToolsHosting: BrowserPage {
    /// What the page's tools look like now.
    var devToolsState: BrowserDevToolsState { get }

    /// Runs a DevTools command.
    /// - Parameter command: The command.
    func performDevTools(_ command: BrowserDevToolsCommand)

    /// Gives keyboard focus to the open tools, or returns it to the page.
    /// - Parameter focused: `true` to focus the tools.
    func setDevToolsFocused(_ focused: Bool)

    /// Applies the app's settings to the tools' divider and dock menu.
    /// - Parameters:
    ///   - dividerThickness: The pane divider thickness setting.
    ///   - closeShortcut: The Toggle Developer Tools shortcut for the dock menu's Close row.
    func configureDevTools(dividerThickness: CGFloat, closeShortcut: BrowserDevToolsMenuShortcut?)
}
