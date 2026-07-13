public import Bonsplit
public import Foundation

/// Binary tmux tree with native chrome residuals folded once for a geometry snapshot.
public indirect enum RemoteTmuxNativeMeasuredSplitTree: Sendable {
    case atomic(layout: RemoteTmuxLayoutNode, residual: CGSize)
    case split(
        layout: RemoteTmuxLayoutNode,
        residual: CGSize,
        orientation: SplitOrientation,
        first: RemoteTmuxNativeMeasuredSplitTree,
        second: RemoteTmuxNativeMeasuredSplitTree
    )

    public init(tree: RemoteTmuxNativeSplitTree, metrics: RemoteTmuxNativeLayoutMetrics) {
        switch tree {
        case .atomic(let layout):
            self = .atomic(layout: layout, residual: metrics.residual(of: layout))
        case .split(let layout, let orientation, let first, let second):
            let measuredFirst = Self(tree: first, metrics: metrics)
            let measuredSecond = Self(tree: second, metrics: metrics)
            self = .split(
                layout: layout,
                residual: metrics.joinedResidual(
                    first: measuredFirst.residual,
                    second: measuredSecond.residual,
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
        case .atomic(let layout, _), .split(let layout, _, _, _, _):
            return layout
        }
    }

    public var residual: CGSize {
        switch self {
        case .atomic(_, let residual), .split(_, let residual, _, _, _):
            return residual
        }
    }
}
