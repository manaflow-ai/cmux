/// The grid a terminal view of a known size will fit, worked out before the
/// view (or its Ghostty surface) exists.
///
/// A new terminal must start its PTY at the grid its view will show, or the
/// first frames draw the shell at the wrong width and the pane visibly snaps
/// when the view's own report resizes it (the "wrong size frame" of a new
/// tab). The PTY owner spawns before the view lays out, so the client works
/// the grid out from what it already knows: the pane's content size, the
/// backing scale, Ghostty's cell size and the configured padding.
///
/// It uses Ghostty's own formula: each padding side is
/// `floor(points * scale)` pixels (`Surface.zig` `scaledPadding`, where
/// `dpi / 72` is the content scale on macOS), and the grid is the truncating
/// division of the padded pixel size by the cell, at least one cell
/// (`GridSize.update`), as ``TerminalGridMetrics/grid(fittingWidth:height:)``.
public nonisolated struct TerminalGridEstimate: Sendable, Equatable {
    /// Cell width in backing pixels.
    public var cellWidth: Int
    /// Cell height in backing pixels.
    public var cellHeight: Int
    /// Configured padding in points: left, right, top, bottom.
    public var padding: (leading: Double, trailing: Double, top: Double, bottom: Double)

    /// - Parameters:
    ///   - cellWidth: Cell width in backing pixels, as a live surface at the
    ///     configured font size reports it.
    ///   - cellHeight: Cell height in backing pixels.
    ///   - padding: `window-padding-x` / `-y` in points.
    public init(cellWidth: Int, cellHeight: Int,
                padding: (leading: Double, trailing: Double, top: Double, bottom: Double)) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.padding = padding
    }

    /// The grid a `width` x `height` point view fits at `scale` backing
    /// pixels per point, or nil for an empty view or unknown cells.
    public func grid(width: Double, height: Double, scale: Double) -> TerminalGridSize? {
        guard cellWidth > 0, cellHeight > 0, scale > 0, width >= 1, height >= 1 else { return nil }
        let pixelWidth = Int((width * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        let metrics = TerminalGridMetrics(
            cellWidth: cellWidth, cellHeight: cellHeight,
            paddingWidth: Self.pixels(padding.leading, scale) + Self.pixels(padding.trailing, scale),
            paddingHeight: Self.pixels(padding.top, scale) + Self.pixels(padding.bottom, scale)
        )
        return metrics.grid(fittingWidth: pixelWidth, height: pixelHeight)
    }

    private static func pixels(_ points: Double, _ scale: Double) -> Int {
        max(0, Int((points * scale).rounded(.down)))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cellWidth == rhs.cellWidth && lhs.cellHeight == rhs.cellHeight
            && lhs.padding.leading == rhs.padding.leading && lhs.padding.trailing == rhs.padding.trailing
            && lhs.padding.top == rhs.padding.top && lhs.padding.bottom == rhs.padding.bottom
    }
}
