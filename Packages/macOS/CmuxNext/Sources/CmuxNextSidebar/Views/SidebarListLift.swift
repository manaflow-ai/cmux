import AppKit

// cx-bp40 (Lawrence 2026-10-07: "dragging grouped workspaces around ... the
// workspaces inside disappear"): a group drag hides the group's header and
// member rows in the list, so the lifted card carries all of them. The card
// is the whole block, and it lands on the whole block. A workspace drag does
// the same with the workspace's tab rows (cx-ikxz).
@MainActor enum SidebarListLift {
    /// The rows a drag of `key` lifts, top to bottom: a group's header with
    /// its shown members and their tab rows; a workspace with its tab rows,
    /// which the list hides with it, so the card is the block that leaves
    /// the list and lands back in it (cx-ikxz); else the one row.
    static func rows(_ list: SidebarListView, for key: SidebarRowKey, hidden: Set<SidebarRowKey>) -> [SidebarRow] {
        switch key {
        case .group:
            return list.displayed.rows.filter { hidden.contains($0.key) }
        case let .workspace(id):
            return list.displayed.rows.filter { row in
                guard row.key != key else { return true }
                guard case let .tab(owner, _) = row.key else { return false }
                return owner == id && hidden.contains(row.key)
            }
        default:
            return list.displayed.row(for: key).map { [$0] } ?? []
        }
    }

    /// The frame that holds `rows` (list coordinates).
    static func blockFrame(_ list: SidebarListView, _ rows: [SidebarRow]) -> NSRect? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return list.frame(for: first).union(list.frame(for: last))
    }

    /// The lifted card's content: one live row view, or for several rows (a
    /// group, a workspace with tab rows) a block that draws each at its
    /// offset from the first.
    static func content(_ list: SidebarListView, _ rows: [SidebarRow], in block: NSRect) -> NSView? {
        guard rows.count > 1 else { return rows.first.map { rowView(list, $0) } }
        let container = SidebarLiftBlockView(frame: NSRect(origin: .zero, size: block.size))
        // The group's members' line rides under the rows on the card, as in the list (cx-qno.17).
        let lines = SidebarGroupLine.lines(rows, colors: list.groups) { list.frame(for: $0).offsetBy(dx: -block.minX, dy: -block.minY) }
        for line in lines {
            let view = NSView(frame: line.frame)
            view.wantsLayer = true
            view.layer?.cornerRadius = line.frame.width / 2
            container.performWithTheme { view.layer?.backgroundColor = line.color.headerFill.cgColor }
            container.addSubview(view)
        }
        for row in rows {
            let view = rowView(list, row)
            let rowFrame = list.frame(for: row)
            view.frame = rowFrame.offsetBy(dx: -block.minX, dy: -block.minY)
            view.autoresizingMask = [.width]
            container.addSubview(view)
        }
        return container
    }

    private static func rowView(_ list: SidebarListView, _ row: SidebarRow) -> SidebarRowView {
        let content = list.dequeue(row.key)
        content.targetSize = list.frame(for: row).size
        list.configure(content, row: row, animated: false)
        content.isHovered = false
        content.isSelected = false // The lifted card is its own raised surface: no selection fill on it.
        (content as? WorkspaceRowView)?.isSecondarySelected = false
        return content
    }
}

/// The lifted content of a block drag: a group's header and member rows, or
/// a workspace and its tab rows.
final class SidebarLiftBlockView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
