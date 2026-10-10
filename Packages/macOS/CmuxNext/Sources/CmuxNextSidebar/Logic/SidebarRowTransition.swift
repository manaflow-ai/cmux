import CoreGraphics

/// Where a row that appears or leaves travels from or to. A collapse folds
/// rows under the header that hides them (Dia): the header stays put, a
/// collapsing group's, section's or workspace's rows slide up beneath it,
/// and an expand brings them back out from under it. Any other row that
/// appears or leaves (a new or closed workspace, tab or group) opens or
/// closes its own slot in place, like a browser's vertical tabs (cx-bqm6).
nonisolated enum SidebarRowTransition {
    /// Where an inserted row (a row of `new` that `old` lacks) starts: under
    /// the header that unfolds it at full height, or else its own slot at
    /// zero height, so it grows in place while its siblings make room.
    static func insertFrame(_ row: SidebarRow, target: CGRect, from old: SidebarLayout, to new: SidebarLayout) -> CGRect {
        if let header = foldingHeader(of: row, open: new, closed: old, placedIn: new) {
            return CGRect(x: target.minX, y: header.y, width: target.width, height: target.height)
        }
        return CGRect(x: target.minX, y: target.minY, width: target.width, height: 0)
    }

    /// Where a removed row (a row of `old` that `new` lacks) ends: under the
    /// header that folds it, or else its own slot shrunk to zero height, so
    /// the rows below close the gap on the same spring.
    static func removeFrame(_ row: SidebarRow, current: CGRect, from old: SidebarLayout, to new: SidebarLayout) -> CGRect {
        if let y = foldedY(row, from: old, to: new) {
            return CGRect(x: current.minX, y: y, width: current.width, height: current.height)
        }
        return CGRect(x: current.minX, y: current.minY, width: current.width, height: 0)
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
