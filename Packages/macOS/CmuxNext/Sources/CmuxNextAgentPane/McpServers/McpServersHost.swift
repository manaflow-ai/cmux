public import Foundation

/// What Settings > MCP Servers needs from the app (``McpServersCoordinator``). The app conforms with
/// one-line forwards (`AppServices+McpServersHost.swift`); tests pass a fake.
public protocol McpServersHost: AnyObject {
    /// This app's acpmux, which the page reaches on a person line; nil when the app has none.
    var mcpServersEnvironment: AcpmuxEnvironment? { get }
    /// Shows the page tab ``McpServersCoordinator/pageID`` in the active window, else opens one;
    /// `focus` false (automation) opens it without selecting it.
    /// - Returns: False when no window can show it.
    func mcpServersShowPage(focus: Bool) -> Bool
    /// Whether any window still shows the page.
    func mcpServersPageIsOpen() -> Bool
    /// Opens `url` (a sign-in page) in a cmux browser tab of the active window.
    func mcpServersOpenBrowserTab(_ url: URL)
}
