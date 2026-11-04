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
        guard geometry.isColumns, let leftFrame = geometry.columns[left.id], let rightFrame = geometry.columns[right.id],
              case let unit = geometry.stripWidth - style.stripGap, unit > 0, delta != 0 else { return nil }
        let strip = geometry.stripWidth, gap = style.stripGap, range = ColumnWidthPreset.widthRange
        let pixel = scale > 0 ? scale : 1
        let widest = max(1, strip - gap * 2)
        func ideal(_ fraction: Double) -> CGFloat { ColumnStripGeometry.pixelWidth(fraction: fraction, viewportWidth: strip, gap: gap) }
        /// The narrowest width a column shows: its minimum rounded up to a pixel, and never below the narrowest share.
        func floor(_ column: LayoutColumn) -> CGFloat {
            max(SplitGeometry.ceilToPixel(min(column.minimumSize(style: style).width, widest), scale: scale),
                SplitGeometry.ceilToPixel(ideal(range.lowerBound), scale: scale))
        }
        // How far the divider may go, in points: right until a column reaches a bound, left the same.
        var most = min(widest - leftFrame.width, rightFrame.width - floor(right))
        var least = -min(leftFrame.width - floor(left), widest - rightFrame.width)
        if let stripOffset {
            let leading = max(0, geometry.uncoveredMinX - geometry.stripMinX)
            let trailing = max(0, geometry.stripMinX + geometry.stripWidth - geometry.uncoveredMaxX)
            most = min(most, stripOffset + strip - trailing - rightFrame.minX)
            least = max(least, stripOffset + leading - leftFrame.maxX)
        }
        // Toward the arrow only, in whole pixels: the step to the nearest one, the room to the last one inside it
        // (`edgeTolerance` of a pixel of float slack), so a press never passes a bound.
        let room = max(0, delta > 0 ? most : -least)
        let pixels = min((abs(CGFloat(delta)) * unit * pixel).rounded(), (room * pixel + ColumnStripGeometry.edgeTolerance).rounded(.down))
        guard pixels > 0 else { return nil }
        let move = (delta > 0 ? pixels : -pixels) / pixel
        let (leftShown, rightShown) = (leftFrame.width + move, rightFrame.width - move)
        // The ideal widths that show those: the pair's ideal sum kept, both the same way from their pixels; else (a pair
        // whose ideal widths are both on a tie, where that way is the tie itself) the shown widths themselves.
        let (leftIdeal, rightIdeal) = (ideal(left.width), ideal(right.width))
        let shift = (leftShown - leftIdeal + rightIdeal - rightShown) / 2
        for (a, b) in [(leftIdeal + shift, rightIdeal - shift), (leftShown, rightShown)] {
            let widths = (kept(fraction(a)), kept(fraction(b)))
            if movesOnlyTheDivider(layout.settingWidth(widths.0, for: left.id).settingWidth(widths.1, for: right.id),
                                   left: left.id, right: right.id, by: move) {
                return widths
            }
        }
        return nil
    }

    /// The share of the strip whose ideal width is `width` points.
    private func fraction(_ width: CGFloat) -> Double {
        ColumnStripGeometry.fraction(forPixelWidth: width, viewportWidth: geometry.stripWidth, gap: style.stripGap)
    }

    /// `width` as the daemon keeps a column width (`f32`, cmux-tui `LayoutColumn.width`): the value its echo brings back.
    private func kept(_ width: Double) -> Double { Double(Float(width)) }

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
        let sides = geometry.dock.filter { !$0.dock.edge.isBand }
        guard let entry = sides.first(where: { $0.column == column.id }) else { return nil }
        let width = geometry.viewport.width, gap = style.stripGap
        var widest = max(1, width * (sides.count == 2 ? DockStripGeometry.maxShareBoth : DockStripGeometry.maxShare))
        if entry.dock.mode == .docked {
            let others = sides.filter { $0.column != column.id && $0.dock.mode == .docked }
            let room = width - min(DockStripGeometry.minimumStripWidth, width / 2) - gap * CGFloat(others.count + 1)
            widest = min(widest, room - others.reduce(0) { $0 + $1.frame.width })
        }
        let lower = ColumnStripGeometry.fraction(forPixelWidth: column.minimumSize(style: style).width, viewportWidth: width, gap: gap)
        let upper = ColumnStripGeometry.fraction(forPixelWidth: widest, viewportWidth: width, gap: gap)
        return lower...max(lower, upper)
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
        let upper = index + 1 < column.rows.count ? index : index - 1
        guard upper >= 0 else { return nil }
        let rows = column.rows, sum = rows.reduce(0) { $0 + max($1.height, 1) }
        let fills = !style.rowsEnabled || sum <= 1000
        // Permille as placed: a filled stack scales every row by 1000 / sum.
        let scale = fills && sum > 0 ? Double(sum) / 1000 : 1
        /// The largest stored permille at which `row` still shows at its minimum height on this screen's pixel grid
        /// (as `RowStackGeometry.compute` places it: the placed height rounded to a pixel, held at the minimum rounded
        /// up to one): below it nothing moves, above it the edge moves. Searched from the exact estimate; a few steps.
        func floor(_ row: LayoutRow) -> Int {
            let minimum = SplitGeometry.ceilToPixel(SplitGeometry.minimumSize(of: row.root, style: style).height, scale: self.scale)
            func shown(_ stored: Int) -> CGFloat {
                SplitGeometry.roundToPixel(RowStackGeometry.pixelHeight(permille: Double(stored) / scale, columnHeight: stack.frame.height,
                                                                         gap: stack.gap), scale: self.scale)
            }
            let range = LayoutRow.heightRange
            let exact = Double((minimum + stack.gap) / (stack.frame.height + stack.gap)) * 1000 * scale
            var stored = min(max(Int(exact.rounded(.down)), range.lowerBound), range.upperBound)
            while stored > range.lowerBound, shown(stored) > minimum { stored -= 1 }
            while stored < range.upperBound, shown(stored + 1) <= minimum { stored += 1 }
            return stored
        }
        let step = Int((delta * 1000 * scale).rounded())
        guard step != 0 else { return nil }
        var heights = rows.map { RowHeight(row: $0.id, height: $0.height) }
        let range = LayoutRow.heightRange
        // The upper row's permille where it shows: a row stored below what its panes need shows at that minimum.
        let shownUpper = max(rows[upper].height, floor(rows[upper]))
        /// From where the row shows, one step toward `next`, inside `low...high`; nil when nothing would move, so a
        /// press never moves the edge the wrong way or sends a height the model refuses.
        /// Each direction checks only its own bound: Up (shrinking the upper row) stops at `low`, Down at `high`. Where
        /// the two rows' minimums cannot both fit (`low > high`), Up can still bring the upper row to its minimum (the
        /// lower row only grows).
        func stepped(low: Int, high: Int) -> Int? {
            if step > 0 {
                let next = min(shownUpper + step, high)
                return next > shownUpper ? next : nil
            }
            let next = max(shownUpper + step, low)
            return next < shownUpper ? next : nil
        }
        if fills {
            let pair = rows[upper].height + rows[upper + 1].height
            // Both rows stay in 100...1000 (setRowHeights refuses others) and keep their minimums.
            guard let next = stepped(low: max(floor(rows[upper]), pair - range.upperBound),
                                     high: min(pair - floor(rows[upper + 1]), range.upperBound)) else { return nil }
            heights[upper].height = next
            heights[upper + 1].height = pair - next
        } else {
            // A scrolling stack: the upper row alone, and never below the sum that fills the column (there the stack
            // places rows in proportion, a different edge): the press that reaches it is a part step.
            let rest = sum - rows[upper].height
            guard let next = stepped(low: max(floor(rows[upper]), 1000 - rest), high: range.upperBound) else { return nil }
            heights[upper].height = next
        }
        return heights
    }
}
