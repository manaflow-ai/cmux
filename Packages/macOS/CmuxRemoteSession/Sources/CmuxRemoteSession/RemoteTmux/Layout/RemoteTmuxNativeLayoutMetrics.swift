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
    /// Feasibility floor for planned pane extents, per axis. Zero disables
    /// it (the pure-math and fuzz suites drive the walk with synthetic
    /// metrics and no renderer behind them); production metrics carry
    /// ``bonsplitMinimumPaneExtent``.
    public var minimumPaneExtent: CGFloat
    private let paneTitleRowPaneIDs: Set<Int>?

    /// The smallest outer extent bonsplit actually renders a pane at. The
    /// embedded configuration asks for a 1pt minimum, but the pane chrome's
    /// required AppKit constraints (the tab-bar controls) hold a ~32pt
    /// floor: imposing less parks the divider at the floor and the outcome
    /// never matches the target, so a smaller planned extent is permanently
    /// unappliable (observed live: plan=21x192 rendered at 32x192, and
    /// plan=13x381 at 32x380). bonsplit exposes no constant for this floor
    /// — it is emergent layout behavior, measured — so this is the one
    /// shared definition.
    public static let bonsplitMinimumPaneExtent: CGFloat = 32
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

    /// The grid a pane's outer point size renders to, in the shipping
    /// surface's own arithmetic: the portal floors points→pixels exactly like
    /// `TerminalSurface.pixelDimension`, and ghostty floors the padded pixel
    /// budget to whole cells. Both steps FLOOR — rounding would credit a cell
    /// the surface cannot paint (a scaled size landing in [B−0.5, B) would
    /// pass a rounded model while wrapping on the real surface). This is the
    /// ONE source for points→cells: the sizing tests and the DEBUG
    /// chrome-parity check both call it, so the two cannot drift.
    public static func renderedCells(
        outer: CGSize,
        tabBarHeight: CGFloat,
        scale: CGFloat,
        surfacePadPx: (width: Int, height: Int),
        cellPx: (width: Int, height: Int)
    ) -> (columns: Int, rows: Int) {
        let widthPx = Int((outer.width * scale).rounded(.down))
        let surfaceHeightPx = Int(
            ((outer.height - tabBarHeight) * scale).rounded(.down)
        )
        return (
            columns: (widthPx - surfacePadPx.width) / cellPx.width,
            rows: (surfaceHeightPx - surfacePadPx.height) / cellPx.height
        )
    }

    /// Creates the point-space metrics used by the remote-tmux layout planner.
    ///
    /// - Parameters:
    ///   - cellSize: One terminal cell's native point size.
    ///   - surfacePadding: Native surface chrome outside the rendered grid.
    ///   - tabBarHeight: Native tab-strip height carried by every pane.
    ///   - dividerThickness: Native split divider thickness.
    ///   - paneTitleRowHeight: Height of tmux's configured pane status row.
    ///   - minimumPaneExtent: Smallest pane extent the renderer will apply,
    ///     per axis. Zero (the default) disables the floor for synthetic
    ///     metrics; production metrics pass ``bonsplitMinimumPaneExtent``.
    ///   - paneTitleRowPaneIDs: Panes touching the configured status-row edge.
    ///     Pass `nil` only when the full patched layout will be supplied to each operation.
    public init(
        cellSize: CGSize,
        surfacePadding: CGSize,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat,
        paneTitleRowHeight: CGFloat = 0,
        minimumPaneExtent: CGFloat = 0,
        paneTitleRowPaneIDs: Set<Int>? = nil
    ) {
        self.cellSize = cellSize
        self.surfacePadding = surfacePadding
        self.tabBarHeight = tabBarHeight
        self.dividerThickness = dividerThickness
        self.paneTitleRowHeight = paneTitleRowHeight
        self.minimumPaneExtent = minimumPaneExtent
        self.paneTitleRowPaneIDs = paneTitleRowPaneIDs
    }

    /// The point size at which a tree renders a `columns`×`rows` grid with
    /// zero leftover: the grid at this cell size plus `layout`'s residual
    /// chrome. The render frame and the exact-fit tests both size regions
    /// with this, so neither can drift from ``residual(of:)``.
    public func exactFitSize(
        columns: Int,
        rows: Int,
        layout: RemoteTmuxLayoutNode
    ) -> CGSize {
        let residual = residual(of: layout)
        return CGSize(
            width: CGFloat(columns) * cellSize.width + residual.width,
            height: CGFloat(rows) * cellSize.height + residual.height
        )
    }

    public func clientGrid(
        layout: RemoteTmuxLayoutNode,
        contentSize: CGSize
    ) -> (columns: Int, rows: Int)? {
        guard contentSize.width > 1, contentSize.height > 1,
              cellSize.width > 1, cellSize.height > 1 else { return nil }
        // The claim charges real chrome AND the per-pane rail slack. The
        // slack is not chrome — nothing paints it — but the native plan
        // places extents on the whole-point rail, and at a container exactly
        // at a slack-free claim boundary the rounded rails cannot give every
        // pane its cells: with fractional chrome, one side of some split
        // lands a device pixel under a cell boundary and the surface floors
        // it away (the tight-container fuzz measures exactly this). Claiming
        // one point per pane fewer cells keeps every claimed cell honestly
        // placeable; the cost is at most one column/row at boundary sizes.
        let overhead = claimResidual(of: layout)
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

    /// Chrome residual for the window-size CLAIM.
    ///
    /// ``residual(of:)`` reads the LIVE parent-minus-children gap, so it moves
    /// by a cell whenever tmux folds the pane-border title row in or out of a
    /// child span across a reflow. Feeding that into the claim makes the claim
    /// read its own effect: it resizes the window, tmux republishes the tree
    /// with the title row on the other side of the gap, and the next claim
    /// lands a row away — the window-size claim oscillates and never settles.
    ///
    /// This variant reserves chrome from the stable model instead: one native
    /// divider per STRUCTURAL boundary (`children.count - 1` per split), never
    /// the assigned gap, plus one title row at the configured window edge under
    /// `pane-border-status`. Every interior title row shares a border row that
    /// is already charged as a structural separator, so the single edge title
    /// is the whole reservation with no double count. The result depends only
    /// on the container, cell size, pane structure, and border-status setting —
    /// so the same window always yields the same claim, titled or not, and tmux
    /// converges instead of the claim chasing the reflow.
    func claimResidual(of node: RemoteTmuxLayoutNode) -> CGSize {
        let structural = residual(
            of: node,
            panePlacementSlack: Self.paneQuantizationSlack,
            paneTitleRowPaneIDs: resolvedPaneTitleRowPaneIDs(for: node),
            useStructuralGap: true
        )
        guard paneTitleRowHeight > 0,
              !resolvedPaneTitleRowPaneIDs(for: node).isEmpty else { return structural }
        return CGSize(
            width: structural.width,
            height: structural.height - paneTitleRowHeight
        )
    }

    private func residual(
        of node: RemoteTmuxLayoutNode,
        panePlacementSlack: CGFloat,
        paneTitleRowPaneIDs: Set<Int>,
        useStructuralGap: Bool = false
    ) -> CGSize {
        switch node.content {
        case .pane:
            // No per-pane title charge: tmux's title rows live in the tree's
            // COORDINATES (the gaps between siblings and the window-edge row),
            // and the fold below credits those actual gap cells directly. A
            // native charge here granted the pane points nothing native
            // renders — the surface floored them into a phantom grid row.
            return CGSize(
                width: surfacePadding.width + panePlacementSlack,
                height: tabBarHeight + surfacePadding.height + panePlacementSlack
            )
        case .horizontal(let children):
            let childResiduals = children.map {
                residual(
                    of: $0,
                    panePlacementSlack: panePlacementSlack,
                    paneTitleRowPaneIDs: paneTitleRowPaneIDs,
                    useStructuralGap: useStructuralGap
                )
            }
            return CGSize(
                width: childResiduals.reduce(0) { $0 + $1.width }
                    + separatorResidual(
                        parent: node,
                        children: children,
                        axis: .horizontal,
                        useStructuralGap: useStructuralGap
                    ),
                height: childResiduals.map(\.height).max() ?? 0
            )
        case .vertical(let children):
            let childResiduals = children.map {
                residual(
                    of: $0,
                    panePlacementSlack: panePlacementSlack,
                    paneTitleRowPaneIDs: paneTitleRowPaneIDs,
                    useStructuralGap: useStructuralGap
                )
            }
            return CGSize(
                width: childResiduals.map(\.width).max() ?? 0,
                height: childResiduals.reduce(0) { $0 + $1.height }
                    + separatorResidual(
                        parent: node,
                        children: children,
                        axis: .vertical,
                        useStructuralGap: useStructuralGap
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
            minimumPaneExtent: minimumPaneExtent,
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

    /// The narrowest extent the plan may grant `tree` along `orientation`
    /// and still be appliable: ``minimumPaneExtent`` per pane stacked on the
    /// axis, plus the native divider between same-axis siblings; a
    /// cross-axis split needs only its widest child. The divider charge is
    /// native — unlike the cell-domain gap fold, the renderer spends exactly
    /// one ``dividerThickness`` per same-axis boundary regardless of what
    /// tmux's assignment holds between the spans. Zero when the metrics
    /// carry no floor.
    func minimumImposableExtent(
        of tree: RemoteTmuxNativeMeasuredSplitTree,
        along orientation: RemoteTmuxSplitOrientation
    ) -> CGFloat {
        guard minimumPaneExtent > 0 else { return 0 }
        switch tree {
        case .atomic:
            return minimumPaneExtent
        case .split(_, _, _, let splitOrientation, let first, let second):
            let firstMinimum = minimumImposableExtent(of: first, along: orientation)
            let secondMinimum = minimumImposableExtent(of: second, along: orientation)
            guard splitOrientation == orientation else {
                return max(firstMinimum, secondMinimum)
            }
            return firstMinimum + secondMinimum + dividerThickness
        }
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

    /// Binary form of ``residual(of:)``'s fold, used by the measured tree.
    /// The two MUST apply the same gap rule: this fold feeds the plan's
    /// ideals and the drag-end cell conversion, while the n-ary fold feeds
    /// the claim and the render frame — a disagreement is misallocated by
    /// exactly its size. `gapCells` is the ACTUAL coordinate cells between
    /// (and around) the joined spans, read off the assignment.
    func joinedResidual(
        first: CGSize,
        second: CGSize,
        orientation: RemoteTmuxSplitOrientation,
        gapCells: Int = 1
    ) -> CGSize {
        if orientation == .horizontal {
            return CGSize(
                width: first.width + second.width + dividerThickness
                    - CGFloat(gapCells) * cellSize.width,
                height: max(first.height, second.height)
            )
        }
        return CGSize(
            width: max(first.width, second.width),
            height: first.height + second.height + dividerThickness
                - CGFloat(gapCells) * cellSize.height
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

    /// Native points a split spends on the chrome BETWEEN and AROUND its
    /// children along the split axis: one native divider per boundary, minus
    /// the ACTUAL coordinate cells the assignment holds outside the children
    /// (separator columns/rows, or the title rows that replace them, plus a
    /// window-edge title row when one is inside this node's span). Reading
    /// the gaps off the assigned spans — parent minus children — makes a
    /// node's extent equal its children's sum by construction, titled or
    /// not; assuming one cell per boundary charged titled trees for rows
    /// they spend elsewhere. Degenerate spans (structure-only placeholders)
    /// fall back to the one-cell-per-boundary reading.
    private func separatorResidual(
        parent: RemoteTmuxLayoutNode,
        children: [RemoteTmuxLayoutNode],
        axis: RemoteTmuxSplitOrientation,
        useStructuralGap: Bool = false
    ) -> CGFloat {
        let boundaries = max(0, children.count - 1)
        // The claim reserves the STRUCTURAL separator count — one gap cell per
        // boundary — never the assigned gap. tmux draws the interior title rows
        // on those same separator rows (no double count), and the single
        // window-edge title is charged once by ``claimResidual(of:)``. Reading
        // `parentSpan - childSpans` here instead would let the claim move by a
        // cell as tmux folds the title row in and out of a child span.
        let gapCells = useStructuralGap
            ? boundaries
            : Self.assignedGapCells(
                parentSpan: axis == .horizontal ? parent.width : parent.height,
                childSpans: children.map { axis == .horizontal ? $0.width : $0.height },
                fallback: boundaries
            )
        let cell = axis == .horizontal ? cellSize.width : cellSize.height
        return CGFloat(boundaries) * dividerThickness - CGFloat(gapCells) * cell
    }

    /// The coordinate cells a split's assignment holds OUTSIDE its children
    /// along the split axis — parent span minus child spans: separator
    /// columns/rows, or the title rows that replace them, plus a window-edge
    /// title row inside the parent's span. Degenerate spans (structure-only
    /// placeholders, or a parent briefly narrower than its children
    /// mid-reconcile) make the subtraction meaningless, so each call site
    /// supplies its own fallback for that case: the n-ary residual fold reads
    /// one cell per boundary, the binary fold reads one cell, and the
    /// minimum-span walk keeps the clamped raw gap.
    static func assignedGapCells(
        parentSpan: Int,
        childSpans: [Int],
        fallback: @autoclosure () -> Int
    ) -> Int {
        let childSpanSum = childSpans.reduce(0, +)
        let spansUsable = parentSpan > 0
            && !childSpans.isEmpty
            && childSpans.allSatisfy { $0 > 0 }
            && parentSpan >= childSpanSum
        return spansUsable ? parentSpan - childSpanSum : fallback()
    }
}
