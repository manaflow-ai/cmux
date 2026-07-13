public import Foundation

/// Converts between tmux cell geometry and native split-pane outer sizes.
public struct RemoteTmuxNativeLayoutMetrics: Equatable, Sendable {
    public let cellSize: CGSize
    public let surfacePadding: CGSize
    public let tabBarHeight: CGFloat
    public let dividerThickness: CGFloat
    /// Extra height each pane's outer size carries for tmux's own title row
    /// (`pane-border-status`): one cell when active, zero otherwise. tmux
    /// assigns the pane one row FEWER than its visual region — the title row
    /// is tmux chrome inside the pane's rectangle but outside its grid — so
    /// the claim must reserve it and the ideals must grant it, or every pane
    /// renders one row over and the accounting drifts.
    public var paneTitleRowHeight: CGFloat
    private let paneTitleRowPaneIDs: Set<Int>?
    /// One point of slack per pane per axis: extents are quantized to whole
    /// points on cumulative rails rounded to NEAREST, so a pane sits within
    /// half a point of its exact span — and half a point below an exact
    /// boundary would cost a whole column when the surface floors to cells.
    /// One point covers the worst case (0.5) with the same again as margin.
    /// Whole points and nearest are both load-bearing: finer grids leave
    /// nested view edges on half pixels where backing alignment shaves a
    /// device pixel, and rounding UP would overshoot into trailing siblings
    /// and compound across cross-axis nesting levels.
    public static let paneQuantizationSlack: CGFloat = 1

    /// Creates the point-space metrics used by the remote-tmux layout planner.
    ///
    /// - Parameters:
    ///   - cellSize: One terminal cell's native point size.
    ///   - surfacePadding: Native surface chrome outside the rendered grid.
    ///   - tabBarHeight: Native tab-strip height carried by every pane.
    ///   - dividerThickness: Native split divider thickness.
    ///   - paneTitleRowHeight: Height of tmux's configured pane status row.
    ///   - paneTitleRowPaneIDs: Panes touching the configured status-row edge.
    ///     Pass `nil` only when the full patched layout will be supplied to each operation.
    public init(
        cellSize: CGSize,
        surfacePadding: CGSize,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat,
        paneTitleRowHeight: CGFloat = 0,
        paneTitleRowPaneIDs: Set<Int>? = nil
    ) {
        self.cellSize = cellSize
        self.surfacePadding = surfacePadding
        self.tabBarHeight = tabBarHeight
        self.dividerThickness = dividerThickness
        self.paneTitleRowHeight = paneTitleRowHeight
        self.paneTitleRowPaneIDs = paneTitleRowPaneIDs
    }

    public func clientGrid(
        layout: RemoteTmuxLayoutNode,
        contentSize: CGSize
    ) -> (columns: Int, rows: Int)? {
        guard contentSize.width > 1, contentSize.height > 1,
              cellSize.width > 1, cellSize.height > 1 else { return nil }
        // Tmux owns pane-title rows inside the client grid: after the client
        // claims the window size, tmux removes those rows from pane_height.
        // Native layout adds them back to each pane's outer extent below, but
        // subtracting them here would charge the same server chrome twice.
        let overhead = clientGridResidual(of: layout)
        let columns = Int(floor((contentSize.width - overhead.width) / cellSize.width))
        let rows = Int(floor((contentSize.height - overhead.height) / cellSize.height))
        return (
            columns: max(RemoteTmuxMirrorGeometry.minCols, columns),
            rows: max(RemoteTmuxMirrorGeometry.minRows, rows)
        )
    }

    /// Native points the planner reserves beyond the node's tmux cell span.
    ///
    /// A tmux separator already consumes one cell in the parent span. Replacing
    /// it with a native divider therefore contributes `divider - cell`, which
    /// may be negative when the native divider is thinner than a terminal cell.
    /// Pane residuals also include placement slack for whole-point rail
    /// rounding; tmux grid claims use a separate chrome-only residual.
    public func residual(of node: RemoteTmuxLayoutNode) -> CGSize {
        residual(
            of: node,
            panePlacementSlack: Self.paneQuantizationSlack,
            paneTitleRowPaneIDs: resolvedPaneTitleRowPaneIDs(for: node)
        )
    }

