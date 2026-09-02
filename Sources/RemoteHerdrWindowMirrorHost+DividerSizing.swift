import Bonsplit
import CmuxNestedTopology
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
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

    /// Synchronizes changed native dividers to Herdr via ``pane.resize``.
    ///
    /// Herdr resize is absolute cols/rows on a leaf; we convert the first
    /// subtree's divider fraction into that leaf's assigned cell span and
    /// resize the first leaf of the first child.
    @discardableResult
    func syncChangedDividerPositions(sendWithoutBaseline: Bool = false) -> Bool {
        guard let containerSizePt, containerSizePt.width > 0, containerSizePt.height > 0 else {
            return false
        }
        guard let layout = renderedLayout else { return false }
        return syncChangedDividerPositions(
            treeNode: bonsplitController.treeSnapshot(),
            layoutNode: layout,
            parentSize: containerSizePt,
            sendWithoutBaseline: sendWithoutBaseline
        )
    }

    private func syncChangedDividerPositions(
        treeNode: ExternalTreeNode,
        layoutNode: RemoteHerdrLayoutNode,
        parentSize: CGSize,
        sendWithoutBaseline: Bool
    ) -> Bool {
        guard case .split(let split) = treeNode,
              let splitID = UUID(uuidString: split.id),
              let children = layoutNode.children, children.count >= 2
        else { return false }

        let isHorizontal = layoutNode.isHorizontal
        let expectedOrientation = isHorizontal ? "horizontal" : "vertical"
        guard split.orientation == expectedOrientation else { return false }

        let position = CGFloat(split.dividerPosition)
        var sentResize = false

        if split.imposedFirstExtent != nil {
            lastDividerPositions[splitID] = position
        } else if let previous = lastDividerPositions[splitID],
                  abs(position - previous) > 0.005 {
            lastDividerPositions[splitID] = position
            sentResize = requestResizeForDividerPosition(
                position,
                parentSize: parentSize,
                firstChild: children[0],
                siblings: Array(children.dropFirst()),
                isHorizontal: isHorizontal
            )
        } else if lastDividerPositions[splitID] == nil {
            lastDividerPositions[splitID] = position
            if sendWithoutBaseline {
                sentResize = requestResizeForDividerPosition(
                    position,
                    parentSize: parentSize,
                    firstChild: children[0],
                    siblings: Array(children.dropFirst()),
                    isHorizontal: isHorizontal
                )
            }
        }

        let parentExtent = isHorizontal ? parentSize.width : parentSize.height
        let firstExtent = parentExtent * position
        let secondExtent = parentExtent - firstExtent
        let firstSize: CGSize
        let secondSize: CGSize
        if isHorizontal {
            firstSize = CGSize(width: firstExtent, height: parentSize.height)
            secondSize = CGSize(width: secondExtent, height: parentSize.height)
        } else {
            firstSize = CGSize(width: parentSize.width, height: firstExtent)
            secondSize = CGSize(width: parentSize.width, height: secondExtent)
        }

        let rest = Array(children.dropFirst())
        let secondLayout: RemoteHerdrLayoutNode
        if rest.count == 1 {
            secondLayout = rest[0]
        } else if isHorizontal {
            secondLayout = RemoteHerdrLayoutNode(
                width: rest.map(\.width).reduce(0, +),
                height: rest.map(\.height).max() ?? rest[0].height,
                x: rest[0].x,
                y: rest[0].y,
                content: .horizontal(rest)
            )
        } else {
            secondLayout = RemoteHerdrLayoutNode(
                width: rest.map(\.width).max() ?? rest[0].width,
                height: rest.map(\.height).reduce(0, +),
                x: rest[0].x,
                y: rest[0].y,
                content: .vertical(rest)
            )
        }

        let sentInFirst = syncChangedDividerPositions(
            treeNode: split.first,
            layoutNode: children[0],
            parentSize: firstSize,
            sendWithoutBaseline: sendWithoutBaseline
        )
        let sentInSecond = syncChangedDividerPositions(
            treeNode: split.second,
            layoutNode: secondLayout,
            parentSize: secondSize,
            sendWithoutBaseline: sendWithoutBaseline
        )
        return sentResize || sentInFirst || sentInSecond
    }

    @discardableResult
    private func requestResizeForDividerPosition(
        _ position: CGFloat,
        parentSize: CGSize,
        firstChild: RemoteHerdrLayoutNode,
        siblings: [RemoteHerdrLayoutNode],
        isHorizontal: Bool
    ) -> Bool {
        let parentExtent = isHorizontal ? parentSize.width : parentSize.height
        let firstSpan = isHorizontal ? firstChild.width : firstChild.height
        let siblingSpan = siblings.reduce(0) { partial, sibling in
            partial + (isHorizontal ? sibling.width : sibling.height)
        }
        let axisTotal = max(2, firstSpan + siblingSpan)
        let draggedExtent = Double(parentExtent * position)
        let cells = sizing.resizeCells(
            draggedExtent: draggedExtent,
            axisSpan: Double(parentExtent),
            totalCells: axisTotal
        )
        guard let leafID = firstChild.paneIDsInOrder.first else { return false }
        let leaf = firstChild.firstLeaf(withPaneID: leafID) ?? firstChild
        let cols: Int
        let rows: Int
        if isHorizontal {
            cols = cells
            rows = max(1, leaf.height)
        } else {
            cols = max(1, leaf.width)
            rows = cells
        }
        // Skip no-ops that would not change the assigned leaf grid.
        if leaf.width == cols, leaf.height == rows { return false }
        onResizePaneRequest?(leafID, cols, rows)
        dividerResizeSentSinceDragBegan = true
        return true
    }
}
