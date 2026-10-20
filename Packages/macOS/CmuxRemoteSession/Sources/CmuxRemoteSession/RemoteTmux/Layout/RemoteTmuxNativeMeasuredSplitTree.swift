public import Foundation

/// Binary tmux tree with preferred and minimum native residuals folded once per snapshot.
public indirect enum RemoteTmuxNativeMeasuredSplitTree: Sendable {
    case atomic(layout: RemoteTmuxLayoutNode, residual: CGSize, minimumResidual: CGSize)
    case split(
        layout: RemoteTmuxLayoutNode,
        residual: CGSize,
        minimumResidual: CGSize,
        orientation: RemoteTmuxSplitOrientation,
        first: RemoteTmuxNativeMeasuredSplitTree,
        second: RemoteTmuxNativeMeasuredSplitTree
    )

    public init(tree: RemoteTmuxNativeSplitTree, metrics: RemoteTmuxNativeLayoutMetrics) {
        self.init(
            resolvedTree: tree,
            metrics: metrics.resolvingPaneTitleRows(in: tree.layout)
        )
    }

    private init(
        resolvedTree tree: RemoteTmuxNativeSplitTree,
        metrics: RemoteTmuxNativeLayoutMetrics
    ) {
        switch tree {
        case .atomic(let layout):
            self = .atomic(
                layout: layout,
                residual: metrics.residual(of: layout),
                minimumResidual: metrics.minimumResidual(of: layout)
            )
        case .split(let layout, let orientation, let first, let second):
            let measuredFirst = Self(resolvedTree: first, metrics: metrics)
            let measuredSecond = Self(resolvedTree: second, metrics: metrics)
            // The actual coordinate cells between (and around) the two
            // subtrees — separator columns/rows, title rows, a window-edge
            // title row — read off the assignment so this binary fold agrees
            // with the n-ary residual fold node for node.
            let gapCells = RemoteTmuxNativeLayoutMetrics.assignedGapCells(
                parentSpan: layout.assignedSpan(along: orientation),
                childSpans: [
                    measuredFirst.layout.assignedSpan(along: orientation),
                    measuredSecond.layout.assignedSpan(along: orientation),
                ],
                fallback: 1
            )
            self = .split(
                layout: layout,
                residual: metrics.joinedResidual(
                    first: measuredFirst.residual,
                    second: measuredSecond.residual,
                    orientation: orientation,
                    gapCells: gapCells
                ),
                minimumResidual: metrics.joinedResidual(
                    first: measuredFirst.minimumResidual,
                    second: measuredSecond.minimumResidual,
                    orientation: orientation,
                    gapCells: gapCells
                ),
                orientation: orientation,
                first: measuredFirst,
                second: measuredSecond
            )
        }
    }

    public var layout: RemoteTmuxLayoutNode {
        switch self {
        case .atomic(let layout, _, _), .split(let layout, _, _, _, _, _):
            return layout
        }
    }

    public var residual: CGSize {
        switch self {
        case .atomic(_, let residual, _), .split(_, let residual, _, _, _, _):
            return residual
        }
    }

    /// Chrome-only residual that preserves assigned cells without placement slack.
    var minimumResidual: CGSize {
        switch self {
        case .atomic(_, _, let residual), .split(_, _, let residual, _, _, _):
            return residual
        }
    }

    /// The fewest cells tmux can leave this subtree along `orientation`:
    /// one cell per pane stacked on the axis, plus the chrome cells the
    /// current assignment holds between them (a separator column, or the
    /// title rows that replace separators). The chrome is read off the
    /// assigned spans — parent minus children — so this never re-derives
    /// tmux's border accounting; whatever the current layout spends on a
    /// gap stays spent when the panes shrink around it.
    public func minimumSpan(along orientation: RemoteTmuxSplitOrientation) -> Int {
        switch self {
        case .atomic:
            return 1
        case .split(let layout, _, _, let splitOrientation, let first, let second):
            let firstMinimum = first.minimumSpan(along: orientation)
            let secondMinimum = second.minimumSpan(along: orientation)
            guard splitOrientation == orientation else {
                return max(firstMinimum, secondMinimum)
            }
            let parentSpan = layout.assignedSpan(along: orientation)
            let childSpans = [
                first.layout.assignedSpan(along: orientation),
                second.layout.assignedSpan(along: orientation),
            ]
            let gap = RemoteTmuxNativeLayoutMetrics.assignedGapCells(
                parentSpan: parentSpan,
                childSpans: childSpans,
                fallback: max(0, parentSpan - childSpans.reduce(0, +))
            )
            return firstMinimum + secondMinimum + gap
        }
    }

    /// Clamps a requested first-subtree span to what tmux can actually
    /// assign in this split: the two subtrees trade cells across a fixed
    /// gap, so the first can grow at most to their combined span minus the
    /// least the second can shrink to, and can shrink to its own minimum.
    /// A resize-pane outside this range changes no layout, and a command
    /// that changes nothing gets no layout reply — the caller must treat a
    /// request that clamps back to the assigned span as "nothing to send".
    public static func clampToFeasibleFirstSpan(
        _ requested: Int,
        first: RemoteTmuxNativeMeasuredSplitTree,
        second: RemoteTmuxNativeMeasuredSplitTree,
        orientation: RemoteTmuxSplitOrientation
    ) -> Int {
        let combined = first.layout.assignedSpan(along: orientation)
            + second.layout.assignedSpan(along: orientation)
        let lower = first.minimumSpan(along: orientation)
        let upper = combined - second.minimumSpan(along: orientation)
        guard lower <= upper else {
            return first.layout.assignedSpan(along: orientation)
        }
        return min(max(requested, lower), upper)
    }
}

private extension RemoteTmuxLayoutNode {
    func assignedSpan(along orientation: RemoteTmuxSplitOrientation) -> Int {
        orientation == .horizontal ? width : height
    }
}
