import AppKit
import CmuxNextDesign

extension SidebarLayout {
    /// Space kept around a revealed active row (close-focus.md).
    static let revealPadding: CGFloat = 8

    /// The rows as `ListViewport` sees them in a viewport `height` tall.
    func viewport(height: CGFloat) -> ListViewport<SidebarRowKey> {
        ListViewport(items: rows.map { .init(id: $0.key, start: $0.y, length: $0.height) },
                     viewport: height, content: max(totalHeight, height))
    }

    /// The extent a reveal of the selection shows (u2605: "Command-1 doesn't scroll all the way up"):
    /// `span` (row `key`, or an item inside block row `key`) with its context: the header rows right
    /// above it (section, group, folder) and the block's own top, the list's top (0) when no workspace
    /// stop draws above it (only top items or headers), and the list's end when nothing lies below it.
    /// Context that would not fit in a viewport `height` tall (with `revealPadding` on both sides) is
    /// dropped, the end first, so the span itself always shows. `id` is the selection's identity
    /// (`SidebarListViewComponents.selectionReveal`). Nil when the layout does not show `key`.
    func revealExtent(id: SidebarRowKey, row key: SidebarRowKey, span: (start: CGFloat, length: CGFloat)? = nil,
                      height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        guard let row = row(for: key) else { return nil }
        // O(log n): `row(for:)` found it, rows are sorted by y; equal tops (empty rows) fall back to a scan.
        guard let index = lastIndex(startingAtOrBefore: row.y).flatMap({ rows[$0].key == key ? $0 : nil })
            ?? rows.firstIndex(where: { $0.key == key }) else { return nil }
        let start = span?.start ?? row.y, end = start + (span?.length ?? row.height)
        var lead = row.key.isBlock ? row.y : start
        var above = index - 1
        while above >= 0, rows[above].key.isRevealHeader { lead = rows[above].y; above -= 1 }
        // Only top items (blocks, link rows) or headers above: the list's top padding, its top items and any
        // header belong to the first stop (`SidebarItemOrder.revealsTop`: Cmd-1 to Home or the first workspace).
        if !rows[..<index].contains(where: \.isWorkspaceStop) { lead = 0 }
        let trail = rows[(index + 1)...].contains(where: { $0.key.isRevealStop }) ? end : max(totalHeight, end)
        let fits = { (lead: CGFloat, trail: CGFloat) in trail - lead + Self.revealPadding * 2 <= height }
        let (l, t) = fits(lead, trail) ? (lead, trail) : fits(lead, end) ? (lead, end) : (start, end)
        return .init(id: id, start: l, length: t - l)
    }
}

private extension SidebarRow {
    /// A workspace stop (a workspace row, or a collapsed group, one stop): what
    /// `SidebarItemOrder.revealsTop` counts before a selection (top items do not).
    var isWorkspaceStop: Bool {
        switch key {
        case .workspace: true
        case .group: isCollapsed
        default: false
        }
    }
}

private extension SidebarRowKey {
    /// A row that only titles the rows below it.
    var isRevealHeader: Bool {
        switch self {
        case .section, .group, .folder, .status: true
        default: false
        }
    }

    /// A row the selection can stand on (a block holds selectable items).
    var isRevealStop: Bool {
        switch self {
        case .workspace, .item, .block: true
        default: false
        }
    }

    var isBlock: Bool { if case .block = self { true } else { false } }
}

extension NSScrollView {
    /// Moves the content to `y`, animated with `Motion.move` (instant under
    /// Reduce Motion or when not `animated`); `moved` runs after each change.
    func scrollContent(toY y: CGFloat, animated: Bool, moved: @escaping @MainActor () -> Void) {
        let clip = contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y)
        if animated, Motion.sidebar.animatesMovement {
            Motion.sidebar.animate(.move, in: clip, { clip.animator().setBoundsOrigin(origin) }, completion: { [weak self] in
                self?.reflectScrolledClipView(clip)
                moved()
            })
        } else {
            clip.setBoundsOrigin(origin)
            reflectScrolledClipView(clip)
        }
        moved()
    }
}
