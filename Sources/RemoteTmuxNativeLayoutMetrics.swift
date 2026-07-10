import Bonsplit
import Foundation

/// Converts between tmux cell geometry and the outer sizes of native Bonsplit panes.
struct RemoteTmuxNativeLayoutMetrics: Equatable, Sendable {
    let cellSize: CGSize
    let surfacePadding: CGSize
    let tabBarHeight: CGFloat
    let dividerThickness: CGFloat

    func clientGrid(
        layout: RemoteTmuxLayoutNode,
        contentSize: CGSize
    ) -> (columns: Int, rows: Int)? {
        guard contentSize.width > 1, contentSize.height > 1,
              cellSize.width > 1, cellSize.height > 1 else { return nil }
        let overhead = residual(of: layout)
        let columns = Int(floor((contentSize.width - overhead.width) / cellSize.width))
        let rows = Int(floor((contentSize.height - overhead.height) / cellSize.height))
        return (
            columns: max(RemoteTmuxMirrorGeometry.minCols, columns),
            rows: max(RemoteTmuxMirrorGeometry.minRows, rows)
        )
    }

    /// Native points not represented by the node's tmux cell span.
    ///
    /// A tmux separator already consumes one cell in the parent span. Replacing
    /// it with a native divider therefore contributes `divider - cell`, which
    /// may be negative when the native divider is thinner than a terminal cell.
    func residual(of node: RemoteTmuxLayoutNode) -> CGSize {
        switch node.content {
        case .pane:
            return CGSize(
                width: surfacePadding.width,
                height: tabBarHeight + surfacePadding.height
            )
        case .horizontal(let children):
            let childResiduals = children.map(residual(of:))
            return CGSize(
                width: childResiduals.reduce(0) { $0 + $1.width }
                    + separatorResidual(
                        count: children.count,
                        cellExtent: cellSize.width
                    ),
                height: childResiduals.map(\.height).max() ?? 0
            )
        case .vertical(let children):
            let childResiduals = children.map(residual(of:))
            return CGSize(
                width: childResiduals.map(\.width).max() ?? 0,
                height: childResiduals.reduce(0) { $0 + $1.height }
                    + separatorResidual(
                        count: children.count,
                        cellExtent: cellSize.height
                    )
            )
        }
    }

    func dividerFraction(
        first: RemoteTmuxLayoutNode,
        rest: [RemoteTmuxLayoutNode],
        orientation: SplitOrientation
    ) -> CGFloat {
        let firstExtent = extent(of: first, residual: residual(of: first), along: orientation)
        let restExtent = joinedExtent(of: rest, along: orientation)
        return firstExtent / max(1, firstExtent + restExtent)
    }

    func dividerFraction(
        first: RemoteTmuxNativeMeasuredSplitTree,
        second: RemoteTmuxNativeMeasuredSplitTree,
        orientation: SplitOrientation
    ) -> CGFloat {
        let firstExtent = extent(
            of: first.layout,
            residual: first.residual,
            along: orientation
        )
        let secondExtent = extent(
            of: second.layout,
            residual: second.residual,
            along: orientation
        )
        return firstExtent / max(1, firstExtent + secondExtent)
    }

    func requestedTmuxSpan(
        first: RemoteTmuxLayoutNode,
        orientation: SplitOrientation,
        parentExtent: CGFloat,
        dividerPosition: CGFloat
    ) -> Int {
        let available = parentExtent - dividerThickness
        let firstOuterExtent = available * dividerPosition
        let firstResidual = residualExtent(
            residual(of: first),
            along: orientation
        )
        let cells = (firstOuterExtent - firstResidual) / cellExtent(along: orientation)
        return max(1, Int(cells.rounded()))
    }

    func requestedTmuxSpan(
        first: RemoteTmuxNativeMeasuredSplitTree,
        orientation: SplitOrientation,
        parentExtent: CGFloat,
        dividerPosition: CGFloat
    ) -> Int {
        let available = parentExtent - dividerThickness
        let firstOuterExtent = available * dividerPosition
        let firstResidual = residualExtent(first.residual, along: orientation)
        let cells = (firstOuterExtent - firstResidual) / cellExtent(along: orientation)
        return max(1, Int(cells.rounded()))
    }

    /// Converts a native point delta to tmux cells along one split axis.
    func requestedTmuxCellDelta(
        pointDelta: CGFloat,
        orientation: SplitOrientation
    ) -> Int {
        let cell = cellExtent(along: orientation)
        guard cell > 0 else { return 0 }
        let cells = pointDelta / cell
        return max(1, NSNumber(value: Double(cells.rounded())).intValue)
    }

    /// Converts a requested outer native pane extent to terminal-grid cells,
    /// removing the pane chrome that tmux does not represent in its grid span.
    func requestedTmuxSpan(
        pane: RemoteTmuxLayoutNode,
        orientation: SplitOrientation,
        outerExtent: CGFloat
    ) -> Int {
        let cell = cellExtent(along: orientation)
        guard cell > 0 else { return 0 }
        let chrome = residualExtent(residual(of: pane), along: orientation)
        let cells = (outerExtent - chrome) / cell
        return max(1, NSNumber(value: Double(cells.rounded())).intValue)
    }

    func childExtents(parentExtent: CGFloat, dividerPosition: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let available = max(0, parentExtent - dividerThickness)
        let first = available * dividerPosition
        return (first: first, second: available - first)
    }

    func joinedResidual(
        first: CGSize,
        second: CGSize,
        orientation: SplitOrientation
    ) -> CGSize {
        if orientation == .horizontal {
            return CGSize(
                width: first.width + second.width + dividerThickness - cellSize.width,
                height: max(first.height, second.height)
            )
        }
        return CGSize(
            width: max(first.width, second.width),
            height: first.height + second.height + dividerThickness - cellSize.height
        )
    }

    private func extent(
        of node: RemoteTmuxLayoutNode,
        residual: CGSize,
        along orientation: SplitOrientation
    ) -> CGFloat {
        let cells = orientation == .horizontal ? node.width : node.height
        return CGFloat(cells) * cellExtent(along: orientation)
            + residualExtent(residual, along: orientation)
    }

    private func joinedExtent(
        of nodes: [RemoteTmuxLayoutNode],
        along orientation: SplitOrientation
    ) -> CGFloat {
        nodes.reduce(0) {
            $0 + extent(of: $1, residual: residual(of: $1), along: orientation)
        }
            + dividerThickness * CGFloat(max(0, nodes.count - 1))
    }

    private func residualExtent(
        _ residual: CGSize,
        along orientation: SplitOrientation
    ) -> CGFloat {
        orientation == .horizontal ? residual.width : residual.height
    }

    private func cellExtent(along orientation: SplitOrientation) -> CGFloat {
        orientation == .horizontal ? cellSize.width : cellSize.height
    }

    private func separatorResidual(count: Int, cellExtent: CGFloat) -> CGFloat {
        CGFloat(max(0, count - 1)) * (dividerThickness - cellExtent)
    }
}
