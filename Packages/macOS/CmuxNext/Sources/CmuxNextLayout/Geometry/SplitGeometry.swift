public import CoreGraphics

/// A divider in computed geometry. All rects use a top-left origin.
public nonisolated struct DividerGeometry: Hashable, Sendable {
    public var id: SplitID
    public var axis: SplitAxis
    /// Visible divider line.
    public var frame: CGRect
    /// Draggable area, centered on `frame` (`DividerBand`).
    public var hitFrame: CGRect
    /// The rect the split node divides; the drag maps pointer position into it.
    public var container: CGRect
    /// Smallest extent along `axis` that child `a` (the leading or top side)
    /// and child `b` need so every pane inside keeps `LayoutStyle.minimumPaneSize`.
    public var minimumA: CGFloat = 0
    public var minimumB: CGFloat = 0
    /// The extent child `a` (`b`) takes folded into bars (``LayoutStyle/collapsesPanes(along:)``); nil when it
    /// cannot fold along `axis`. A side laid out below its minimum shows folded (`PaneChromeFit`).
    public var collapsedA: CGFloat?
    public var collapsedB: CGFloat?
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
        // Child minimums of every split in one bottom-up pass: asking
        // `minimumSize` at each split walked its whole subtree again, so a
        // deep tree cost O(N * depth), a same-axis chain O(N^2).
        // A split id can repeat in one tree (`split@<firstPane>` from a daemon
        // without split ids, LayoutHandleMap): those splits use the recursive path.
        var minimums: [SplitID: SplitMinimums] = [:]
        var repeated: Set<SplitID> = []
        _ = collectMinimums(node, style: style, into: &minimums, repeated: &repeated)
        for id in repeated { minimums[id] = nil }
        layout(node, in: rect, style: style, scale: scale, minimums: minimums, into: &result)
        return result
    }

    /// A split's children's minimum sizes, unfolded and folded (``collapsedSize(of:style:)``).
    struct SplitMinimums {
        var a: CGSize
        var b: CGSize
        var collapsedA: CGSize
        var collapsedB: CGSize
    }

    private static func collectMinimums(_ node: SplitNode, style: LayoutStyle, into minimums: inout [SplitID: SplitMinimums],
                                        repeated: inout Set<SplitID>) -> (minimum: CGSize, collapsed: CGSize) {
        switch node {
        case .leaf:
            return (style.minimumPaneSize, collapsedLeaf(style))
        case let .split(id, axis, _, a, b):
            let first = collectMinimums(a, style: style, into: &minimums, repeated: &repeated)
            let second = collectMinimums(b, style: style, into: &minimums, repeated: &repeated)
            let entry = SplitMinimums(a: first.minimum, b: second.minimum, collapsedA: first.collapsed, collapsedB: second.collapsed)
            if minimums.updateValue(entry, forKey: id) != nil { repeated.insert(id) }
            return (combine(first.minimum, second.minimum, axis: axis, divider: style.dividerThickness),
                    combine(first.collapsed, second.collapsed, axis: axis, divider: style.dividerThickness))
        }
    }

    /// One pane folded: the bar's extent along each axis it folds on, infinite along one it cannot.
    private static func collapsedLeaf(_ style: LayoutStyle) -> CGSize {
        CGSize(width: style.collapsesPanes(along: .horizontal) ? style.collapsedPaneExtent : .infinity,
               height: style.collapsesPanes(along: .vertical) ? style.collapsedPaneExtent : .infinity)
    }

    private static func combine(_ first: CGSize, _ second: CGSize, axis: SplitAxis, divider t: CGFloat) -> CGSize {
        switch axis {
        case .horizontal:
            CGSize(width: first.width + t + second.width, height: max(first.height, second.height))
        case .vertical:
            CGSize(width: max(first.width, second.width), height: first.height + t + second.height)
        }
    }

    private static func layout(_ node: SplitNode, in rect: CGRect, style: LayoutStyle, scale: CGFloat,
                               minimums: [SplitID: SplitMinimums], into result: inout SplitLayoutResult) {
        switch node {
        case let .leaf(pane):
            result.panes[pane] = rect
        case let .split(id, axis, ratio, a, b):
            let t = style.dividerThickness
            let extent = axis == .horizontal ? rect.width : rect.height
            let available = max(0, extent - t)
            let childMinimums = minimums[id] ?? SplitMinimums(a: minimumSize(of: a, style: style), b: minimumSize(of: b, style: style),
                                                              collapsedA: collapsedSize(of: a, style: style),
                                                              collapsedB: collapsedSize(of: b, style: style))
            let minimumA = childMinimums.a.extent(along: axis)
            let minimumB = childMinimums.b.extent(along: axis)
            let collapsedA = finite(childMinimums.collapsedA.extent(along: axis))
            let collapsedB = finite(childMinimums.collapsedB.extent(along: axis))
            let aExtent = firstExtent(ratio: ratio, available: available, minimumA: minimumA, minimumB: minimumB,
                                      collapsedA: collapsedA, collapsedB: collapsedB, scale: scale)
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
            let hit = DividerBand(axis: axis, center: axis == .horizontal ? divider.midX : divider.midY, lineThickness: t,
                                  hitThickness: style.effectiveDividerHitThickness,
                                  crossStart: axis == .horizontal ? rect.minY : rect.minX,
                                  crossLength: axis == .horizontal ? rect.height : rect.width, scale: scale).hit
            result.dividers.append(DividerGeometry(id: id, axis: axis, frame: divider, hitFrame: hit, container: rect,
                                                   minimumA: minimumA, minimumB: minimumB, collapsedA: collapsedA, collapsedB: collapsedB))
            layout(a, in: aRect, style: style, scale: scale, minimums: minimums, into: &result)
            layout(b, in: bRect, style: style, scale: scale, minimums: minimums, into: &result)
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
            return combine(minimumSize(of: a, style: style), minimumSize(of: b, style: style), axis: axis,
                           divider: style.dividerThickness)
        }
    }

    /// Smallest size `node` takes with every pane folded into a bar (``LayoutStyle/collapsedPaneExtent``), the
    /// way ``minimumSize(of:style:)`` adds a chain; infinite along an axis on which its panes cannot fold.
    public static func collapsedSize(of node: SplitNode, style: LayoutStyle) -> CGSize {
        switch node {
        case .leaf:
            return collapsedLeaf(style)
        case let .split(_, axis, _, a, b):
            return combine(collapsedSize(of: a, style: style), collapsedSize(of: b, style: style), axis: axis,
                           divider: style.dividerThickness)
        }
    }

    private static func finite(_ value: CGFloat) -> CGFloat? { value.isFinite ? value : nil }

    /// Extent of child `a`: `ratio` of the available space, clamped so `a`
    /// keeps `minimumA` and `b` keeps `minimumB`. A side whose share is below
    /// its minimum and that can fold (`collapsedA`, `collapsedB` non-nil) folds
    /// to that extent and the other side takes the rest; when both would, the
    /// smaller share folds. When neither folds and both cannot fit (a tree
    /// deeper than its container, built by another client), space is shared in
    /// proportion to the minimums, so every pane shrinks evenly and none
    /// collapses to zero. Pixel-rounded.
    static func firstExtent(ratio: Double, available: CGFloat, minimumA: CGFloat, minimumB: CGFloat,
                            collapsedA: CGFloat? = nil, collapsedB: CGFloat? = nil, scale: CGFloat) -> CGFloat {
        var value = available * CGFloat(ratio)
        let foldsA = collapsedA != nil && value < minimumA - 0.5
        let foldsB = collapsedB != nil && available - value < minimumB - 0.5
        if foldsA, let collapsedA, !foldsB || value <= available - value {
            return ceilToPixel(min(collapsedA, available), scale: scale)
        }
        if foldsB, let collapsedB {
            return floorToPixel(max(0, available - collapsedB), scale: scale)
        }
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
    /// (`DividerGeometry`); nil means a single pane on that side. A divider
    /// within `snapDistance` points of one of `snaps` (ratios) lands on it,
    /// if both sides keep their minimums there. A side that can fold
    /// (`collapsedA`, `collapsedB`; for a single pane, ``LayoutStyle/collapsesPanes(along:)``)
    /// folds once the pointer passes halfway from its minimum to its folded
    /// extent: the ratio goes to the end of ``SplitRatio/range``, so the fold
    /// stays at any container size, and dragged back the side unfolds at its minimum.
    public static func ratio(
        forPointer pointer: CGFloat,
        grabOffset: CGFloat = 0,
        container: CGRect,
        axis: SplitAxis,
        style: LayoutStyle,
        minimumA: CGFloat? = nil,
        minimumB: CGFloat? = nil,
        collapsedA: CGFloat? = nil,
        collapsedB: CGFloat? = nil,
        snaps: [Double] = [],
        snapDistance: CGFloat = 0
    ) -> Double {
        let start = axis == .horizontal ? container.minX : container.minY
        let extent = axis == .horizontal ? container.width : container.height
        let available = extent - style.dividerThickness
        guard available > 0 else { return 0.5 }
        let leaf = style.minimumPaneSize.extent(along: axis)
        let minA = minimumA ?? leaf, minB = minimumB ?? leaf
        let leafFold = style.collapsesPanes(along: axis) ? style.collapsedPaneExtent : nil
        let foldA = collapsedA ?? (minimumA == nil ? leafFold : nil), foldB = collapsedB ?? (minimumB == nil ? leafFold : nil)
        var aExtent = pointer - grabOffset - start
        if let foldA, aExtent < minA, aExtent < (foldA + minA) / 2 { return SplitRatio.range.lowerBound }
        if let foldB, available - aExtent < minB, available - aExtent < (foldB + minB) / 2 { return SplitRatio.range.upperBound }
        if available >= minA + minB {
            aExtent = min(max(aExtent, minA), available - minB)
        }
        let snap = snaps.map { (ratio: $0, at: CGFloat($0) * available) }
            .filter { abs($0.at - aExtent) <= snapDistance && $0.at >= minA && available - $0.at >= minB }
            .min { abs($0.at - aExtent) < abs($1.at - aExtent) }
        let ratio = snap?.ratio ?? Double(aExtent / available)
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
