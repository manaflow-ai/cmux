public import CoreGraphics

/// The split ratios and column widths one screen can show as different layouts. Below or above them the
/// minimum pane sizes hold the divider where it is (``SplitGeometry/firstExtent(ratio:available:minimumA:minimumB:scale:)``,
/// ``ColumnStripGeometry/frames(widths:viewport:gap:scale:minimumWidths:)``): a keyboard resize step there would
/// change the model and move nothing (RESIZE KEYS, cmux-ad 2026-11-02, P0 "pixel perfect ctrl shift hjkl").
public nonisolated struct ShownResizeRange {
    let geometry: ScreenGeometry
    let style: LayoutStyle
    /// The device pixels per point the geometry was placed on (`ScreenGeometry.compute`'s `scale`).
    let scale: CGFloat
    /// Where the strip's camera rests (content-space x of its viewport's leading edge); nil when unknown.
    let stripOffset: CGFloat?

    /// - Parameters:
    ///   - geometry: The screen's geometry at its rest (the one its springs head for).
    ///   - style: The style that geometry was computed with.
    ///   - scale: The backing scale that geometry was computed at.
    ///   - stripOffset: Where the strip's camera rests: a trade's divider stays in the part of the strip it shows.
    public init(geometry: ScreenGeometry, style: LayoutStyle, scale: CGFloat = 2, stripOffset: CGFloat? = nil) {
        self.geometry = geometry
        self.style = style
        self.scale = scale
        self.stripOffset = stripOffset
    }

    /// The ratios of `split` that place its divider somewhere new: each side keeps its minimum extent.
    /// Nil when the screen has no such divider or no room for both minimums.
    public func ratio(of split: SplitID) -> ClosedRange<Double>? {
        guard let divider = geometry.dividers.first(where: { $0.id == split }) else { return nil }
        let horizontal = divider.axis == .horizontal
        return Self.ratioRule(containerExtent: horizontal ? divider.container.width : divider.container.height,
                              dividerExtent: horizontal ? divider.frame.width : divider.frame.height,
                              minimumA: divider.minimumA, minimumB: divider.minimumB).map { $0.lower...$0.upper }
    }

    /// The width fractions of a scrolling `column` the strip shows as different widths: from the fraction
    /// whose frame is the column's minimum width up. Nil for a docked column or a screen with no strip size.
    public func width(of column: LayoutColumn) -> ClosedRange<Double>? {
        Self.columnWidthRule(isColumns: geometry.isColumns, isDocked: column.dock != nil, stripWidth: geometry.stripWidth,
                             minimumWidth: column.minimumSize(style: style).width, gap: style.stripGap)
            .map { $0.lower...$0.upper }
    }

    /// The widths of two neighbor strip columns of `layout` after a keyboard press moves the divider between them by
    /// `delta` (a share of the strip; right is positive): `left` takes what `right` gives, or gives what it takes, so the
    /// columns after them and the strip stay where they are (the trade of an Option-drag, ``StripStart/trading(_:to:)``).
    ///
    /// The move is whole device pixels from the widths the columns show, and stops where a column reaches its minimum
    /// (shown rounded up to a pixel) or the widest share, and where the divider would leave the part of the strip the
    /// window shows (``stripOffset``): past it the press would move nothing a person sees. The new widths keep the
    /// pair's ideal (unrounded) sum, so the columns after it and the cut of a column that ends at the window's edge
    /// (`ColumnStripGeometry.frames`) do not change, and put both ideal widths the same way from their shown pixels, as
    /// far from a rounding tie as that allows. They are what the daemon keeps (`f32`), so its echo moves nothing. The
    /// result is checked by placing it: the press moves exactly the divider by the step, or it is refused (nil), as when
    /// nothing would move.
    public func trade(_ left: LayoutColumn, _ right: LayoutColumn, by delta: Double, in layout: ScreenLayout) -> (left: Double, right: Double)? {
        guard let leftFrame = geometry.columns[left.id], let rightFrame = geometry.columns[right.id] else { return nil }
        let input = TradeInput(
            isColumns: geometry.isColumns, stripWidth: geometry.stripWidth, gap: style.stripGap, scale: scale, delta: delta,
            leftMinX: leftFrame.minX, leftMaxX: leftFrame.maxX, leftWidth: leftFrame.width,
            rightMinX: rightFrame.minX, rightMaxX: rightFrame.maxX, rightWidth: rightFrame.width,
            leftMinimumWidth: left.minimumSize(style: style).width, rightMinimumWidth: right.minimumSize(style: style).width,
            leftFraction: left.width, rightFraction: right.width, stripOffset: stripOffset,
            uncoveredMinX: geometry.uncoveredMinX, uncoveredMaxX: geometry.uncoveredMaxX, stripMinX: geometry.stripMinX)
        guard let candidates = Self.tradeRule(input) else { return nil }
        for widths in [candidates.first, candidates.second] {
            if movesOnlyTheDivider(layout.settingWidth(widths.left, for: left.id).settingWidth(widths.right, for: right.id),
                                   left: left.id, right: right.id, by: candidates.move) {
                return widths
            }
        }
        return nil
    }

    /// Whether `candidate`, placed as the screen places it, shows every column where it shows now but the divider between
    /// `left` and `right`, moved by `move` points.
    private func movesOnlyTheDivider(_ candidate: ScreenLayout, left: ColumnID, right: ColumnID, by move: CGFloat) -> Bool {
        let placed = ScreenGeometry.compute(candidate, viewport: geometry.viewport, style: style, scale: scale)
        guard let l0 = geometry.columns[left], let r0 = geometry.columns[right], let l1 = placed.columns[left],
              let r1 = placed.columns[right] else { return false }
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        guard same(l1.minX, l0.minX), same(r1.maxX, r0.maxX), same(l1.maxX, l0.maxX + move), same(r1.minX, r0.minX + move) else { return false }
        return geometry.columns.allSatisfy { id, frame in id == left || id == right || placed.columns[id] == frame }
    }

    /// The width fractions of a side dock the screen shows as different widths (`DockStripGeometry.place`):
    /// from its panes' minimum to its share of the window, and for a docked dock to the room the strip leaves at its
    /// minimum width beside the other docked dock as it shows. Past that room the two docked docks share it in
    /// proportion, so a change of one moves both inner edges. Nil for a column that is not a placed side dock.
    public func dockWidth(of column: LayoutColumn) -> ClosedRange<Double>? {
        let sides = geometry.dock.map {
            DockSide(isTarget: $0.column == column.id, isBand: $0.dock.edge.isBand, isDocked: $0.dock.mode == .docked, width: $0.frame.width)
        }
        return Self.dockWidthRule(sides, viewportWidth: geometry.viewport.width, gap: style.stripGap,
                                  minimumWidth: column.minimumSize(style: style).width).map { $0.lower...$0.upper }
    }

    /// Every row height of `column` after a keyboard press moves the row edge next to `pane`'s row by `delta`
    /// (a share of the column's height; down is positive): the edge below that row, or above it for the last row.
    /// The press trades whole permille between the two rows (or, in a scrolling stack, sizes the upper row alone),
    /// the exact inverse of ``RowStackGeometry/compute``'s placement, so each press moves the edge by the same
    /// `(height + gap) * delta` points, snapped once to the pixel grid. Each row keeps 100 permille and the height its
    /// tree needs; a press at that limit is nil (nothing moves).
    public func rowHeights(moving pane: PaneID, in column: LayoutColumn, by delta: Double) -> [RowHeight]? {
        guard column.hasRows, let stack = geometry.rowStacks[column.id],
              let index = column.rows.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
        let rows = column.rows
        let input = RowInput(
            heights: rows.map(\.height),
            minimumHeights: rows.map { SplitGeometry.minimumSize(of: $0.root, style: style).height },
            paneRow: index, rowsEnabled: style.rowsEnabled, columnHeight: stack.frame.height, gap: stack.gap, scale: scale,
            delta: delta)
        guard let heights = Self.rowHeightsRule(input) else { return nil }
        return zip(rows, heights).map { RowHeight(row: $0.id, height: $1) }
    }
}
