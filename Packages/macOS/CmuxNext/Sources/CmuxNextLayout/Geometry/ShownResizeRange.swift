public import CoreGraphics

/// The split ratios and column widths one screen can show as different layouts. Below or above them the
/// minimum pane sizes hold the divider where it is (``SplitGeometry/firstExtent(ratio:available:minimumA:minimumB:scale:)``,
/// ``ColumnStripGeometry/frames(widths:viewport:gap:scale:minimumWidths:)``): a keyboard resize step there would
/// change the model and move nothing (RESIZE KEYS, cmux-ad 2026-11-02, P0 "pixel perfect ctrl shift hjkl").
public nonisolated struct ShownResizeRange {
    let geometry: ScreenGeometry
    let style: LayoutStyle

    /// - Parameters:
    ///   - geometry: The screen's geometry at its rest (the one its springs head for).
    ///   - style: The style that geometry was computed with.
    public init(geometry: ScreenGeometry, style: LayoutStyle) {
        self.geometry = geometry
        self.style = style
    }

    /// The ratios of `split` that place its divider somewhere new: each side keeps its minimum extent.
    /// Nil when the screen has no such divider or no room for both minimums.
    public func ratio(of split: SplitID) -> ClosedRange<Double>? {
        guard let divider = geometry.dividers.first(where: { $0.id == split }) else { return nil }
        let horizontal = divider.axis == .horizontal
        let available = Double((horizontal ? divider.container.width : divider.container.height)
            - (horizontal ? divider.frame.width : divider.frame.height))
        guard available > 0, Double(divider.minimumA + divider.minimumB) <= available else { return nil }
        let lower = Double(divider.minimumA) / available, upper = (available - Double(divider.minimumB)) / available
        return lower <= upper ? lower...upper : nil
    }

    /// The width fractions of a scrolling `column` the strip shows as different widths: from the fraction
    /// whose frame is the column's minimum width up. Nil for a docked column or a screen with no strip size.
    public func width(of column: LayoutColumn) -> ClosedRange<Double>? {
        guard geometry.isColumns, column.dock == nil, geometry.stripWidth > 0 else { return nil }
        let lower = ColumnStripGeometry.fraction(forPixelWidth: column.minimumSize(style: style).width,
                                                 viewportWidth: geometry.stripWidth, gap: style.stripGap)
        return lower...max(lower, ColumnWidthPreset.widthRange.upperBound)
    }

    /// Every row height of `column` after a keyboard press moves the row edge next to `pane`'s row by `delta`
    /// (a share of the column's height; down is positive): the edge below that row, or above it for the last row.
    /// Each row keeps its minimum (``RowResize``). Nil when the column has no rows here or nothing moves.
    public func rowHeights(moving pane: PaneID, in column: LayoutColumn, by delta: Double) -> [RowHeight]? {
        nil
    }
}
