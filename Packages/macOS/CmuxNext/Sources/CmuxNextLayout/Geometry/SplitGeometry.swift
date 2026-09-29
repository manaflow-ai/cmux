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
            let aExtent = firstExtent(ratio: ratio, available: available, minimum: style.minimumPaneExtent, scale: scale)
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
            result.dividers.append(DividerGeometry(id: id, axis: axis, frame: divider, hitFrame: hit, container: rect))
            layout(a, in: aRect, style: style, scale: scale, into: &result)
            layout(b, in: bRect, style: style, scale: scale, into: &result)
        }
    }

    /// Extent of child `a`: ratio of the available space, clamped so both
    /// children keep `minimum` when there is room, and pixel-rounded.
    static func firstExtent(ratio: Double, available: CGFloat, minimum: CGFloat, scale: CGFloat) -> CGFloat {
        var value = available * CGFloat(ratio)
        if available >= minimum * 2 {
            value = min(max(value, minimum), available - minimum)
        }
        return roundToPixel(min(max(0, value), available), scale: scale)
    }

    /// The ratio that puts a divider under `pointer` (a coordinate along the
    /// split axis, same space as `container`). `grabOffset` is where inside
    /// the divider the drag started, so the divider does not jump on press.
    public static func ratio(
        forPointer pointer: CGFloat,
        grabOffset: CGFloat = 0,
        container: CGRect,
        axis: SplitAxis,
        style: LayoutStyle
    ) -> Double {
        let start = axis == .horizontal ? container.minX : container.minY
        let extent = axis == .horizontal ? container.width : container.height
        let available = extent - style.dividerThickness
        guard available > 0 else { return 0.5 }
        var aExtent = pointer - grabOffset - start
        if available >= style.minimumPaneExtent * 2 {
            aExtent = min(max(aExtent, style.minimumPaneExtent), available - style.minimumPaneExtent)
        }
        let ratio = Double(aExtent / available)
        return min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
    }

    public static func roundToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}
