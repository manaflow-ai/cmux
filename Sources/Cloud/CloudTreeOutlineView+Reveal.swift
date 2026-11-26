import AppKit
import Foundation

extension CloudTreeOutlineView.Coordinator {
    /// Selects a requested row once, expanding its ancestors and the row itself.
    func reveal(_ request: CloudTreeRevealRequest?) {
        guard let request, request.token != lastRevealToken, let outlineView,
              let path = request.path(in: nodes), let node = path.last else { return }
        expand(path.dropLast(), in: outlineView)
        if node.isExpandable { expand([node], in: outlineView) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        lastRevealToken = request.token
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowFullyIntoView(row, in: outlineView)
    }

    /// Follows this window's workspace creation: selects the new row once it
    /// exists, expanding its machine and Workspaces group, and puts the prior
    /// selection back when the create is withdrawn. It never moves keyboard
    /// focus, and a newer selection always wins.
    func reveal(creation request: CloudWorkspaceCreationReveal?) {
        // A drag defers node updates; the next update after it ends catches up.
        guard !isDragging, let outlineView else { return }
        let action = creationRevealPresentation.update(request: request, selectedNodeID: selectedNodeID) { id in
            CloudTreeNode.path(to: id, in: nodes) != nil
        }
        switch action {
        case .select(let id)?:
            guard let path = CloudTreeNode.path(to: id, in: nodes), let node = path.last else { return }
            expand(path.dropLast(), in: outlineView)
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            // A regular selection change records the row, so reloads restore it.
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // The outline view refuses rows it cannot select; retry those later.
            guard outlineView.selectedRow == row else { return }
            scrollRowFullyIntoView(row, in: outlineView)
            creationRevealPresentation.didSelect(id)
        case .restore(let baseline)?:
            selectedNodeID = baseline
            withProgrammaticUpdate { restoreSelection(in: outlineView) }
            // The reveal scrolled away from the prior row; bring it back.
            if outlineView.selectedRow >= 0 {
                scrollRowFullyIntoView(outlineView.selectedRow, in: outlineView)
            }
        case nil:
            break
        }
    }

    private func expand(_ nodes: some Sequence<CloudTreeNode>, in outlineView: NSOutlineView) {
        for node in nodes where !outlineView.isItemExpanded(node) {
            expansionStore.setExpanded(true, node: node)
            outlineView.expandItem(node)
        }
    }

    /// `scrollRowToVisible` accepts a partially visible row. Reveals need the
    /// whole row visible so a newly selected workspace is not clipped at the
    /// viewport edge after fractional row-height rounding.
    func scrollRowFullyIntoView(_ row: Int, in outlineView: NSOutlineView) {
        guard row >= 0 else { return }
        let rowRect = outlineView.rect(ofRow: row)
        if !outlineView.visibleRect.contains(rowRect) {
            outlineView.scrollToVisible(rowRect.insetBy(dx: 0, dy: -1))
        }
    }
}

extension CloudTreeNode {
    /// The node with `id` and its ancestors, root first.
    static func path(to id: String, in nodes: [CloudTreeNode]) -> [CloudTreeNode]? {
        for node in nodes {
            if node.id == id { return [node] }
            if let descendants = path(to: id, in: node.children) { return [node] + descendants }
        }
        return nil
    }
}