    /// Native chrome residual without optional placement slack.
    func minimumResidual(of node: RemoteTmuxLayoutNode) -> CGSize {
        residual(
            of: node,
            panePlacementSlack: 0,
            paneTitleRowPaneIDs: resolvedPaneTitleRowPaneIDs(for: node)
        )
    }

    private func clientGridResidual(of node: RemoteTmuxLayoutNode) -> CGSize {
        residual(of: node, panePlacementSlack: 0, paneTitleRowPaneIDs: [])
    }

    private func residual(
        of node: RemoteTmuxLayoutNode,
        panePlacementSlack: CGFloat,
        paneTitleRowPaneIDs: Set<Int>
    ) -> CGSize {
        switch node.content {
        case .pane(let paneID):
            return CGSize(
                width: surfacePadding.width + panePlacementSlack,
                height: tabBarHeight + surfacePadding.height
                    + (paneTitleRowPaneIDs.contains(paneID) ? paneTitleRowHeight : 0)
                    + panePlacementSlack
            )
        case .horizontal(let children):
            let childResiduals = children.map {
                residual(
                    of: $0,
                    panePlacementSlack: panePlacementSlack,
                    paneTitleRowPaneIDs: paneTitleRowPaneIDs
                )
            }
            return CGSize(
                width: childResiduals.reduce(0) { $0 + $1.width }
                    + separatorResidual(
                        count: children.count,
                        cellExtent: cellSize.width
                    ),
                height: childResiduals.map(\.height).max() ?? 0
            )
        case .vertical(let children):
            let childResiduals = children.map {
                residual(
                    of: $0,
                    panePlacementSlack: panePlacementSlack,
                    paneTitleRowPaneIDs: paneTitleRowPaneIDs
                )
            }
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

    func resolvingPaneTitleRows(in layout: RemoteTmuxLayoutNode) -> Self {
        guard paneTitleRowPaneIDs == nil, paneTitleRowHeight > 0 else { return self }
        return Self(
            cellSize: cellSize,
            surfacePadding: surfacePadding,
            tabBarHeight: tabBarHeight,
            dividerThickness: dividerThickness,
            paneTitleRowHeight: paneTitleRowHeight,
            paneTitleRowPaneIDs: resolvedPaneTitleRowPaneIDs(for: layout)
        )
    }

    private func resolvedPaneTitleRowPaneIDs(for layout: RemoteTmuxLayoutNode) -> Set<Int> {
        guard paneTitleRowHeight > 0 else { return [] }
        if let paneTitleRowPaneIDs { return paneTitleRowPaneIDs }
        if let placement = RemoteTmuxPaneTitleRowPlacement.inferred(in: layout) {
            return placement.paneIDs(in: layout)
        }
        return Set(layout.paneIDsInOrder)
    }

    public func dividerFraction(
        first: RemoteTmuxLayoutNode,
        rest: [RemoteTmuxLayoutNode],
        orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        let firstExtent = extent(of: first, residual: residual(of: first), along: orientation)
        let restExtent = joinedExtent(of: rest, along: orientation)
        return firstExtent / max(1, firstExtent + restExtent)
    }

    public func dividerFraction(
        first: RemoteTmuxNativeMeasuredSplitTree,
        second: RemoteTmuxNativeMeasuredSplitTree,
        orientation: RemoteTmuxSplitOrientation
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

    /// Preferred points for a subtree: its cell span, chrome, and placement slack.
    public func idealExtent(
        of tree: RemoteTmuxNativeMeasuredSplitTree,
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        extent(of: tree.layout, residual: tree.residual, along: orientation)
    }

    /// The point extent that preserves every assigned cell before optional placement slack.
    func minimumIdealExtent(
        of tree: RemoteTmuxNativeMeasuredSplitTree,
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        extent(
            of: tree.layout,
            residual: tree.minimumResidual,
            along: orientation
        )
    }

    /// The whole-point extent the FIRST subtree of a split should receive:
    /// its ideal extent — scaled down evenly when the split's actual extent
    /// cannot fit both subtrees' ideals — plus the region's leading-edge
    /// rounding error (`carry`), rounded to the nearest whole point.
    /// `round(ideal + carry)` is "round the boundary's absolute coordinate,
    /// measured from the region's rounded leading edge", so allocations
    /// track exact boundary positions and per-split error cannot accumulate
    /// with depth (see the plan walk in ``RemoteTmuxNativeSplitLayoutPlanner`` for
    /// how the carries flow through the tree).
    ///
    /// When the ideals do not fit (mid-resize, a co-attached client holding
    /// the window small, tmux briefly exceeding the claim on one axis)
    /// every subtree shrinks by the same factor — an even degradation with
    /// no pane singled out. Returns nil only for a degenerate extent
    /// (nothing to divide).
    ///
    /// `secondCarry` is the rounding error of the freshly placed boundary —
    /// its exact position minus its rounded position — which is precisely
    /// the trailing subtree's leading-edge error along this split's axis.
    public func railAllocation(
        firstIdeal: CGFloat,
        secondIdeal: CGFloat,
        carry: CGFloat,
        available: CGFloat
    ) -> (firstExtent: CGFloat, secondCarry: CGFloat)? {
        guard available > 0 else { return nil }
        let idealSum = firstIdeal + secondIdeal
        // Fit is judged against the EXACT span, not the rounded one. The
        // carry is positional — this region's leading edge landed |carry|
        // inside or beyond its exact position — so `available - carry` is
        // the true room the ideals were budgeted for. Comparing against the
        // rounded span would let a half-point edge masquerade as
        // overconstraint and scale every child down when everything fits.
        let exactSpan = available - carry
        let scale = idealSum > exactSpan && idealSum > 0 ? max(0, exactSpan) / idealSum : 1
        let target = firstIdeal * scale + carry
        // NEAREST whole point: rounding the boundary's absolute coordinate
        // keeps every edge within half a point of exact — every pane within
        // one point of ideal, which the per-pane quantization slack covers.
        // Rounding up instead would overshoot into trailing siblings.
        let allocated = min(max(0, target.rounded()), available)
        let secondCarry = min(max(target - allocated, -0.5), 0.5)
        return (firstExtent: allocated, secondCarry: secondCarry)
    }

    /// Allocates a rail without letting optional placement slack consume required cell extents.
    func railAllocation(
        firstIdeal: CGFloat,
        secondIdeal: CGFloat,
        firstMinimum: CGFloat,
        secondMinimum: CGFloat,
        carry: CGFloat,
        available: CGFloat
    ) -> (firstExtent: CGFloat, secondCarry: CGFloat)? {
        guard available > 0 else { return nil }
        let tolerance: CGFloat = 0.0001
        let minimumFirstExtent = (firstMinimum - tolerance).rounded(.up)
        let maximumFirstExtent = (available - secondMinimum + tolerance).rounded(.down)
        let minimumsFit = firstMinimum + secondMinimum <= available + tolerance
            && minimumFirstExtent <= maximumFirstExtent

        let target: CGFloat
        if minimumsFit {
            let exactSpan = available - carry
            if firstIdeal + secondIdeal <= exactSpan {
                target = firstIdeal + carry
            } else {
                let firstSlack = max(0, firstIdeal - firstMinimum)
                let secondSlack = max(0, secondIdeal - secondMinimum)
                let totalSlack = firstSlack + secondSlack
                let spare = max(0, available - firstMinimum - secondMinimum)
                let grantedFirstSlack = totalSlack > 0
                    ? min(firstSlack, spare * firstSlack / totalSlack)
                    : 0
                target = firstMinimum + grantedFirstSlack + carry
            }
        } else {
            let minimumSum = firstMinimum + secondMinimum
            let scale = minimumSum > 0 ? max(0, available) / minimumSum : 1
            target = firstMinimum * scale + carry
        }

        let boundedTarget = minimumsFit
            ? min(max(target, minimumFirstExtent), maximumFirstExtent)
            : target
        let allocated = min(max(0, boundedTarget.rounded()), available)
        let secondCarry = min(max(boundedTarget - allocated, -0.5), 0.5)
        return (firstExtent: allocated, secondCarry: secondCarry)
    }

    public func requestedTmuxSpan(
        first: RemoteTmuxLayoutNode,
        orientation: RemoteTmuxSplitOrientation,
        parentExtent: CGFloat,
        dividerPosition: CGFloat
    ) -> Int {
        let available = parentExtent - dividerThickness
        let firstOuterExtent = available * dividerPosition
        let firstResidual = residualExtent(
            minimumResidual(of: first),
            along: orientation
        )
        let cells = (firstOuterExtent - firstResidual) / cellExtent(along: orientation)
        return max(1, Int(cells.rounded()))
    }

    public func requestedTmuxSpan(
        first: RemoteTmuxNativeMeasuredSplitTree,
        orientation: RemoteTmuxSplitOrientation,
        parentExtent: CGFloat,
        dividerPosition: CGFloat
    ) -> Int {
        let available = parentExtent - dividerThickness
        let firstOuterExtent = available * dividerPosition
        let firstResidual = residualExtent(first.minimumResidual, along: orientation)
        let cells = (firstOuterExtent - firstResidual) / cellExtent(along: orientation)
        return max(1, Int(cells.rounded()))
    }

    /// Converts a native point delta to tmux cells along one split axis.
    public func requestedTmuxCellDelta(
        pointDelta: CGFloat,
        orientation: RemoteTmuxSplitOrientation
    ) -> Int {
        let cell = cellExtent(along: orientation)
        guard cell > 0 else { return 0 }
        let cells = pointDelta / cell
        return max(1, NSNumber(value: Double(cells.rounded())).intValue)
    }

    /// Converts a requested outer native pane extent to terminal-grid cells,
    /// removing the pane chrome that tmux does not represent in its grid span.
    public func requestedTmuxSpan(
        pane: RemoteTmuxLayoutNode,
        orientation: RemoteTmuxSplitOrientation,
        outerExtent: CGFloat
    ) -> Int {
        let cell = cellExtent(along: orientation)
        guard cell > 0 else { return 0 }
        let chrome = residualExtent(minimumResidual(of: pane), along: orientation)
        let cells = (outerExtent - chrome) / cell
        return max(1, NSNumber(value: Double(cells.rounded())).intValue)
    }

    public func childExtents(parentExtent: CGFloat, dividerPosition: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let available = max(0, parentExtent - dividerThickness)
        // Whole points: the native split view lays children out on the point
        // grid, so modeling the division unrounded would disagree with the
        // sizes panes actually receive.
        let first = (available * dividerPosition).rounded()
        return (first: first, second: max(0, available - first))
    }

    /// Splits a parent's size into the two child sizes a split with
    /// `firstExtent` points for its first child produces — the one shared
    /// model of a split's geometry, used by the divider plan (writing
    /// fractions to the native tree) and the drag sync walk (reading them
    /// back), so the two directions can never disagree about child sizes.
    public func childSizes(
        parentSize: CGSize,
        orientation: RemoteTmuxSplitOrientation,
        firstExtent: CGFloat
    ) -> (first: CGSize, second: CGSize) {
        let parentExtent = orientation == .horizontal ? parentSize.width : parentSize.height
        let available = max(0, parentExtent - dividerThickness)
        let first = min(max(0, firstExtent), available)
        let second = max(0, available - first)
        if orientation == .horizontal {
            return (
                first: CGSize(width: first, height: parentSize.height),
                second: CGSize(width: second, height: parentSize.height)
            )
        }
        return (
            first: CGSize(width: parentSize.width, height: first),
            second: CGSize(width: parentSize.width, height: second)
        )
    }

    func joinedResidual(
        first: CGSize,
        second: CGSize,
        orientation: RemoteTmuxSplitOrientation
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
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        let cells = orientation == .horizontal ? node.width : node.height
        return CGFloat(cells) * cellExtent(along: orientation)
            + residualExtent(residual, along: orientation)
    }

    private func joinedExtent(
        of nodes: [RemoteTmuxLayoutNode],
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        nodes.reduce(0) {
            $0 + extent(of: $1, residual: residual(of: $1), along: orientation)
        }
            + dividerThickness * CGFloat(max(0, nodes.count - 1))
    }

    private func residualExtent(
        _ residual: CGSize,
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        orientation == .horizontal ? residual.width : residual.height
    }

    private func cellExtent(along orientation: RemoteTmuxSplitOrientation) -> CGFloat {
        orientation == .horizontal ? cellSize.width : cellSize.height
    }

    private func separatorResidual(count: Int, cellExtent: CGFloat) -> CGFloat {
        CGFloat(max(0, count - 1)) * (dividerThickness - cellExtent)
    }
}
