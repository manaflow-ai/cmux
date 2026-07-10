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
              case .split(_, _, let orientation, let firstTree, let secondTree) = tmuxTree,
              let splitID = UUID(uuidString: split.id),
              split.orientation == (orientation == .horizontal ? "horizontal" : "vertical") else { return }
        let first = firstTree.layout
        let position = CGFloat(split.dividerPosition)
        let previous = lastDividerPositions[splitID] ?? position
        if abs(position - previous) > 0.005 {
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
            let flag = orientation == .horizontal ? "-x" : "-y"
            _ = connection?.send(
                "resize-pane -t @\(windowId).%\(first.paneIDsInOrder.first ?? 0) \(flag) \(cells)"
            )
        }

        let parentExtent = orientation == .horizontal
            ? parentSize.width
            : parentSize.height
        let childExtents = metrics.childExtents(
            parentExtent: parentExtent,
            dividerPosition: position
        )
        let firstSize: CGSize
        let secondSize: CGSize
        if orientation == .horizontal {
            firstSize = CGSize(width: childExtents.first, height: parentSize.height)
            secondSize = CGSize(width: childExtents.second, height: parentSize.height)
        } else {
            firstSize = CGSize(width: parentSize.width, height: childExtents.first)
            secondSize = CGSize(width: parentSize.width, height: childExtents.second)
        }
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
