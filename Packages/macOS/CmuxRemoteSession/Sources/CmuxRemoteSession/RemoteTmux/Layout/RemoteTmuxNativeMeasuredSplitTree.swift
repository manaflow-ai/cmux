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
            self = .split(
                layout: layout,
                residual: metrics.joinedResidual(
                    first: measuredFirst.residual,
                    second: measuredSecond.residual,
                    orientation: orientation
                ),
                minimumResidual: metrics.joinedResidual(
                    first: measuredFirst.minimumResidual,
                    second: measuredSecond.minimumResidual,
                    orientation: orientation
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
}
