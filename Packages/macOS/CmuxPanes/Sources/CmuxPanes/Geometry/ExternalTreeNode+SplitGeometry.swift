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
        var candidates: [ResizeSplitCandidate] = []
        let trace = collectResizeCandidates(targetPaneId: targetPaneId, candidates: &candidates)
        guard trace.containsTarget else { return nil }

        let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
        guard !orientationMatches.isEmpty else { return nil }

        guard let candidate = orientationMatches.first(where: {
            $0.paneInFirstChild == direction.requiresPaneInFirstChild
        }) else {
            return nil
        }

        let delta = CGFloat(amountPixels) / candidate.axisPixels
        let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
        let clamped = min(max(requested, 0.1), 0.9)
        return SplitDividerAdjustment(splitId: candidate.splitId, position: clamped)
    }

    /// Walks the split subtree rooted at `self`, appending one
    /// ``ResizeSplitCandidate`` for every split that encloses the pane named
    /// `targetPaneId` (innermost first), and returns a ``ResizeSplitTrace``
    /// reporting whether the target was found plus the subtree's combined
    /// bounds. The pure tree-walk underlying both relative and absolute pane
    /// resizes; it reads only the Bonsplit snapshot and never mutates state.
    public func collectResizeCandidates(
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
