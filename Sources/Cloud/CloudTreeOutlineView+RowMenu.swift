import AppKit

extension CloudTreeOutlineView.Coordinator {
    /// Shows a row's context menu under its trailing "⋯" button, the same
    /// menu a right-click opens.
    func popUpRowMenu(nodeID: String) {
        guard let outlineView,
              let row = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? CloudTreeNode)?.id == nodeID }),
              let menu = contextMenu(forRow: row),
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        let bounds = cell.bounds
        let anchor = NSPoint(x: bounds.maxX - 24, y: cell.isFlipped ? bounds.maxY : bounds.minY)
        menu.popUp(positioning: nil, at: anchor, in: cell)
    }
}
