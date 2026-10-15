public import CoreGraphics

/// The frames ``BrowserDevToolsLayout`` computes for one pane, in content coordinates.
public struct BrowserDevToolsLayoutFrames: Hashable, Sendable {
    /// The page's frame.
    public var page: CGRect
    /// The docked tools' frame; `.zero` when the tools are not docked in the pane.
    public var devTools: CGRect
    /// The drawn divider line; `.zero` when not docked.
    public var line: CGRect
    /// The line plus ``BrowserDevToolsLayout/grabOutset`` on each side: the divider view's frame.
    public var grab: CGRect

    /// Creates a frames value.
    /// - Parameters:
    ///   - page: The page's frame.
    ///   - devTools: The tools' frame.
    ///   - line: The divider line.
    ///   - grab: The divider's mouse area.
    public init(page: CGRect, devTools: CGRect, line: CGRect, grab: CGRect) {
        self.page = page
        self.devTools = devTools
        self.line = line
        self.grab = grab
    }
}
