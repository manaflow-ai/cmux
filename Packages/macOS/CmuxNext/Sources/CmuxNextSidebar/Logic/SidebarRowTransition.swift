import CoreGraphics

/// Where a row that appears or leaves travels from or to. A collapse folds
/// rows under the header that hides them (Dia): the header stays put, a
/// collapsing group's, section's or workspace's rows slide up beneath it,
/// and an expand brings them back out from under it. Any other row that
/// appears or leaves (a new or closed workspace) keeps the small drop-in.
nonisolated enum SidebarRowTransition {
    /// The y `row` (a row of `new` that `old` lacks) starts at.
    static func appearY(_ row: SidebarRow, from old: SidebarLayout, to new: SidebarLayout, dropIn: CGFloat) -> CGFloat {
        foldingHeader(of: row, open: new, closed: old, placedIn: new)?.y ?? row.y - dropIn
    }

    /// The y `row` (a row of `old` that `new` lacks) ends at.
    static func leaveY(_ row: SidebarRow, from old: SidebarLayout, to new: SidebarLayout, dropIn: CGFloat) -> CGFloat {
        foldedY(row, from: old, to: new) ?? row.y - dropIn
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
