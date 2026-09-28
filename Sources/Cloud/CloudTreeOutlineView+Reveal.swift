import AppKit
import Foundation

extension CloudTreeOutlineView.Coordinator {
    /// Selects a requested row once, expanding its ancestors and the row itself.
    func reveal(_ request: CloudTreeRevealRequest?) {
        guard let request, request.token != lastRevealToken, let outlineView,
              let path = request.path(in: nodes), let node = path.last else { return }
        for ancestor in path.dropLast() where !outlineView.isItemExpanded(ancestor) {
            expansionStore.setExpanded(true, node: ancestor)
            outlineView.expandItem(ancestor)
        }
        if node.isExpandable, !outlineView.isItemExpanded(node) {
            expansionStore.setExpanded(true, node: node)
            outlineView.expandItem(node)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        lastRevealToken = request.token
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// Follows this window's workspace creation: selects the new row once it
    /// exists, expanding its machine and Workspaces group, and puts the prior
    /// selection back when the create is withdrawn. It never moves keyboard
    /// focus, and a newer selection always wins.
    func reveal(creation request: CloudWorkspaceCreationReveal?) {
        // A drag defers node updates; the next update after it ends catches up.
        guard !isDragging, let outlineView else { return }
        let action = creationRevealPresentation.update(request: request, selectedNodeID: selectedNodeID) { id in
            CloudTreeRevealRequest(token: UUID(), nodeID: id).path(in: nodes) != nil
        }
        switch action {
        case .select(let id)?:
            guard let path = CloudTreeRevealRequest(token: UUID(), nodeID: id).path(in: nodes),
                  let node = path.last else { return }
            for ancestor in path.dropLast() where !outlineView.isItemExpanded(ancestor) {
                expansionStore.setExpanded(true, node: ancestor)
                outlineView.expandItem(ancestor)
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            // A regular selection change records the row, so reloads restore it.
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        case .restore(let baseline)?:
            selectedNodeID = baseline
            withProgrammaticUpdate { restoreSelection(in: outlineView) }
        case nil:
            break
        }
    }
}
