import AppKit

extension CloudTreeOutlineView.Coordinator {
    /// Re-expands every row the expansion store remembers after a full reload.
    func restoreExpansion(in outlineView: NSOutlineView) {
        var row = 0
        while row < outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? CloudTreeNode,
               node.isExpandable,
               expansionStore.isExpanded(node) {
                outlineView.expandItem(node)
            }
            row += 1
        }
    }

    /// Selects the row for ``selectedNodeID``, or nothing when it is not shown.
    func restoreSelection(in outlineView: NSOutlineView) {
        outlineView.deselectAll(nil)
        guard let selectedNodeID else { return }
        for row in 0..<outlineView.numberOfRows {
            if (outlineView.item(atRow: row) as? CloudTreeNode)?.id == selectedNodeID {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }
}
