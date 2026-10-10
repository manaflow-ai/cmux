import CoreGraphics

/// Where a row that appears or leaves travels from or to. A collapse folds
/// rows under the header that hides them (Dia): the header stays put, a
/// collapsing group's, section's or workspace's rows slide up beneath it,
/// and an expand brings them back out from under it. Any other row that
/// appears or leaves (a new or closed workspace, tab or group) opens or
/// closes its slot in place, like a browser's vertical tabs (cx-bqm6, cx-ai79).
nonisolated enum SidebarRowTransition {
    /// Where an inserted row (a row of `new` that `old` lacks) starts: under
    /// the header that unfolds it at full height, or else at the top of its
    /// run of inserted rows at zero height (cx-ai79). A run (a workspace and
    /// its tab rows, a group header) opens as one slot: each row's top tracks
    /// the rows above it in the run, so none overlaps a row still sliding down.
    static func insertFrame(_ row: SidebarRow, target: CGRect, runTop: CGFloat?, from old: SidebarLayout, to new: SidebarLayout) -> CGRect {
        if let header = foldingHeader(of: row, open: new, closed: old, placedIn: new) {
            return CGRect(x: target.minX, y: header.y, width: target.width, height: target.height)
        }
        return CGRect(x: target.minX, y: runTop ?? target.minY, width: target.width, height: 0)
    }

    /// Where a removed row (a row of `old` that `new` lacks) ends: under the
    /// header that folds it, or else at the top of its run of removed rows at
    /// zero height, so the rows below close the gap on the same spring.
    static func removeFrame(_ row: SidebarRow, current: CGRect, runTop: CGFloat?, from old: SidebarLayout, to new: SidebarLayout) -> CGRect {
        if let y = foldedY(row, from: old, to: new) {
            return CGRect(x: current.minX, y: y, width: current.width, height: current.height)
        }
        return CGRect(x: current.minX, y: runTop ?? current.minY, width: current.width, height: 0)
    }

    /// Each row of `layout` that `other` lacks, keyed to the y of the first
    /// row of its run (consecutive such rows), in `layout`'s coordinates.
    static func runTops(of layout: SidebarLayout, missingFrom other: SidebarLayout) -> [SidebarRowKey: CGFloat] {
        var tops: [SidebarRowKey: CGFloat] = [:]
        var top: CGFloat?
        for row in layout.rows {
            guard other.row(for: row.key) == nil else { top = nil; continue }
            let start = top ?? row.y
            top = start
            tops[row.key] = start
        }
        return tops
    }

    /// The y of the header `row` (a row of `old` that `new` lacks) folds
    /// under, or nil when no collapse hides it.
    static func foldedY(_ row: SidebarRow, from old: SidebarLayout, to new: SidebarLayout) -> CGFloat? {
        foldingHeader(of: row, open: old, closed: new, placedIn: new)?.y
    }

    /// The nearest header that shows `row` in `open` and hides it in
    /// `closed`, as it sits in `placedIn`: its workspace (inline tabs), then
    /// its group, then its section.
    private static func foldingHeader(of row: SidebarRow, open: SidebarLayout, closed: SidebarLayout,
                                      placedIn layout: SidebarLayout) -> SidebarRow? {
        var headers: [SidebarRowKey] = []
        if case let .tab(workspace, _) = row.key { headers.append(.workspace(workspace)) }
        if let group = row.group, row.key != .group(group) { headers.append(.group(group)) }
        if row.key != .section(row.section) { headers.append(.section(row.section)) }
        for key in headers {
            guard let shown = open.row(for: key), let hidden = closed.row(for: key) else { continue }
            if isFolded(hidden) && !isFolded(shown) { return layout.row(for: key) }
        }
        return nil
    }

    private static func isFolded(_ header: SidebarRow) -> Bool {
        if case .workspace = header.key { return header.tabDisclosure == .collapsed }
        return header.isCollapsed
    }
}
