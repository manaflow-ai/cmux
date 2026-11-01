public import CoreGraphics
public import CmuxNextTerminalGeometry

/// The grid a new terminal tab in a pane spawns at, so its PTY starts at the
/// grid its view will show and its first frame is already the right size.
///
/// Without it the create request carries no size and the daemon falls back
/// to the grid of the terminal that reported last, anywhere
/// (`client_sizing_state.rs` `creation_size`): another pane's or workspace's
/// width. The shell then prints its first prompt at that width, the view
/// reports its own grid, and the pane snaps a frame or more later.
///
/// Two sources, best first:
/// 1. The pane's shown terminal at the configured font size: Ghostty's own
///    fit of the same content area (exact).
/// 2. The pane's content size, the backing scale, a live terminal's cell size
///    and the configured padding, through Ghostty's formula
///    (``TerminalGridEstimate``): a pane showing a page, an agent or the New
///    Tab page (Cmd-T).
///
/// Nil when neither is known (the first terminal of the app, a pane out of
/// a window): the daemon's fallback applies, and the view's first report
/// corrects it.
public struct NewTerminalGrid {
    /// The fitted grid of the terminal this pane shows, when it is at the
    /// configured font size (``TerminalSession/gridForNewTerminal``).
    public var shownTerminalGrid: TerminalGridSize?
    /// The pane's content host size in points.
    public var hostSize: CGSize
    /// Backing pixels per point of the pane's window; nil out of a window.
    public var scale: CGFloat?
    /// A live terminal's cell size in backing pixels at `scale` and the
    /// configured font size (the App's `TabContentCache.configuredCellPixelSize(scale:)`).
    public var cellPixels: CGSize?
    /// The configured terminal padding.
    public var padding: TerminalPadding
    /// The surface width of a host this wide (``TerminalHostView/surfaceWidth(hostWidth:)``).
    public var surfaceWidth: (CGFloat) -> CGFloat

    public init(shownTerminalGrid: TerminalGridSize?, hostSize: CGSize, scale: CGFloat?, cellPixels: CGSize?, padding: TerminalPadding,
                surfaceWidth: @escaping (CGFloat) -> CGFloat = { TerminalHostView.surfaceWidth(hostWidth: $0) }) {
        (self.shownTerminalGrid, self.hostSize, self.scale, self.cellPixels) = (shownTerminalGrid, hostSize, scale, cellPixels)
        (self.padding, self.surfaceWidth) = (padding, surfaceWidth)
    }

    /// The grid to spawn at, or nil to let the daemon choose.
    public var grid: TerminalGridSize? {
        if let shownTerminalGrid { return shownTerminalGrid }
        guard let scale, let cellPixels else { return nil }
        let estimate = TerminalGridEstimate(
            cellWidth: Int(cellPixels.width), cellHeight: Int(cellPixels.height),
            padding: (Double(padding.leading), Double(padding.trailing), Double(padding.top), Double(padding.bottom))
        )
        return estimate.grid(width: Double(surfaceWidth(hostSize.width)), height: Double(hostSize.height), scale: Double(scale))
    }
}
