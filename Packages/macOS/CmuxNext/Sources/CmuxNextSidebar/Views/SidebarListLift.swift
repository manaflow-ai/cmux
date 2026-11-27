import AppKit

// cx-bp40 (Lawrence 2026-10-07: "dragging grouped workspaces around ... the
// workspaces inside disappear"): a group drag hides the group's header and
// member rows in the list, so the lifted card carries all of them. The card
// is the whole block, and it lands on the whole block.
@MainActor enum SidebarListLift {
    /// The rows a drag of `key` lifts, top to bottom: a group's header with
    /// its shown members, which the list hides with it, so the card is the
    /// block that leaves the list and lands back in it; else the one row.
    static func rows(_ list: SidebarListView, for key: SidebarRowKey, hidden: Set<SidebarRowKey>) -> [SidebarRow] {
        switch key {
        case .group:
            return list.displayed.rows.filter { hidden.contains($0.key) }
        default:
            return list.displayed.row(for: key).map { [$0] } ?? []
        }
    }

    /// The frame that holds `rows` (list coordinates), and a lifted group's members' line: the line
    /// runs just left of the rows (`SidebarStyle.groupLineX`), so the card reaches over it and the
    /// line and rows stay where they were in the list when the group lifts.
    static func blockFrame(_ list: SidebarListView, _ rows: [SidebarRow]) -> NSRect? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return withLines(list, rows, list.frame(for: first).union(list.frame(for: last)))
    }

    /// `block` grown over the members' lines of the open groups among `rows`, each row placed by `frame`
    /// (default: its layout frame). The lift, the landing and a settled drop all use it, so a group's card
    /// keeps one frame from lift to landing (#23975).
    static func withLines(_ list: SidebarListView, _ rows: [SidebarRow], _ block: NSRect,
                          frame: ((SidebarRow) -> CGRect)? = nil) -> NSRect {
        guard rows.count > 1 else { return block }
        return lines(list, rows, frame: frame).reduce(block) { $0.union($1.frame) }
    }

    /// The members' lines of the open groups among `rows` (list coordinates).
    static func lines(_ list: SidebarListView, _ rows: [SidebarRow], frame: ((SidebarRow) -> CGRect)? = nil) -> [SidebarGroupLine] {
        // The list's own look (`styled`): `sidebar.showColors` off, no group color on the lifted card either.
        list.styled(SidebarGroupLine.lines(rows, colors: list.lineColors) { frame?($0) ?? list.frame(for: $0) })
    }

    /// The lifted card's content: one live row view, or for several rows (a
    /// group) a block that draws each at its
    /// offset from the first.
    static func content(_ list: SidebarListView, _ rows: [SidebarRow], in block: NSRect) -> NSView? {
        guard rows.count > 1 else { return rows.first.map { rowView(list, $0) } }
        let container = SidebarLiftBlockView(frame: NSRect(origin: .zero, size: block.size))
        // The group's members' line rides under the rows on the card, as in the list (cx-qno.17): the list's own
        // line view, the same shape and color, painted in the scope the card lands in.
        for line in lines(list, rows) {
            let view = GroupLineView()
            view.frame = line.frame.offsetBy(dx: -block.minX, dy: -block.minY)
            view.isBlock = line.isBlock
            view.color = line.color
            view.background = line.background
            view.strength = SidebarGroupLine.opacity(level: line.level)
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

    /// A multi-selection's card (Leo 2026-11-08: "ours vs edge's group moving i think we need to make ours more like
    /// edge and chrome"): every selected row the list draws, stacked in `ids` order (the order the drop and the drag's
    /// look lay them out, `SidebarDragLook`) at the list's row spacing, with the pressed row where it was, under the
    /// pointer. The card is as tall as the gap the list opens for the rows. `shown` counts the rows on the card (a row
    /// in a collapsed group has none). Nil for fewer than two rows.
    static func stack(_ list: SidebarListView, ids: [WorkspaceID], pressed: SidebarRowKey)
        -> (frame: NSRect, content: NSView, shown: Int)? {
        let rows = ids.compactMap { list.displayed.row(for: .workspace($0)) }
        guard rows.count > 1, let at = rows.firstIndex(where: { $0.key == pressed }) else { return nil }
        let spacing = list.displayed.rowSpacing
        let frames = rows.map { list.frame(for: $0) }
        let minX = frames.map(\.minX).min() ?? 0, maxX = frames.map(\.maxX).max() ?? 0
        let above = frames[..<at].reduce(0) { $0 + $1.height + spacing }
        let height = frames.reduce(0) { $0 + $1.height } + spacing * CGFloat(frames.count - 1)
        let frame = NSRect(x: minX, y: frames[at].minY - above, width: maxX - minX, height: height)
        let container = SidebarLiftBlockView(frame: NSRect(origin: .zero, size: frame.size))
        var y: CGFloat = 0
        for (row, rowFrame) in zip(rows, frames) {
            let view = rowView(list, row)
            view.frame = NSRect(x: 0, y: y, width: frame.width, height: rowFrame.height)
            view.autoresizingMask = [.width]
            container.addSubview(view)
            y += rowFrame.height + spacing
        }
        return (frame, container, rows.count)
    }

    private static func rowView(_ list: SidebarListView, _ row: SidebarRow) -> SidebarRowView {
        let content = list.dequeue(row.key)
        content.targetSize = list.frame(for: row).size
        list.configure(content, row: row, animated: false)
        content.isHovered = false
        // A selected row keeps its selection fill on the card, so it reads the same lifted as in the list
        // before and after the drag (Leo 2026-10-18). The card shows no row to VoiceOver (DragLiftView).
        // The lifted header shows no hover-only buttons and no focus ring.
        (content as? GroupHeaderRowView)?.isKeyboardFocused = false
        (content as? WorkspaceRowView)?.isKeyboardFocused = false
        (content as? GroupHeaderRowView)?.isEditing = false
        return content
    }
}

/// The lifted content of a block drag: a group's header and member rows.
final class SidebarLiftBlockView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
