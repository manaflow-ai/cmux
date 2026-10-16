public import Bonsplit
import Foundation

/// Whether a pane can be split without leaving a pane below the minimum size.
public enum SplitSpaceVerdict: Sendable, Equatable {
    /// Both halves of the split meet the minimum as the layout stands.
    case fits
    /// The halves would be too small, but equalizing the run of
    /// same-orientation splits that will hold them gives every pane in the
    /// run the minimum. Apply the split, then equalize that run.
    case fitsAfterEqualizingRun
    /// No layout of the run fits another pane: refuse the split, the way
    /// tmux answers "no space for new pane".
    case noSpace
}

private func splitSpaceClampedDividerPosition(_ position: Double) -> Double {
    min(max(position, 0.1), 0.9)
}

extension ExternalTreeNode {
    /// Decides whether splitting `paneId` along `orientation` fits.
    ///
    /// A split halves the pane, so it fits in place when each half keeps
    /// `minimumExtent` along the split axis. Otherwise it may borrow from the
    /// panes it stacks with: the pane's parent split and every ancestor of the
    /// same orientation form one run, and equalizing that run after the split
    /// gives each of its slots an equal share. The split fits after
    /// equalizing when each slot's share still covers what the slot needs.
    /// A slot that is itself split across the axis needs the most its
    /// children need. Equalizing leaves same-axis splits nested behind it
    /// alone, so they keep their divider position and need enough room for
    /// each side at that proportion.
    ///
    /// Frames of zero extent mean the layout has not been measured yet, so
    /// the split is allowed rather than refused on unknown geometry.
    ///
    /// - Parameters:
    ///   - paneId: The pane being split.
    ///   - orientation: `"horizontal"` (side by side) or `"vertical"` (stacked).
    ///   - minimumExtent: The smallest width (horizontal) or height (vertical)
    ///     a pane may have, in points.
    ///   - dividerThickness: The space one divider takes along the axis.
    ///   - dividerPosition: The requested first-child ratio. Bonsplit clamps
    ///     it to 0.1...0.9; `nil` uses its 0.5 default.
    public func splitSpaceVerdict(
        splittingPaneId paneId: String,
        orientation: String,
        minimumExtent: Double,
        dividerThickness: Double,
        dividerPosition: Double? = nil
    ) -> SplitSpaceVerdict {
        guard let path = splitSpacePath(toPaneId: paneId) else { return .fits }
        let isHorizontal = orientation == "horizontal"
        let paneExtent = path.pane.axisExtent(isHorizontal: isHorizontal)
        guard paneExtent > 0 else { return .fits }
        let position = splitSpaceClampedDividerPosition(dividerPosition ?? 0.5)
        let availablePaneExtent = paneExtent - dividerThickness
        if availablePaneExtent * position >= minimumExtent,
           availablePaneExtent * (1 - position) >= minimumExtent {
            return .fits
        }

        guard let parent = path.splits.last, parent.orientation == orientation else {
            return .noSpace
        }
        var runRoot = parent
        for ancestor in path.splits.dropLast().reversed() {
            guard ancestor.orientation == orientation else { break }
            runRoot = ancestor
        }
        let run = ExternalTreeNode.split(runRoot)
        let runExtent = run.axisExtent(isHorizontal: isHorizontal)
        let fits = run.fitsAfterEqualizingRun(
            extent: runExtent,
            orientation: orientation,
            splittingPaneId: paneId,
            minimumExtent: minimumExtent,
            dividerThickness: dividerThickness
        )
        return fits ? .fitsAfterEqualizingRun : .noSpace
    }

    private struct SplitSpacePath {
        var splits: [ExternalSplitNode]
        var pane: ExternalTreeNode
    }

    private func splitSpacePath(toPaneId paneId: String) -> SplitSpacePath? {
        switch self {
        case .pane(let pane):
            return pane.id == paneId ? SplitSpacePath(splits: [], pane: self) : nil
        case .split(let splitNode):
            guard var rest = splitNode.first.splitSpacePath(toPaneId: paneId)
                ?? splitNode.second.splitSpacePath(toPaneId: paneId) else { return nil }
            rest.splits.insert(splitNode, at: 0)
            return rest
        }
    }

