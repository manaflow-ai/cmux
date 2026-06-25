public import Bonsplit
import CoreGraphics
import Foundation

/// Pure split-tree geometry over Bonsplit's external snapshot: equalize and
/// resize planning, lifted one-for-one from the app-side `SplitEqualizer`
/// and `TabManager.resizeSplit` math. Plans are computed from the snapshot
/// only; ``PaneLayoutService`` applies them to a `BonsplitController` in the
/// same order the legacy code issued its divider mutations.
extension ExternalTreeNode {
    /// Plans an equalize pass: every split matching `orientationFilter`
    /// (or every split when `nil`) gets its divider set so that each
    /// same-orientation leaf span receives equal space.
    public func equalizeDividerPlan(orientationFilter: String? = nil) -> SplitEqualizePlan {
        var adjustments: [SplitDividerAdjustment] = []
        var foundSplit = false
        var hadInvalidSplitIds = false
        appendEqualizeAdjustments(
            orientationFilter: orientationFilter,
            adjustments: &adjustments,
            foundSplit: &foundSplit,
            hadInvalidSplitIds: &hadInvalidSplitIds
        )
        return SplitEqualizePlan(
            adjustments: adjustments,
            foundSplit: foundSplit,
            hadInvalidSplitIds: hadInvalidSplitIds
        )
    }

    private func appendEqualizeAdjustments(
        orientationFilter: String?,
        adjustments: inout [SplitDividerAdjustment],
        foundSplit: inout Bool,
        hadInvalidSplitIds: inout Bool
    ) {
        switch self {
        case .pane:
            return
        case .split(let splitNode):
            splitNode.first.appendEqualizeAdjustments(
                orientationFilter: orientationFilter,
                adjustments: &adjustments,
                foundSplit: &foundSplit,
                hadInvalidSplitIds: &hadInvalidSplitIds
            )
            splitNode.second.appendEqualizeAdjustments(
                orientationFilter: orientationFilter,
                adjustments: &adjustments,
                foundSplit: &foundSplit,
                hadInvalidSplitIds: &hadInvalidSplitIds
            )

            if orientationFilter == nil || splitNode.orientation == orientationFilter {
                foundSplit = true
                if let splitId = UUID(uuidString: splitNode.id) {
                    let firstSpanCount = splitNode.first.spanCount(along: splitNode.orientation)
                    let secondSpanCount = splitNode.second.spanCount(along: splitNode.orientation)
                    let totalSpanCount = firstSpanCount + secondSpanCount
                    let position = CGFloat(firstSpanCount) / CGFloat(totalSpanCount)
                    adjustments.append(SplitDividerAdjustment(splitId: splitId, position: position))
                } else {
                    hadInvalidSplitIds = true
                }
            }
        }
    }

    private func spanCount(along orientation: String) -> Int {
        switch self {
        case .pane:
            return 1
        case .split(let splitNode):
            guard splitNode.orientation == orientation else {
                return 1
            }
            let firstSpanCount = splitNode.first.spanCount(along: orientation)
            let secondSpanCount = splitNode.second.spanCount(along: orientation)
            return firstSpanCount + secondSpanCount
        }
    }

    /// Plans a keyboard resize of the pane's controlling divider: walks the
    /// tree for the splits enclosing `targetPaneId` (innermost first, the
    /// legacy candidate order), picks the first split matching the resize
    /// direction's orientation and child side, and converts `amountPixels`
    /// into a divider delta along that split's axis, clamped to 0.1-0.9.
    /// Returns `nil` when the pane is absent or no enclosing split matches.
    public func resizeDividerAdjustment(
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16
    ) -> SplitDividerAdjustment? {
        switch relativeResizeDividerPlan(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: CGFloat(amountPixels)
        ) {
        case .planned(let plan):
            return SplitDividerAdjustment(splitId: plan.splitId, position: plan.newPosition)
        case .paneNotFound, .noOrientationSplitAncestor, .noAdjacentBorder:
            return nil
        }
    }

