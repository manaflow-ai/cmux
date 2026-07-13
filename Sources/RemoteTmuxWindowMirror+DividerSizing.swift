import CmuxRemoteSession
import Bonsplit
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    /// Synchronizes changed native dividers to tmux in one traversal while
    /// carrying each split's actual local point extent from the root container.
    func syncChangedDividerPositions() {
        guard let containerSizePt,
              let metrics = nativeLayoutMetrics() else { return }
        let splitTree = RemoteTmuxNativeSplitTree(layout: renderedLayout)
        syncChangedDividerPositions(
            treeNode: bonsplitController.treeSnapshot(),
            tmuxTree: RemoteTmuxNativeMeasuredSplitTree(
                tree: splitTree,
                metrics: metrics
            ),
            parentSize: containerSizePt,
            metrics: metrics
        )
    }

    private func syncChangedDividerPositions(
        treeNode: ExternalTreeNode,
        tmuxTree: RemoteTmuxNativeMeasuredSplitTree,
        parentSize: CGSize,
        metrics: RemoteTmuxNativeLayoutMetrics
    ) {
        guard case .split(let split) = treeNode,
              case .split(_, _, _, let orientation, let firstTree, let secondTree) = tmuxTree,
              let splitID = UUID(uuidString: split.id),
              split.orientation == orientation.treeName else { return }
        let first = firstTree.layout
        let position = CGFloat(split.dividerPosition)
        let previous = lastDividerPositions[splitID] ?? position
        // Bonsplit applies imposed extents on its next layout turn, then
        // mirrors the ACTUAL (possibly minimum-clamped) fraction into the
        // model. Rebaseline from that post-layout geometry while the
        // imposition still owns the split; recording during the plan pass
        // snapshots the old fraction before the apply lands.
        if split.imposedFirstExtent != nil {
            lastDividerPositions[splitID] = position
        } else if abs(position - previous) > 0.005 {
            lastDividerPositions[splitID] = position
            let parentExtent = orientation == .horizontal
                ? parentSize.width
                : parentSize.height
            let cells = metrics.requestedTmuxSpan(
                first: firstTree,
                orientation: orientation,
                parentExtent: parentExtent,
                dividerPosition: position
            )
            let axis = orientation.treeName
            if let targetPaneID = first.paneIDsInOrder.first {
                _ = requestResizePane(
                    targetPaneID,
                    absoluteAxis: axis,
                    targetCells: cells
                )
            }
        }

        let parentExtent = orientation == .horizontal
            ? parentSize.width
            : parentSize.height
        let childExtents = metrics.childExtents(
            parentExtent: parentExtent,
            dividerPosition: position
        )
        // Descend with the imposed extent itself when one is active: the
        // divider fraction is mirrored back from the same value, so the two
        // agree to floating-point noise, but the extent is the exact point
        // count the plan chose — no reason to round-trip it through a ratio.
        let firstExtent = split.imposedFirstExtent
            .map { min(max(0, CGFloat($0)), max(0, parentExtent - metrics.dividerThickness)) }
            ?? childExtents.first
        let sizes = metrics.childSizes(
            parentSize: parentSize,
            orientation: orientation,
            firstExtent: firstExtent
        )
        let firstSize = sizes.first
        let secondSize = sizes.second
        syncChangedDividerPositions(
            treeNode: split.first,
            tmuxTree: firstTree,
            parentSize: firstSize,
            metrics: metrics
        )
        syncChangedDividerPositions(
            treeNode: split.second,
            tmuxTree: secondTree,
            parentSize: secondSize,
            metrics: metrics
        )
    }
}