    /// Simulates the exact divider positions that Bonsplit applies when the
    /// run is equalized. Ratios outside its configured 0.1...0.9 range are
    /// clamped, so averaging all slots would overestimate the smaller side of
    /// an 11-or-more-slot run.
    private func fitsAfterEqualizingRun(
        extent: Double,
        orientation: String,
        splittingPaneId: String,
        minimumExtent: Double,
        dividerThickness: Double
    ) -> Bool {
        switch self {
        case .pane(let pane):
            if pane.id == splittingPaneId {
                return (extent - dividerThickness) / 2 >= minimumExtent
            }
            return extent >= minimumExtent
        case .split(let splitNode):
            guard splitNode.orientation == orientation else {
                return requiredExtent(
                    orientation: orientation,
                    minimumExtent: minimumExtent,
                    dividerThickness: dividerThickness
                ) <= extent
            }
            let firstSpanCount = splitNode.first.prospectiveSpanCount(
                orientation: orientation,
                splittingPaneId: splittingPaneId
            )
            let secondSpanCount = splitNode.second.prospectiveSpanCount(
                orientation: orientation,
                splittingPaneId: splittingPaneId
            )
            let availableExtent = extent - dividerThickness
            guard availableExtent >= 0 else { return false }
            let position = splitSpaceClampedDividerPosition(
                Double(firstSpanCount) / Double(firstSpanCount + secondSpanCount)
            )
            return splitNode.first.fitsAfterEqualizingRun(
                extent: availableExtent * position,
                orientation: orientation,
                splittingPaneId: splittingPaneId,
                minimumExtent: minimumExtent,
                dividerThickness: dividerThickness
            ) && splitNode.second.fitsAfterEqualizingRun(
                extent: availableExtent * (1 - position),
                orientation: orientation,
                splittingPaneId: splittingPaneId,
                minimumExtent: minimumExtent,
                dividerThickness: dividerThickness
            )
        }
    }

    private func prospectiveSpanCount(orientation: String, splittingPaneId: String) -> Int {
        switch self {
        case .pane(let pane):
            return pane.id == splittingPaneId ? 2 : 1
        case .split(let splitNode):
            guard splitNode.orientation == orientation else { return 1 }
            return splitNode.first.prospectiveSpanCount(
                orientation: orientation,
                splittingPaneId: splittingPaneId
            ) + splitNode.second.prospectiveSpanCount(
                orientation: orientation,
                splittingPaneId: splittingPaneId
            )
        }
    }

    /// The smallest extent along the axis of `orientation` that keeps every
    /// pane in this subtree at `minimumExtent`.
    private func requiredExtent(
        orientation: String,
        minimumExtent: Double,
        dividerThickness: Double
    ) -> Double {
        switch self {
        case .pane:
            return minimumExtent
        case .split(let splitNode):
            let first = splitNode.first.requiredExtent(
                orientation: orientation,
                minimumExtent: minimumExtent,
                dividerThickness: dividerThickness
            )
            let second = splitNode.second.requiredExtent(
                orientation: orientation,
                minimumExtent: minimumExtent,
                dividerThickness: dividerThickness
            )
            guard splitNode.orientation == orientation else { return max(first, second) }
            let position = splitSpaceClampedDividerPosition(splitNode.dividerPosition)
            return max(first / position, second / (1 - position)) + dividerThickness
        }
    }

    /// The extent along the axis covered by this subtree's pane frames.
    private func axisExtent(isHorizontal: Bool) -> Double {
        guard let span = axisSpan(isHorizontal: isHorizontal) else { return 0 }
        return span.upperBound - span.lowerBound
    }

    private func axisSpan(isHorizontal: Bool) -> ClosedRange<Double>? {
        switch self {
        case .pane(let pane):
            let start = isHorizontal ? pane.frame.x : pane.frame.y
            let length = isHorizontal ? pane.frame.width : pane.frame.height
            return start...(start + max(length, 0))
        case .split(let splitNode):
            let first = splitNode.first.axisSpan(isHorizontal: isHorizontal)
            let second = splitNode.second.axisSpan(isHorizontal: isHorizontal)
            switch (first, second) {
            case let (first?, second?):
                return min(first.lowerBound, second.lowerBound)...max(first.upperBound, second.upperBound)
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case (nil, nil):
                return nil
            }
        }
    }
}
