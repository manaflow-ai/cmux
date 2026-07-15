public import Foundation

/// The pure sizing walk behind the mirror's divider imposition: given a
/// measured tmux split tree, the native metrics, and the container's actual
/// size, decide every split's divider fraction and every pane's resulting
/// outer size, mirroring the native split view's whole-point division.
///
/// Extracted from the mirror so the whole pipeline — claim, ideals, rail
/// allocation, per-level rounding — is testable without views: the fuzz
/// drives random trees and containers through this exact walk and checks
/// every pane still derives its assigned tmux span.
public struct RemoteTmuxNativeSplitLayoutPlanner: Sendable {
    /// Metrics applied by every plan this value computes.
    public let metrics: RemoteTmuxNativeLayoutMetrics

    /// Creates a planner for one measured terminal geometry profile.
    public init(metrics: RemoteTmuxNativeLayoutMetrics) {
        self.metrics = metrics
    }
    /// One node of the computed plan, shaped like the measured tree it was
    /// derived from. `firstExtent` is the exact point extent to IMPOSE on
    /// the split's first child; `fraction` is the equivalent normalized
    /// value, kept for the paths that cannot impose (no container measured
    /// yet — `firstExtent` nil — and readers that think in ratios).
    public indirect enum Plan: Sendable {
        case leaf(paneId: Int?, outer: CGSize?)
        case split(
            orientation: RemoteTmuxSplitOrientation,
            fraction: CGFloat,
            firstExtent: CGFloat?,
            first: Plan,
            second: Plan
        )
    }

    /// Computes the divider plan by rounding ABSOLUTE split boundaries, not
    /// per-split extents. Each carry is the rounding error of a region's
    /// leading edge along one axis — exact position minus rounded position —
    /// and `round(ideal + carry)` is exactly "round the boundary's absolute
    /// coordinate, measured from that edge". Both children inherit their
    /// region's edge errors: the first child shares the parent's leading
    /// edge, the trailing child starts at the freshly rounded boundary, and
    /// a cross-axis split moves neither child's edges along the other axis,
    /// so carries pass through it unchanged. Every boundary then lands
    /// within half a point of its exact position no matter how deep the
    /// tree is, and every pane within one point of its ideal — the bound
    /// the per-pane quantization slack covers. (Rounding per split with
    /// carries that reset at each level re-anchors the error at every
    /// nesting depth, and a leaf under k same-axis levels could fall half
    /// a point short per level — one lost column at depth two.)
    ///
    /// Placement slack is preferred but optional: when both preferred ideals
    /// do not fit, the walk preserves the chrome-only minimums that carry the
    /// assigned cells. Only a region too small for those minimums degrades.
    /// Without a parent size (no container measured yet, or a degenerate
    /// extent mid-collapse), fractions fall back to the proportional
    /// ideal-over-ideal split and sizes stop being modeled below that
    /// point.
    public func plan(
        tree: RemoteTmuxNativeMeasuredSplitTree,
        parentSize: CGSize?,
        horizontalCarry: CGFloat = 0,
        verticalCarry: CGFloat = 0
    ) -> Plan {
        switch tree {
        case .atomic(let layout, _, _):
            var paneId: Int?
            if case .pane(let id) = layout.content { paneId = id }
            return .leaf(paneId: paneId, outer: parentSize)
        case .split(_, _, _, let orientation, let firstTree, let secondTree):
            let axisCarry = orientation == .horizontal ? horizontalCarry : verticalCarry
            var fraction: CGFloat?
            var firstSize: CGSize?
            var secondSize: CGSize?
            var secondCarry: CGFloat = 0
            if let parentSize {
                let parentExtent = orientation == .horizontal
                    ? parentSize.width
                    : parentSize.height
                let available = parentExtent - metrics.dividerThickness
                if let allocation = metrics.railAllocation(
                    firstIdeal: metrics.idealExtent(of: firstTree, along: orientation),
                    secondIdeal: metrics.idealExtent(of: secondTree, along: orientation),
                    firstMinimum: metrics.minimumIdealExtent(
                        of: firstTree, along: orientation
                    ),
                    secondMinimum: metrics.minimumIdealExtent(
                        of: secondTree, along: orientation
                    ),
                    carry: axisCarry,
                    available: available
                ) {
                    fraction = allocation.firstExtent / available
                    secondCarry = allocation.secondCarry
                    let sizes = metrics.childSizes(
                        parentSize: parentSize,
                        orientation: orientation,
                        firstExtent: allocation.firstExtent
                    )
                    firstSize = sizes.first
                    secondSize = sizes.second
                }
            }
            let applied = fraction ?? metrics.dividerFraction(
                first: firstTree,
                second: secondTree,
                orientation: orientation
            )
            return .split(
                orientation: orientation,
                fraction: applied,
                firstExtent: fraction != nil ? firstSize.map {
                    orientation == .horizontal ? $0.width : $0.height
                } : nil,
                first: plan(
                    tree: firstTree,
                    parentSize: firstSize,
                    horizontalCarry: horizontalCarry,
                    verticalCarry: verticalCarry
                ),
                second: plan(
                    tree: secondTree,
                    parentSize: secondSize,
                    horizontalCarry: orientation == .horizontal ? secondCarry : horizontalCarry,
                    verticalCarry: orientation == .vertical ? secondCarry : verticalCarry
                )
            )
        }
    }

    /// Flattens a plan's leaves into pane-id → outer size (panes whose size
    /// the plan could not model are absent).
    public func outerSizes(of plan: Plan) -> [Int: CGSize] {
        switch plan {
        case .leaf(let paneId, let outer):
            guard let paneId, let outer else { return [:] }
            return [paneId: outer]
        case .split(_, _, _, let first, let second):
            return outerSizes(of: first).merging(outerSizes(of: second)) { first, _ in first }
        }
    }
}
