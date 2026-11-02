public import CoreGraphics

/// Pure math for scrolling columns. Offsets are the content-space
/// x of the viewport's leading edge.
public nonisolated enum ColumnStripGeometry {
    /// Pixel width of a column with width fraction `fraction`. Gaps included:
    /// `(viewport - gap) * fraction - gap`, so two half columns and three gaps
    /// exactly fill the viewport.
    public static func pixelWidth(fraction: Double, viewportWidth: CGFloat, gap: CGFloat) -> CGFloat {
        max(1, (viewportWidth - gap) * CGFloat(fraction) - gap)
    }

    /// Inverse of `pixelWidth`, clamped to the daemon range.
    public static func fraction(forPixelWidth width: CGFloat, viewportWidth: CGFloat, gap: CGFloat) -> Double {
        let denominator = viewportWidth - gap
        guard denominator > 0 else { return ColumnWidthPreset.defaultWidth }
        let value = Double((width + gap) / denominator)
        return min(max(value, ColumnWidthPreset.widthRange.lowerBound), ColumnWidthPreset.widthRange.upperBound)
    }

    /// Content-space frames for columns laid out left to right with a gap
    /// before, between, and after them. Returns frames and total content width.
    /// Columns that fit the viewport end exactly at its trailing edge: each
    /// width is rounded to a pixel on its own, so a rounded-up column is cut
    /// back to the room left, and no strip scrolls by a rounding error.
    /// `minimumWidths` (per column, optional) widen a column whose split tree
    /// needs more room than its fraction gives, up to the viewport minus its
    /// gaps, so side-by-side panes never collapse.
    public static func frames(
        widths: [Double],
        viewport: CGSize,
        gap: CGFloat,
        scale: CGFloat = 2,
        minimumWidths: [CGFloat] = []
    ) -> (frames: [CGRect], contentWidth: CGFloat) {
        var x = gap
        // Where the columns end before rounding. Only rounding is cut back: a column that runs
        // past the trailing edge on its own fraction keeps its width, and the strip scrolls.
        var idealX = gap
        // A column widened to its minimum moves every later one off its unrounded place; from
        // there on nothing is cut back or snapped, and the strip scrolls.
        var widened = false
        let trailingEdge = viewport.width - gap
        var frames: [CGRect] = []
        frames.reserveCapacity(widths.count)
        let widest = max(1, viewport.width - gap * 2)
        for (index, fraction) in widths.enumerated() {
            let ideal = pixelWidth(fraction: fraction, viewportWidth: viewport.width, gap: gap)
            var width = SplitGeometry.roundToPixel(ideal, scale: scale)
            let idealEnd = idealX + ideal
            idealX = idealEnd + gap
            let room = trailingEdge - x
            if !widened, room >= 1, idealEnd <= trailingEdge + edgeTolerance,
               width > room || abs(idealEnd - trailingEdge) <= edgeTolerance {
                // Fits before rounding: rounding neither pushes it past the edge nor stops it
                // short of an edge it was meant to reach.
                width = room
            }
            if index < minimumWidths.count, width < minimumWidths[index] {
                let minimum = SplitGeometry.ceilToPixel(min(minimumWidths[index], widest), scale: scale)
                if minimum > width { width = minimum; widened = true }
            }
            frames.append(CGRect(x: x, y: 0, width: width, height: viewport.height))
            x += width + gap
        }
        // Float sums land within a hair of the viewport; that hair is not scrollable content.
        let contentWidth = frames.isEmpty ? viewport.width : (x - viewport.width < 0.001 ? min(x, viewport.width) : x)
        return (frames, contentWidth)
    }

    /// Float slack when a column's unrounded end is compared with the strip's trailing edge.
    static let edgeTolerance: CGFloat = 0.01

    public static func maxOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    public static func clamp(_ offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(offset, 0), maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth))
    }

    /// Resting offsets: each column's leading edge at the viewport's leading
    /// edge, and each trailing edge at the trailing edge (both keep the gap
    /// visible), clamped and deduplicated, ascending.
    public static func snapOffsets(frames: [CGRect], contentWidth: CGFloat, viewportWidth: CGFloat, gap: CGFloat) -> [CGFloat] {
        var values: [CGFloat] = [0, maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)]
        for frame in frames {
            values.append(clamp(frame.minX - gap, contentWidth: contentWidth, viewportWidth: viewportWidth))
            values.append(clamp(frame.maxX + gap - viewportWidth, contentWidth: contentWidth, viewportWidth: viewportWidth))
        }
        values.sort()
        var result: [CGFloat] = []
        for value in values where result.last.map({ abs($0 - value) > 0.5 }) ?? true {
            result.append(value)
        }
        return result
    }

    /// Where a fling released at `offset` with `velocity` (points per second,
    /// positive = offset increasing) would coast to. Same model as
    /// `UIScrollView.decelerationRate.normal`.
    public static func projectedOffset(_ offset: CGFloat, velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        offset + (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// The snap offset a release should settle on: the one nearest the
    /// projected coast position. A fast fling always advances at least one
    /// snap point in its direction.
    public static func snapTarget(releaseOffset: CGFloat, velocity: CGFloat, snaps: [CGFloat], flingThreshold: CGFloat = 300) -> CGFloat {
        guard !snaps.isEmpty else { return releaseOffset }
        let projected = projectedOffset(releaseOffset, velocity: velocity)
        var best = snaps.min { abs($0 - projected) < abs($1 - projected) }!
        if velocity > flingThreshold, best <= releaseOffset + 0.5, let next = snaps.first(where: { $0 > releaseOffset + 0.5 }) {
            best = next
        } else if velocity < -flingThreshold, best >= releaseOffset - 0.5, let previous = snaps.last(where: { $0 < releaseOffset - 0.5 }) {
            best = previous
        }
        return best
    }

    /// The adjacent snap offset from `offset` in `direction` (+1 or -1), for
    /// discrete mouse wheel steps.
    public static func adjacentSnap(from offset: CGFloat, direction: Int, snaps: [CGFloat]) -> CGFloat {
        if direction > 0 { return snaps.first { $0 > offset + 0.5 } ?? snaps.last ?? offset }
        return snaps.last { $0 < offset - 0.5 } ?? snaps.first ?? offset
    }

    /// Rubber-band resistance past the ends, like AppKit elastic scrolling.
    public static func rubberBand(_ offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let upper = maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)
        let dimension = max(viewportWidth, 1)
        func resist(_ overshoot: CGFloat) -> CGFloat {
            (1 - 1 / (overshoot * 0.55 / dimension + 1)) * dimension
        }
        if offset < 0 { return -resist(-offset) }
        if offset > upper { return upper + resist(offset - upper) }
        return offset
    }

    /// The column whose leading edge is nearest the viewport's leading edge.
    public static func leadingColumnIndex(frames: [CGRect], offset: CGFloat, gap: CGFloat) -> Int? {
        frames.indices.min { abs(frames[$0].minX - gap - offset) < abs(frames[$1].minX - gap - offset) }
    }
}

/// A one-shot request to scroll the column holding `pane` to the viewport
/// center (`LayoutModel.centerColumn(containing:)`).
public nonisolated struct ColumnCenterRequest: Hashable, Sendable {
    public var pane: PaneID
    public var sequence: UInt64
}
