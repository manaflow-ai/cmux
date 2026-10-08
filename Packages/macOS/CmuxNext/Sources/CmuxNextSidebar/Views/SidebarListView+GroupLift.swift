import AppKit

// cx-bp40 (Lawrence 2026-10-07: "dragging grouped workspaces around ... the
// workspaces inside disappear"): a group drag hides the group's header and
// member rows in the list, so the lifted card carries all of them. The card
// is the whole block, and it lands on the whole block.
extension SidebarListView {
    /// The rows a drag of `key` lifts, top to bottom: a group's header with
    /// its shown members and their tab rows; else the one row.
    func liftRows(for key: SidebarRowKey, hidden: Set<SidebarRowKey>) -> [SidebarRow] {
        guard case .group = key else { return displayed.row(for: key).map { [$0] } ?? [] }
        return displayed.rows.filter { hidden.contains($0.key) }
    }

    /// The frame that holds `rows` (list coordinates).
    func blockFrame(_ rows: [SidebarRow]) -> NSRect? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return frame(for: first).union(frame(for: last))
    }

    /// The lifted card's content: one live row view, or for several rows a
    /// block that draws each at its offset from the first.
    func liftContent(_ rows: [SidebarRow], in block: NSRect) -> NSView? {
        guard rows.count > 1 else { return rows.first.map(liftRowView) }
        let container = SidebarLiftBlockView(frame: NSRect(origin: .zero, size: block.size))
        for row in rows {
            let view = liftRowView(row)
            let rowFrame = frame(for: row)
            view.frame = rowFrame.offsetBy(dx: -block.minX, dy: -block.minY)
            view.autoresizingMask = [.width]
            container.addSubview(view)
        }
        return container
    }

    private func liftRowView(_ row: SidebarRow) -> SidebarRowView {
        let content = dequeue(row.key)
        content.targetSize = frame(for: row).size
        configure(content, row: row, animated: false)
        content.isHovered = false
        content.isSelected = false // The lifted card is its own raised surface: no selection fill on it.
        (content as? WorkspaceRowView)?.isSecondarySelected = false
        return content
    }
}

/// The lifted content of a group drag: the header and its member rows.
final class SidebarLiftBlockView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