    /// Plans a relative resize of the pane's controlling divider, walking the
    /// splits enclosing `targetPaneId` (innermost first), picking the first
    /// split matching `direction`'s orientation and child side, converting
    /// `amountPixels` into a divider delta along that split's axis, and clamping
    /// to 0.1-0.9. Distinguishes the legacy failure reasons (pane absent from
    /// the tree, no enclosing split matching the resize axis, or no split with
    /// the target on the controlling child side). The byte-faithful home of the
    /// candidate walk + delta/clamp math that the app-side `pane.resize`
    /// relative path previously duplicated; ``resizeDividerAdjustment`` is the
    /// position-only view of `.planned`, and the relative resize resolution maps
    /// the failure cases directly.
    public func relativeResizeDividerPlan(
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: CGFloat
    ) -> RelativeResizeDividerPlan {
        var candidates: [ResizeSplitCandidate] = []
        let trace = collectResizeCandidates(targetPaneId: targetPaneId, candidates: &candidates)
        guard trace.containsTarget else { return .paneNotFound }

        let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
        guard !orientationMatches.isEmpty else { return .noOrientationSplitAncestor }

        guard let candidate = orientationMatches.first(where: {
            $0.paneInFirstChild == direction.requiresPaneInFirstChild
        }) else {
            return .noAdjacentBorder
        }

        let delta = amountPixels / candidate.axisPixels
        let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
        let clamped = min(max(requested, 0.1), 0.9)
        return .planned(SplitResizeDividerPlan(
            splitId: candidate.splitId,
            oldPosition: candidate.dividerPosition,
            newPosition: clamped
        ))
    }

    /// Plans an absolute resize that drives the pane's controlling divider so
    /// the pane spans `targetPixels` along `axis` ("horizontal"/"vertical").
    /// Walks the same candidate set as the relative path, picks the first split
    /// matching the axis, converts the target span into a divider fraction
    /// (inverted when the pane is the second child), and clamps to 0.1-0.9.
    /// Returns `nil` for a non-positive target, an unrecognized axis, the pane
    /// being absent, or no enclosing split matching the axis. The byte-faithful
    /// home of the app-side `v2SetAbsolutePaneSize` divider math.
    public func absoluteSizeDividerAdjustment(
        targetPaneId: String,
        axis: String,
        targetPixels: CGFloat
    ) -> SplitResizeDividerPlan? {
        guard targetPixels > 0 else { return nil }
        let orientationName: String
        switch axis.lowercased() {
        case "horizontal":
            orientationName = "horizontal"
        case "vertical":
            orientationName = "vertical"
        default:
            return nil
        }

        var candidates: [ResizeSplitCandidate] = []
        let trace = collectResizeCandidates(targetPaneId: targetPaneId, candidates: &candidates)
        guard trace.containsTarget,
              let candidate = candidates.first(where: { $0.orientation == orientationName }) else {
            return nil
        }

        let targetFraction = targetPixels / candidate.axisPixels
        let requested = candidate.paneInFirstChild ? targetFraction : (1 - targetFraction)
        let clamped = min(max(requested, 0.1), 0.9)
        return SplitResizeDividerPlan(
            splitId: candidate.splitId,
            oldPosition: candidate.dividerPosition,
            newPosition: clamped
        )
    }

    private struct ResizeSplitCandidate {
        let splitId: UUID
        let orientation: String
        let paneInFirstChild: Bool
        let dividerPosition: CGFloat
        let axisPixels: CGFloat
    }

    private struct ResizeSplitTrace {
        let containsTarget: Bool
        let bounds: CGRect
    }

    private func collectResizeCandidates(
        targetPaneId: String,
        candidates: inout [ResizeSplitCandidate]
    ) -> ResizeSplitTrace {
        switch self {
        case .pane(let pane):
            let bounds = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            return ResizeSplitTrace(containsTarget: pane.id == targetPaneId, bounds: bounds)

        case .split(let split):
            let first = split.first.collectResizeCandidates(
                targetPaneId: targetPaneId,
                candidates: &candidates
            )
            let second = split.second.collectResizeCandidates(
                targetPaneId: targetPaneId,
                candidates: &candidates
            )

            let combinedBounds = first.bounds.union(second.bounds)
            let containsTarget = first.containsTarget || second.containsTarget

            if containsTarget,
               let splitUUID = UUID(uuidString: split.id) {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(ResizeSplitCandidate(
                    splitId: splitUUID,
                    orientation: orientation,
                    paneInFirstChild: first.containsTarget,
                    dividerPosition: CGFloat(split.dividerPosition),
                    axisPixels: max(axisPixels, 1)
                ))
            }

            return ResizeSplitTrace(containsTarget: containsTarget, bounds: combinedBounds)
        }
    }
}
