public import AppKit

/// Colors the canvas resolves through the host app so the package carries no
/// theme logic of its own. The provider is re-queried on appearance changes
/// and on every descriptor sync.
public struct CanvasTheme {
    /// Fill of the scrollable canvas itself (behind all panes).
    public var canvasBackground: NSColor
    /// Fill of each pane behind its content.
    public var paneBackground: NSColor

    public init(canvasBackground: NSColor, paneBackground: NSColor) {
        self.canvasBackground = canvasBackground
        self.paneBackground = paneBackground
    }
}
