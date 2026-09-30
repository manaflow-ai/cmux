public import CoreGraphics

/// A divider in computed geometry. All rects use a top-left origin.
public nonisolated struct DividerGeometry: Hashable, Sendable {
    public var id: SplitID
    public var axis: SplitAxis
    /// Visible divider line.
    public var frame: CGRect
    /// Draggable area, centered on `frame`.
    public var hitFrame: CGRect
    /// The rect the split node divides; the drag maps pointer position into it.
    public var container: CGRect
    /// Smallest extent along `axis` that child `a` (the leading or top side)
    /// and child `b` need so every pane inside keeps `LayoutStyle.minimumPaneSize`.
    public var minimumA: CGFloat = 0
    public var minimumB: CGFloat = 0
}

/// Frames for one split tree.
public nonisolated struct SplitLayoutResult: Hashable, Sendable {
    public var panes: [PaneID: CGRect] = [:]
    public var dividers: [DividerGeometry] = []
}

/// Pure frame computation for split trees. Coordinates are top-left origin
/// (views in this module are flipped).
public nonisolated enum SplitGeometry {
    /// Computes pane and divider frames for `node` filling `rect`.
    /// Edges are rounded to `scale` so panes never straddle device pixels.
    public static func layout(_ node: SplitNode, in rect: CGRect, style: LayoutStyle, scale: CGFloat = 2) -> SplitLayoutResult {
        var result = SplitLayoutResult()
        layout(node, in: rect, style: style, scale: scale, into: &result)
        return result
    }

    private static func layout(_ node: SplitNode, in rect: CGRect, style: LayoutStyle, scale: CGFloat, into result: inout SplitLayoutResult) {
        switch node {
        case let .leaf(pane):
            result.panes[pane] = rect
        case let .split(id, axis, ratio, a, b):
            let t = style.dividerThickness
            let extent = axis == .horizontal ? rect.width : rect.height
            let available = max(0, extent - t)
            let minimumA = minimumSize(of: a, style: style).extent(along: axis)
            let minimumB = minimumSize(of: b, style: style).extent(along: axis)
            let aExtent = firstExtent(ratio: ratio, available: available, minimumA: minimumA, minimumB: minimumB, scale: scale)
            let aRect: CGRect
            let divider: CGRect
            let bRect: CGRect
            switch axis {
            case .horizontal:
                aRect = CGRect(x: rect.minX, y: rect.minY, width: aExtent, height: rect.height)
                divider = CGRect(x: rect.minX + aExtent, y: rect.minY, width: t, height: rect.height)
                bRect = CGRect(x: divider.maxX, y: rect.minY, width: max(0, rect.maxX - divider.maxX), height: rect.height)
            case .vertical:
                aRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: aExtent)
                divider = CGRect(x: rect.minX, y: rect.minY + aExtent, width: rect.width, height: t)
                bRect = CGRect(x: rect.minX, y: divider.maxY, width: rect.width, height: max(0, rect.maxY - divider.maxY))
            }
            let grow = max(0, style.dividerHitThickness - t) / 2
            let hit = axis == .horizontal ? divider.insetBy(dx: -grow, dy: 0) : divider.insetBy(dx: 0, dy: -grow)
            result.dividers.append(DividerGeometry(id: id, axis: axis, frame: divider, hitFrame: hit, container: rect,
                                                   minimumA: minimumA, minimumB: minimumB))
            layout(a, in: aRect, style: style, scale: scale, into: &result)
            layout(b, in: bRect, style: style, scale: scale, into: &result)
        }
    }

    /// Smallest size `node` can take with every pane at least
    /// `style.minimumPaneSize`: a same-axis chain adds its children and
    /// dividers, a perpendicular split takes the larger child.
    public static func minimumSize(of node: SplitNode, style: LayoutStyle) -> CGSize {
        switch node {
        case .leaf:
            return style.minimumPaneSize
        case let .split(_, axis, _, a, b):
            let first = minimumSize(of: a, style: style)
            let second = minimumSize(of: b, style: style)
            let t = style.dividerThickness
            switch axis {
            case .horizontal:
                return CGSize(width: first.width + t + second.width, height: max(first.height, second.height))
            case .vertical:
                return CGSize(width: max(first.width, second.width), height: first.height + t + second.height)
            }
        }
    }

    /// Extent of child `a`: `ratio` of the available space, clamped so `a`
    /// keeps `minimumA` and `b` keeps `minimumB`. When both cannot fit (a
    /// tree deeper than its container, built by another client), space is
    /// shared in proportion to the minimums, so every pane shrinks evenly
    /// and none collapses to zero. Pixel-rounded.
    static func firstExtent(ratio: Double, available: CGFloat, minimumA: CGFloat, minimumB: CGFloat, scale: CGFloat) -> CGFloat {
        var value = available * CGFloat(ratio)
        if available >= minimumA + minimumB {
            value = min(max(value, minimumA), available - minimumB)
            // Rounding must not take a pixel from either minimum.
            let rounded = roundToPixel(value, scale: scale)
            if rounded < minimumA { return ceilToPixel(minimumA, scale: scale) }
            if available - rounded < minimumB { return floorToPixel(available - minimumB, scale: scale) }
            return rounded
        } else if minimumA + minimumB > 0 {
            value = available * minimumA / (minimumA + minimumB)
        }
        return roundToPixel(min(max(0, value), available), scale: scale)
    }

    /// The ratio that puts a divider under `pointer` (a coordinate along the
    /// split axis, same space as `container`). `grabOffset` is where inside
    /// the divider the drag started, so the divider does not jump on press.
    /// `minimumA` and `minimumB` are the children's minimum extents
    /// (`DividerGeometry`); nil means a single pane on that side.
    public static func ratio(
        forPointer pointer: CGFloat,
        grabOffset: CGFloat = 0,
        container: CGRect,
        axis: SplitAxis,
        style: LayoutStyle,
        minimumA: CGFloat? = nil,
        minimumB: CGFloat? = nil
    ) -> Double {
        let start = axis == .horizontal ? container.minX : container.minY
        let extent = axis == .horizontal ? container.width : container.height
        let available = extent - style.dividerThickness
        guard available > 0 else { return 0.5 }
        let leaf = style.minimumPaneSize.extent(along: axis)
        let minA = minimumA ?? leaf, minB = minimumB ?? leaf
        var aExtent = pointer - grabOffset - start
        if available >= minA + minB {
            aExtent = min(max(aExtent, minA), available - minB)
        }
        let ratio = Double(aExtent / available)
        return min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
    }

    public static func roundToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    static func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale - 0.001).rounded(.up) / scale
    }

    static func floorToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale + 0.001).rounded(.down) / scale
    }
}

extension CGSize {
    /// Width for a horizontal split, height for a vertical one.
    nonisolated func extent(along axis: SplitAxis) -> CGFloat {
        axis == .horizontal ? width : height
    }
}
