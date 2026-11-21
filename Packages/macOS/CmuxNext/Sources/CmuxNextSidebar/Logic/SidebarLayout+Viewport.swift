import AppKit
import CmuxNextDesign

extension SidebarLayout {
    /// Space kept around a revealed active row (close-focus.md).
    static let revealPadding: CGFloat = 8

    /// The list's extent as `ListViewport` sees it in a viewport `height` tall, with no row: `clamp`, `reveal` and
    /// `isFullyVisible` read the viewport and the content only. The rules that read rows take them from the layout
    /// itself (`viewportChange`), the rows in view, never a copy of every row.
    func viewportFrame(height: CGFloat) -> ListViewport<SidebarRowKey> {
        ListViewport(items: [], viewport: height, content: max(totalHeight, height))
    }

    /// The scroll rules for the list's change from this layout to `next` in a viewport `height` tall
    /// (`ListViewportChange`): the anchor, the settle and a row's own move, read from the rows in view.
    func viewportChange(to next: SidebarLayout, height: CGFloat) -> ListViewportChange<SidebarLayoutViewportRows, SidebarLayoutViewportRows> {
        ListViewportChange(from: SidebarLayoutViewportRows(layout: self), content: max(totalHeight, height), viewport: height,
                           to: SidebarLayoutViewportRows(layout: next), content: max(next.totalHeight, height), viewport: height)
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
        // A collapsed group is a stop of its own, not a header: only the selection's own group titles it.
        while above >= 0, rows[above].key.isRevealHeader, !rows[above].isWorkspaceStop || rows[above].group == row.group {
            lead = rows[above].y
            above -= 1
        }
        // Only top items (blocks, link rows) or headers above: the list's top padding, its top items and any
        // header belong to the first stop (`SidebarItemOrder.revealsTop`: Cmd-1 to Home or the first workspace).
        if !rows[..<index].contains(where: \.isWorkspaceStop) { lead = 0 }
        let trail = rows[(index + 1)...].contains(where: { $0.key.isRevealStop || $0.isWorkspaceStop }) ? end : max(totalHeight, end)
        let fits = { (lead: CGFloat, trail: CGFloat) in trail - lead + Self.revealPadding * 2 <= height }
        let (l, t) = fits(lead, trail) ? (lead, trail) : fits(lead, end) ? (lead, end) : (start, end)
        return .init(id: id, start: l, length: t - l)
    }
}

/// A layout's rows as the scroll rules read them (`ListViewportRows`). The rows of a layout with no drag gap are
/// sorted by `y` and do not overlap (hit testing searches them the same way,
/// `SidebarLayout.lastIndex(startingAtOrBefore:)`), so the rows in a span are found by a search. A layout with a drag
/// gap (`gapY`) can be a group drag's (`SidebarGroupDragPlan.layout`): its carried rows stand one over the other at
/// the card's bottom, a tall one above a short one, so they are not in order of place and every row is read, as the
/// rule did before. The list gives such a layout to the rule in one reload only, the first after a drop or a cancel
/// (`applyKeepingViewport` runs with no drag held). Each row read counts in `viewport_rows`.
nonisolated struct SidebarLayoutViewportRows: ListViewportRows {
    let layout: SidebarLayout

    var rowCount: Int { layout.rows.count }

    func viewportRow(at position: Int) -> ListViewport<SidebarRowKey>.Item {
        SidebarPerfCounters.addViewportRows(1)
        let row = layout.rows[position]
        return .init(id: row.key, start: row.y, length: row.height)
    }

    func viewportPosition(of id: SidebarRowKey) -> Int? { layout.position(of: id) }

    // perf-hot: 0.1ms workspace-list-change
    func viewportPositions(endingAfter lower: CGFloat, startingBefore upper: CGFloat) -> [Int] {
        let rows = layout.rows
        guard layout.gapY == nil else {
            SidebarPerfCounters.addViewportRows(rows.count)
            return rows.indices.filter { rows[$0].maxY > lower && rows[$0].y < upper }
        }
        // The first row that ends after `lower`: the last one that starts at or before it, and any row before that
        // one that still ends after `lower` (none while rows do not overlap).
        var first = layout.lastIndex(startingAtOrBefore: lower).map { $0 + 1 } ?? 0
        while first > 0, rows[first - 1].maxY > lower { first -= 1 }
        var positions: [Int] = []
        var index = first
        while index < rows.count, rows[index].y < upper {
            if rows[index].maxY > lower { positions.append(index) }
            index += 1
        }
        SidebarPerfCounters.addViewportRows(index - first)
        return positions
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
        case .section, .group, .folder, .status, .listHeader: true
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
        if animated, Motion.sidebar.animatesMovement(in: window) {
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
