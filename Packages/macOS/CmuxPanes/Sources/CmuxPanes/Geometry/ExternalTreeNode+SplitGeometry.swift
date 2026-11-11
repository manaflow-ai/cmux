public import Bonsplit
import CoreGraphics
public import Foundation

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

    /// Plans an equalize pass over the run of same-orientation splits that
    /// directly contains `paneId`: the pane's parent split plus every
    /// ancestor reached without crossing a split of another orientation,
    /// and the same-orientation splits nested inside that run. Splits
    /// elsewhere in the tree, including same-orientation splits behind a
    /// cross-orientation subtree, are left alone. Returns an empty plan when
    /// `paneId` is absent or has no parent split.
    public func equalizeDividerPlan(forSplitRunContainingPaneId paneId: String) -> SplitEqualizePlan {
        equalizeDividerPlan(forSplitPath: splitPath(toPaneId: paneId))
    }

    private func equalizeDividerPlan(forSplitPath path: [ExternalSplitNode]?) -> SplitEqualizePlan {
        guard let path, let parent = path.last else {
            return SplitEqualizePlan(adjustments: [], foundSplit: false, hadInvalidSplitIds: false)
        }
        var runRoot = parent
        for ancestor in path.dropLast().reversed() {
            guard ancestor.orientation == parent.orientation else { break }
            runRoot = ancestor
        }
        var adjustments: [SplitDividerAdjustment] = []
        var foundSplit = false
        var hadInvalidSplitIds = false
        ExternalTreeNode.split(runRoot).appendRunEqualizeAdjustments(
            orientation: parent.orientation,
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

    /// Plans the same-axis run containing a divider identified by its split UUID.
    ///
    /// - Parameter splitId: The divider's split UUID in this snapshot.
    /// - Returns: An empty plan for a stale ID, otherwise the containing row or
    ///   column's divider adjustments, stopping at cross-axis boundaries.
    public func equalizeDividerPlan(forSplitRunContainingSplitId splitId: UUID) -> SplitEqualizePlan {
        equalizeDividerPlan(forSplitPath: splitPath(toSplitId: splitId))
    }

    private func splitPath(toSplitId splitId: UUID) -> [ExternalSplitNode]? {
        var path: [ExternalSplitNode] = []
        return appendSplitPath(toSplitId: splitId, path: &path) ? path : nil
    }

    private func appendSplitPath(toSplitId splitId: UUID, path: inout [ExternalSplitNode]) -> Bool {
        guard case .split(let node) = self else { return false }
        path.append(node)
        if UUID(uuidString: node.id) == splitId { return true }
        if node.first.appendSplitPath(toSplitId: splitId, path: &path)
            || node.second.appendSplitPath(toSplitId: splitId, path: &path) { return true }
        path.removeLast()
        return false
    }

    /// The splits from this node down to `paneId`'s parent, or `nil` when
    /// the pane is not in this subtree.
    private func splitPath(toPaneId paneId: String) -> [ExternalSplitNode]? {
        switch self {
        case .pane(let pane):
            return pane.id == paneId ? [] : nil
        case .split(let splitNode):
            guard let rest = splitNode.first.splitPath(toPaneId: paneId)
                ?? splitNode.second.splitPath(toPaneId: paneId) else { return nil }
            return [splitNode] + rest
        }
    }

    /// Post-order equalize over a same-orientation run: recurses only into
    /// children that continue the run, and returns this subtree's spans so
    /// each node is counted once.
    @discardableResult
    private func appendRunEqualizeAdjustments(
        orientation: String,
        adjustments: inout [SplitDividerAdjustment],
        foundSplit: inout Bool,
        hadInvalidSplitIds: inout Bool
    ) -> SplitSpanCounts {
        guard case .split(let splitNode) = self, splitNode.orientation == orientation else {
            return spanCounts()
        }
        let firstSpans = splitNode.first.appendRunEqualizeAdjustments(
            orientation: orientation,
            adjustments: &adjustments,
            foundSplit: &foundSplit,
            hadInvalidSplitIds: &hadInvalidSplitIds
        )
        let secondSpans = splitNode.second.appendRunEqualizeAdjustments(
            orientation: orientation,
            adjustments: &adjustments,
            foundSplit: &foundSplit,
            hadInvalidSplitIds: &hadInvalidSplitIds
        )
        foundSplit = true
        let spans = SplitSpanCounts(orientation: orientation, first: firstSpans, second: secondSpans)
        guard let splitId = UUID(uuidString: splitNode.id) else {
            hadInvalidSplitIds = true
            return spans
        }
        let firstSpanCount = firstSpans.along(orientation)
        let secondSpanCount = secondSpans.along(orientation)
        let position = CGFloat(firstSpanCount) / CGFloat(firstSpanCount + secondSpanCount)
        adjustments.append(SplitDividerAdjustment(splitId: splitId, position: position))
        return spans
    }

    /// Post-order equalize over the whole tree; returns this subtree's spans
    /// so each node is counted once.
    @discardableResult
    private func appendEqualizeAdjustments(
        orientationFilter: String?,
        adjustments: inout [SplitDividerAdjustment],
        foundSplit: inout Bool,
        hadInvalidSplitIds: inout Bool
    ) -> SplitSpanCounts {
        switch self {
        case .pane:
            return .pane
        case .split(let splitNode):
            let firstSpans = splitNode.first.appendEqualizeAdjustments(
                orientationFilter: orientationFilter,
                adjustments: &adjustments,
                foundSplit: &foundSplit,
                hadInvalidSplitIds: &hadInvalidSplitIds
            )
            let secondSpans = splitNode.second.appendEqualizeAdjustments(
                orientationFilter: orientationFilter,
                adjustments: &adjustments,
                foundSplit: &foundSplit,
                hadInvalidSplitIds: &hadInvalidSplitIds
            )

            if orientationFilter == nil || splitNode.orientation == orientationFilter {
                foundSplit = true
                if let splitId = UUID(uuidString: splitNode.id) {
                    let firstSpanCount = firstSpans.along(splitNode.orientation)
                    let secondSpanCount = secondSpans.along(splitNode.orientation)
                    let totalSpanCount = firstSpanCount + secondSpanCount
                    let position = CGFloat(firstSpanCount) / CGFloat(totalSpanCount)
                    adjustments.append(SplitDividerAdjustment(splitId: splitId, position: position))
                } else {
                    hadInvalidSplitIds = true
                }
            }
            return SplitSpanCounts(orientation: splitNode.orientation, first: firstSpans, second: secondSpans)
        }
    }

    private func spanCounts() -> SplitSpanCounts {
        switch self {
        case .pane:
            return .pane
        case .split(let splitNode):
            return SplitSpanCounts(
                orientation: splitNode.orientation,
                first: splitNode.first.spanCounts(),
                second: splitNode.second.spanCounts()
            )
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

/// Panes side by side along each axis: the weights equalize gives dividers.
private struct SplitSpanCounts {
    static let pane = SplitSpanCounts(horizontal: 1, vertical: 1)

    let horizontal: Int
    let vertical: Int

    init(horizontal: Int, vertical: Int) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// A split adds its children along its own axis. Across it, the children
    /// stack, so it is as wide as its widest child: a column holding two
    /// 2-pane rows spans 2.
    init(orientation: String, first: SplitSpanCounts, second: SplitSpanCounts) {
        let isHorizontal = orientation == "horizontal"
        horizontal = isHorizontal
            ? first.horizontal + second.horizontal
            : max(first.horizontal, second.horizontal)
        vertical = isHorizontal
            ? max(first.vertical, second.vertical)
            : first.vertical + second.vertical
    }

    func along(_ orientation: String) -> Int {
        orientation == "horizontal" ? horizontal : vertical
    }
}
