public import AppKit

/// Colors the canvas resolves through the host app so the package carries no
/// theme logic of its own. The provider is re-queried on appearance changes
/// and on every descriptor sync.
public struct CanvasTheme {
    /// Fill of the scrollable canvas itself (behind all panes).
    public var canvasBackground: NSColor
    /// Fill of each pane behind its content.
    public var paneBackground: NSColor
    /// True when the host window already paints a translucent terminal
    /// backdrop behind the canvas, as split mode relies on. The canvas and
    /// pane fills then stay clear so the backdrop shows through, and
    /// ``paneBackground`` only seeds the tab fill colors.
    public var showsWindowBackdrop: Bool

    public init(
        canvasBackground: NSColor,
        paneBackground: NSColor,
        showsWindowBackdrop: Bool = false
    ) {
        self.canvasBackground = canvasBackground
        self.paneBackground = paneBackground
        self.showsWindowBackdrop = showsWindowBackdrop
    }
}

/// A notification after which the host's ``CanvasTheme`` may resolve
/// differently, such as a terminal background or opacity change. The canvas
/// re-queries its theme provider whenever one is posted.
public struct CanvasThemeChangeSignal {
    /// The notification to observe.
    public var name: Notification.Name
    /// The center the notification is posted on.
    public var center: NotificationCenter

    public init(name: Notification.Name, center: NotificationCenter = .default) {
        self.name = name
        self.center = center
    }
}
