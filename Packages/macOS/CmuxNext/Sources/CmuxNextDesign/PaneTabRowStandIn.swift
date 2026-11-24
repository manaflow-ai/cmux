public import AppKit

/// A native stand-in for a view's own tools in its pane's tab row while a resize drag moves the row (Leo 2026-11-24:
/// "i want all our resizing at any cpu to be able to happen in lockstep. the agent pane, chromium, terminal, the
/// relevant ui elements like the top right buttons"). A Chromium chat's tools are page pixels another process draws
/// some frames after the pane takes its size, so through a drag they trailed the pane's own toolbar. While a drag,
/// window or sidebar resize is live the pane draws the tools itself, in an opaque band over the page's, and lays them
/// out in the same commit as its strip and toolbar; the band leaves once the page drew at the size the drag ended at.
public nonisolated struct PaneTabRowStandIn: Equatable {
    /// The band, in the sharing view's coordinates: the whole row's height, from the leftmost x the page's tools took
    /// since the drag began to the row's trailing end (where the pane's own toolbar begins).
    public var frame: CGRect
    /// The row's top points the band leaves clear: the window's lit rim (``PaneTabRowRim``).
    public var rim: CGFloat
    /// The page's tools, as it published them (`pane.tabRowTools.set`), drawn trailing-aligned in the band.
    public var tools: [PaneTabRowTool]
    /// What the band paints under the rim: the row's hole fill, or the page's own surface where the row has none.
    public var fill: CGColor

    public init(frame: CGRect, rim: CGFloat, tools: [PaneTabRowTool], fill: CGColor) {
        self.frame = frame
        self.rim = rim
        self.tools = tools
        self.fill = fill
    }
}

/// The pane's toolbar, which draws a sharing view's ``PaneTabRowStandIn`` (it knows the pane's strip and draws the same
/// buttons): placed with each offer of the row, so the band moves in the pane's own layout, in the same commit as the
/// strip and the toolbar.
@MainActor
public protocol PaneTabRowStandInHosting: NSView {
    /// Shows `standIn` (its frame in `view`'s coordinates), or hides the band (nil).
    func placeTabRowStandIn(_ standIn: PaneTabRowStandIn?, from view: NSView?)
}
