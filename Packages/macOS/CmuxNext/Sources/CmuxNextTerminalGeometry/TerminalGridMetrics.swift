/// Cell and padding sizes of one Ghostty surface, in backing pixels, taken
/// from a surface Ghostty sized to an exact grid.
///
/// `ghostty_surface_set_grid_size` resolves the surface to
/// `columns * cell + padding` (renderer/size.zig `screenForGrid`), so the
/// padding is the resolved size minus the cells. ``grid(fittingWidth:height:)``
/// then answers the grid a pixel size fits with Ghostty's own formula
/// (`GridSize.update`: truncating division of the padded screen by the cell,
/// at least one cell) without resizing the surface. With
/// `window-padding-balance` the resolved padding may exceed the configured
/// one by less than a cell, so a fit can come out one cell smaller than
/// Ghostty would size the view; the surface still renders exactly the grid
/// the PTY has.
public nonisolated struct TerminalGridMetrics: Sendable, Equatable {
    public var cellWidth: Int
    public var cellHeight: Int
    /// Left plus right padding.
    public var paddingWidth: Int
    /// Top plus bottom padding.
    public var paddingHeight: Int

    public init(cellWidth: Int, cellHeight: Int, paddingWidth: Int, paddingHeight: Int) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingWidth = paddingWidth
        self.paddingHeight = paddingHeight
    }

    /// Metrics of a surface resolved to `grid` at `widthPixels` x
    /// `heightPixels`. Nil when the numbers are not a resolved grid.
    public init?(resolving grid: TerminalGridSize, widthPixels: Int, heightPixels: Int, cellWidth: Int, cellHeight: Int) {
        guard grid.columns > 0, grid.rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }
        let paddingWidth = widthPixels - grid.columns * cellWidth
        let paddingHeight = heightPixels - grid.rows * cellHeight
        guard paddingWidth >= 0, paddingHeight >= 0 else { return nil }
        self.init(cellWidth: cellWidth, cellHeight: cellHeight, paddingWidth: paddingWidth, paddingHeight: paddingHeight)
    }

    /// The grid Ghostty fits into a `width` x `height` pixel view.
    public func grid(fittingWidth width: Int, height: Int) -> TerminalGridSize {
        TerminalGridSize(
            columns: max(1, max(0, width - paddingWidth) / cellWidth),
            rows: max(1, max(0, height - paddingHeight) / cellHeight)
        )
    }

    /// Pixel size of `grid`'s cells (the terminal's `ws_xpixel`/`ws_ypixel`).
    public func cellPixels(of grid: TerminalGridSize) -> (width: Int, height: Int) {
        (grid.columns * cellWidth, grid.rows * cellHeight)
    }
}
