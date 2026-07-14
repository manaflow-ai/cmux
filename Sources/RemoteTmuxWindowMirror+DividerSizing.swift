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
    ///
    /// `sendWithoutBaseline` is drag-end's belt: a missing baseline (an
    /// imposition parked it nil and nothing reseeded it) normally routes to
    /// seed-only, because outside a drag an unbaselined fraction is our own
    /// imposition echoing back. A drag END is different — the fraction is
    /// the user's, and the cells-versus-assigned check below is the true
    /// no-op detector — so drag end converts and sends even with no
    /// baseline rather than swallowing the user's move.
    @discardableResult
    func syncChangedDividerPositions(sendWithoutBaseline: Bool = false) -> Bool {
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
            metrics: metrics,
            sendWithoutBaseline: sendWithoutBaseline
        )
    }

    private func syncChangedDividerPositions(
        treeNode: ExternalTreeNode,
        tmuxTree: RemoteTmuxNativeMeasuredSplitTree,
        parentSize: CGSize,
        metrics: RemoteTmuxNativeLayoutMetrics,
        sendWithoutBaseline: Bool
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
            sentResize = requestResizeForDividerPosition(
                position,
                parentSize: parentSize,
                orientation: orientation,
                firstTree: firstTree,
                secondTree: secondTree,
                first: first,
                metrics: metrics
            )
        } else if lastDividerPositions[splitID] == nil {
            // A changed imposition with no post-layout callback has no
            // trustworthy pre-drag fraction. Seed once; subsequent drag
            // callbacks carry only the user's delta and route normally.
            // At drag END the fraction is the user's move, not an echo, so
            // the belt converts and sends instead of swallowing it — the
            // cells-versus-assigned check inside is the real no-op filter.
            lastDividerPositions[splitID] = position
            if sendWithoutBaseline {
                sentResize = requestResizeForDividerPosition(
                    position,
                    parentSize: parentSize,
                    orientation: orientation,
                    firstTree: firstTree,
                    secondTree: secondTree,
                    first: first,
                    metrics: metrics
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
            metrics: metrics,
            sendWithoutBaseline: sendWithoutBaseline
        )
        let sentInSecond = syncChangedDividerPositions(
            treeNode: split.second,
            tmuxTree: secondTree,
            parentSize: secondSize,
            metrics: metrics,
            sendWithoutBaseline: sendWithoutBaseline
        )
        return sentResize || sentInFirst || sentInSecond
    }

    /// Converts one divider fraction to a grid-feasible first-subtree span
    /// and requests it from tmux when it differs from the assignment.
    ///
    /// Grid-feasible, not just cell-aware. A sub-cell nudge rounds to the
    /// span tmux already holds, and a drag past the sibling's minimum
    /// converts to a span tmux cannot assign; both produce a resize-pane
    /// that changes no layout, and a no-op command never gets the layout
    /// reply drag-end would wait for — the divider would park off-grid
    /// while later passes early-return on unchanged inputs. Clamp the
    /// request to the split's feasible range first; only a real, achievable
    /// cell change goes to tmux, and anything else routes drag-end to the
    /// immediate re-impose.
    private func requestResizeForDividerPosition(
        _ position: CGFloat,
        parentSize: CGSize,
        orientation: RemoteTmuxSplitOrientation,
        firstTree: RemoteTmuxNativeMeasuredSplitTree,
        secondTree: RemoteTmuxNativeMeasuredSplitTree,
        first: RemoteTmuxLayoutNode,
        metrics: RemoteTmuxNativeLayoutMetrics
    ) -> Bool {
        let parentExtent = orientation == .horizontal
            ? parentSize.width
            : parentSize.height
        let requested = metrics.requestedTmuxSpan(
            first: firstTree,
            orientation: orientation,
            parentExtent: parentExtent,
            dividerPosition: position
        )
        let cells = RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            requested,
            first: firstTree,
            second: secondTree,
            orientation: orientation
        )
        let assigned = orientation == .horizontal ? first.width : first.height
        guard cells != assigned, let targetPaneID = first.paneIDsInOrder.first else {
            return false
        }
        let sent = requestResizePane(
            targetPaneID,
            absoluteAxis: orientation.treeName,
            targetCells: cells
        )
        if sent { dividerResizeSentSinceDragBegan = true }
        return sent
    }
}
