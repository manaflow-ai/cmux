import Bonsplit
import Foundation

/// The pure sizing walk behind the mirror's divider imposition: given a
/// measured tmux split tree, the native metrics, and the container's actual
/// size, decide every split's divider fraction and every pane's resulting
/// outer size, mirroring the native split view's whole-point division.
///
/// Extracted from the mirror so the whole pipeline — claim, ideals,
/// fractions, per-level rounding — is testable without views: the fuzz
/// drives random trees and containers through this exact walk and checks
/// every pane still derives its assigned tmux span.
enum RemoteTmuxNativeSplitLayout {
    /// One node of the computed plan, shaped like the measured tree it was
    /// derived from. Fractions apply to splits in the same positions.
    indirect enum Plan {
        case leaf(paneId: Int?, outer: CGSize?)
        case split(orientation: SplitOrientation, fraction: CGFloat, first: Plan, second: Plan)
    }

    /// Computes the divider plan: each split's fraction divides the actual
    /// extent proportionally between the two subtrees' ideal extents, and
    /// the walk models the native split view's whole-point division to
    /// derive the outer size every pane will receive.
    static func plan(
        tree: RemoteTmuxNativeMeasuredSplitTree,
        metrics: RemoteTmuxNativeLayoutMetrics,
        parentSize: CGSize?
    ) -> Plan {
        switch tree {
        case .atomic(let layout, _):
            var paneId: Int?
            if case .pane(let id) = layout.content { paneId = id }
            return .leaf(paneId: paneId, outer: parentSize)
        case .split(_, _, let orientation, let firstTree, let secondTree):
            let fraction = metrics.dividerFraction(
                first: firstTree,
                second: secondTree,
                orientation: orientation
            )
            var firstSize: CGSize?
            var secondSize: CGSize?
            if let parentSize {
                let parentExtent = orientation == .horizontal
                    ? parentSize.width
                    : parentSize.height
                let available = max(0, parentExtent - metrics.dividerThickness)
                let firstExtent = (available * fraction).rounded()
                let secondExtent = max(0, available - firstExtent)
                if orientation == .horizontal {
                    firstSize = CGSize(width: firstExtent, height: parentSize.height)
                    secondSize = CGSize(width: secondExtent, height: parentSize.height)
                } else {
                    firstSize = CGSize(width: parentSize.width, height: firstExtent)
                    secondSize = CGSize(width: parentSize.width, height: secondExtent)
                }
            }
            return .split(
                orientation: orientation,
                fraction: fraction,
                first: plan(tree: firstTree, metrics: metrics, parentSize: firstSize),
                second: plan(tree: secondTree, metrics: metrics, parentSize: secondSize)
            )
        }
    }

    /// Flattens a plan's leaves into pane-id → outer size (panes whose size
    /// the plan could not model are absent).
    static func outerSizes(of plan: Plan) -> [Int: CGSize] {
        var sizes: [Int: CGSize] = [:]
        collectOuterSizes(plan, into: &sizes)
        return sizes
    }

    private static func collectOuterSizes(_ plan: Plan, into sizes: inout [Int: CGSize]) {
        switch plan {
        case .leaf(let paneId, let outer):
            if let paneId, let outer { sizes[paneId] = outer }
        case .split(_, _, let first, let second):
            collectOuterSizes(first, into: &sizes)
            collectOuterSizes(second, into: &sizes)
        }
    }
}
