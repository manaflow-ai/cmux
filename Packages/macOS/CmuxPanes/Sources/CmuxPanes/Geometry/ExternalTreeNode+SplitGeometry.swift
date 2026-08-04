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
    /// tree for the splits enclosing `targetPaneId` (innermost first), prefers
    /// the nearest split matching the requested edge, and falls back to the
    /// nearest compatible opposite edge at an outer boundary. Converts
    /// `amountPixels` into a divider delta along that split's axis, clamped to
    /// 0.1-0.9. Returns `nil` when the pane is absent, no enclosing split
    /// matches the direction's orientation, or the selected split cannot be
    /// addressed reliably.
    public func resizeDividerAdjustment(
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16
    ) -> SplitDividerAdjustment? {
        guard case .adjustment(let adjustment) = resizeDividerPlan(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels
        ) else {
            return nil
        }
        return adjustment
    }

    /// Produces a resize plan while retaining failures that the public
    /// optional adjustment API cannot represent.
    func resizeDividerPlan(
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16
    ) -> SplitResizePlan {
        var candidates: [ResizeSplitCandidate] = []
        let trace = collectResizeCandidates(targetPaneId: targetPaneId, candidates: &candidates)
        guard trace.containsTarget else { return .noMatchingSplit }

        let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
        guard !orientationMatches.isEmpty else { return .noMatchingSplit }

        let directCandidate = orientationMatches.first {
            $0.paneInFirstChild == direction.requiresPaneInFirstChild
        }
        let candidate = directCandidate ?? orientationMatches[0]
        guard let splitId = candidate.splitId else {
            return .invalidSplitIdentifier
        }
        let sign = directCandidate == nil
            ? -direction.dividerDeltaSign
            : direction.dividerDeltaSign

        let delta = CGFloat(amountPixels) / candidate.axisPixels
        let requested = candidate.dividerPosition + (sign * delta)
        let clamped = min(max(requested, 0.1), 0.9)
        let requestedShare = candidate.paneInFirstChild ? requested : 1 - requested
        let actualShare = candidate.paneInFirstChild ? clamped : 1 - clamped
        let initialShare = candidate.paneInFirstChild
            ? candidate.dividerPosition
            : 1 - candidate.dividerPosition
        return .adjustment(SplitDividerAdjustment(
            splitId: splitId,
            position: clamped,
            requestedFocusedBranchShare: requestedShare,
            focusedBranchShare: actualShare,
            initialFocusedBranchShare: initialShare,
            focusedBranchIsFirst: candidate.paneInFirstChild
        ))
    }

    /// Plans an exact share for the focused branch at the nearest enclosing
    /// split on `axis`.
    func focusedBranchShareDividerPlan(
        targetPaneId: String,
        axis: PaneAxis,
        share: CGFloat
    ) -> SplitResizePlan {
        var candidates: [ResizeSplitCandidate] = []
        let trace = collectResizeCandidates(targetPaneId: targetPaneId, candidates: &candidates)
        guard trace.containsTarget,
              let candidate = candidates.first(where: { $0.orientation == axis.splitOrientation }) else {
            return .noMatchingSplit
        }
        guard let splitId = candidate.splitId else {
            return .invalidSplitIdentifier
        }

        let clampedShare = min(max(share, 0.1), 0.9)
        let dividerPosition = candidate.paneInFirstChild ? clampedShare : 1 - clampedShare
        let initialShare = candidate.paneInFirstChild
            ? candidate.dividerPosition
            : 1 - candidate.dividerPosition
        return .adjustment(SplitDividerAdjustment(
            splitId: splitId,
            position: dividerPosition,
            requestedFocusedBranchShare: share,
            focusedBranchShare: clampedShare,
            initialFocusedBranchShare: initialShare,
            focusedBranchIsFirst: candidate.paneInFirstChild
        ))
    }

    func dividerPosition(forSplitId splitId: UUID) -> CGFloat? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == splitId.uuidString {
                return split.dividerPosition
            }
            return split.first.dividerPosition(forSplitId: splitId)
                ?? split.second.dividerPosition(forSplitId: splitId)
        }
    }

    private struct ResizeSplitCandidate {
        let splitId: UUID?
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

            if containsTarget {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(ResizeSplitCandidate(
                    splitId: UUID(uuidString: split.id),
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

/// Internal resize planning result used to distinguish absent geometry from
/// an enclosing split whose identifier cannot be routed to Bonsplit safely.
enum SplitResizePlan: Equatable {
    case adjustment(SplitDividerAdjustment)
    case noMatchingSplit
    case invalidSplitIdentifier
}
