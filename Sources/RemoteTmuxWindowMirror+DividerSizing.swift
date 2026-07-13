import CmuxRemoteSession
import Bonsplit
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    func pruneDividerBaselines(to treeNode: ExternalTreeNode) {
        var splitIDs: Set<UUID> = []
        collectSplitIDs(treeNode, into: &splitIDs)
        lastDividerPositions = lastDividerPositions.filter { splitIDs.contains($0.key) }
    }

    private func collectSplitIDs(_ treeNode: ExternalTreeNode, into result: inout Set<UUID>) {
        guard case .split(let split) = treeNode else { return }
        if let splitID = UUID(uuidString: split.id) { result.insert(splitID) }
        collectSplitIDs(split.first, into: &result)
        collectSplitIDs(split.second, into: &result)
    }

    /// Synchronizes changed native dividers to tmux in one traversal while
    /// carrying each split's actual local point extent from the root container.
    /// Returns whether any `resize-pane` was requested, so drag-end can tell
    /// "tmux's reply will settle this" apart from "nothing changed in cells".
    @discardableResult
    func syncChangedDividerPositions() -> Bool {
        guard let containerSizePt,
              let metrics = nativeLayoutMetrics() else { return false }
        let splitTree = RemoteTmuxNativeSplitTree(layout: renderedLayout)
        return syncChangedDividerPositions(
            treeNode: bonsplitController.treeSnapshot(),
            tmuxTree: RemoteTmuxNativeMeasuredSplitTree(
                tree: splitTree,
                metrics: metrics
            ),
            // The tree renders at the exact-fit size, so drag fractions are
            // relative to it — reading them against the whole region would
            // convert cells with the wrong denominator.
            parentSize: renderFrameSize ?? containerSizePt,
            metrics: metrics
        )
    }

    private func syncChangedDividerPositions(
        treeNode: ExternalTreeNode,
        tmuxTree: RemoteTmuxNativeMeasuredSplitTree,
        parentSize: CGSize,
        metrics: RemoteTmuxNativeLayoutMetrics
    ) -> Bool {
        guard case .split(let split) = treeNode,
              case .split(_, _, _, let orientation, let firstTree, let secondTree) = tmuxTree,
              let splitID = UUID(uuidString: split.id),
              split.orientation == orientation.treeName else { return false }
        let first = firstTree.layout
        let position = CGFloat(split.dividerPosition)
        var sentResize = false
        // A split holding an imposed extent is not being dragged: starting a
        // drag clears the imposition, and sizing passes hold until the drag
        // ends, so nothing can set it again while the user's hand is on the
        // divider (see the render-ownership section of the design doc). So a
        // fraction change on an imposed split came from our own sizing,
        // never from the user, and there is nothing to tell tmux. Bonsplit
        // applies imposed extents on its next layout turn, then mirrors the
        // ACTUAL (possibly minimum-clamped) fraction into the model —
        // rebaseline from that post-layout geometry while the imposition
        // still owns the split.
        if split.imposedFirstExtent != nil {
            lastDividerPositions[splitID] = position
        } else if let previous = lastDividerPositions[splitID],
                  abs(position - previous) > 0.005 {
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
            // Cell-aware, not fraction-aware: a sub-cell nudge rounds to the
            // span tmux already holds, and asking tmux for it is a no-op it
            // never answers — counting that as "sent" would leave drag-end
            // waiting for a reply that cannot come while the split sits
            // off-grid. Only a real cell change goes to tmux; anything else
            // routes drag-end to the immediate re-impose.
            let assigned = orientation == .horizontal ? first.width : first.height
            if cells != assigned, let targetPaneID = first.paneIDsInOrder.first {
                sentResize = requestResizePane(
                    targetPaneID,
                    absoluteAxis: orientation.treeName,
                    targetCells: cells
                )
                if sentResize { dividerResizeSentSinceDragBegan = true }
            }
        } else if lastDividerPositions[splitID] == nil {
            // A changed imposition with no post-layout callback has no
            // trustworthy pre-drag fraction. Seed once; subsequent drag
            // callbacks carry only the user's delta and route normally.
            lastDividerPositions[splitID] = position
        }

        let parentExtent = orientation == .horizontal
            ? parentSize.width
            : parentSize.height
        let childExtents = metrics.childExtents(
            parentExtent: parentExtent,
            dividerPosition: position
        )
        let sizes = metrics.childSizes(
            parentSize: parentSize,
            orientation: orientation,
            firstExtent: childExtents.first
        )
        let firstSize = sizes.first
        let secondSize = sizes.second
        let sentInFirst = syncChangedDividerPositions(
            treeNode: split.first,
            tmuxTree: firstTree,
            parentSize: firstSize,
            metrics: metrics
        )
        let sentInSecond = syncChangedDividerPositions(
            treeNode: split.second,
            tmuxTree: secondTree,
            parentSize: secondSize,
            metrics: metrics
        )
        return sentResize || sentInFirst || sentInSecond
    }
}
