public import CoreGraphics

/// One horizontal scroll area (plans/cmux-next/scroll-areas-DESIGN.md G1): a split tree that
/// needs more width than its frame, laid out at its minimum width and shown through the frame.
///
/// Frames are in the same space as the tree's panes (strip space for a strip column, view space
/// for a docked column or a split screen), before the area's own offset.
public nonisolated struct ScrollAreaGeometry: Hashable, Sendable {
    /// The root split of the tree; stable while that split lives.
    public var id: SplitID
    /// The frame the tree shows through.
    public var window: CGRect
    /// Width of the laid-out tree; more than `window.width`.
    public var contentWidth: CGFloat
    /// The tree's panes in visual order.
    public var panes: [PaneID]
    /// The cells of the root's horizontal chain, leading to trailing: each cell's panes and
    /// the frame around them (content space). The scroll reducer sees each cell as a column.
    public var cells: [Cell]
    /// The split dividers inside the tree.
    public var splits: [SplitID]

    /// One cell of the root's horizontal chain.
    public struct Cell: Hashable, Sendable {
        public var panes: [PaneID]
        public var frame: CGRect
        /// Each pane's frame (content space).
        public var paneFrames: [PaneID: CGRect]
    }

    /// The largest offset: the tree's trailing edge at the window's trailing edge.
    public var maxOffset: CGFloat { max(0, contentWidth - window.width) }

    /// `rect` (a pane of this area, content space) mapped into the window in proportion: the
    /// area's panes keep their order and never overlap a neighboring column, so directional
    /// focus steps through them one by one and leaves the area at its ends (K1).
    public func navigationRect(_ rect: CGRect) -> CGRect {
        guard contentWidth > 0 else { return rect }
        let factor = window.width / contentWidth
        return CGRect(x: window.minX + (rect.minX - window.minX) * factor, y: rect.minY, width: rect.width * factor, height: rect.height)
    }

    /// The cells of `root`'s horizontal chain: a horizontal split's sides, recursively, until a
    /// leaf or a vertical split, which is one cell.
    static func cells(of root: SplitNode) -> [SplitNode] {
        if case let .split(_, .horizontal, _, a, b) = root { return cells(of: a) + cells(of: b) }
        return [root]
    }

    /// The area `root` makes in `window`, or nil when the tree fits (G1): its minimum width
    /// (`SplitGeometry.minimumSize`) is wider than the window. Only a split can overflow.
    static func overflow(of root: SplitNode, in window: CGRect, style: LayoutStyle, scale: CGFloat) -> (id: SplitID, content: CGRect)? {
        guard style.scrollAreasEnabled, case let .split(id, _, _, _, _) = root else { return nil }
        let needed = SplitGeometry.ceilToPixel(SplitGeometry.minimumSize(of: root, style: style).width, scale: scale)
        guard needed > window.width + 0.5 else { return nil }
        return (id, CGRect(x: window.minX, y: window.minY, width: needed, height: window.height))
    }
}
