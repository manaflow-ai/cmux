import CoreGraphics

// Sticky project headers (Leo, 2026-11-10, on the one scroll area: "you also don't want to make a, like a scrollable area
// within a scrollable area"): while the list scrolls through an open top-level group whose header went above the visible
// top, the header stays pinned there until the group's last row passes, then the row after the group pushes it up (the
// iOS and Finder section header). The list draws it (`SidebarListView+StickyHeader`); this is only which one and where.
extension SidebarLayout {
    /// The header that sticks when the visible rows start at `top`, as its index in `rows` and the y it draws at: `top`,
    /// or less while the group's last row pushes it out. `topLevel` names the top-level group a row's group sits in (a
    /// nested group's rows belong to their top-level group; only that header sticks). Nil when the row at `top` is in no
    /// open group, its header is at or below `top` (it draws at its own place), or the group's rows have all passed.
    /// Two binary searches by y and a walk back over the rows that start within the header's height below `top`: the
    /// same cost for a group of 30 rows as for one of 3,000.
    func stuckHeader(at top: CGFloat, topLevel: (GroupID) -> GroupID) -> (position: Int, y: CGFloat)? {
        guard let first = lastIndex(startingAtOrBefore: top), let member = rows[first].group else { return nil }
        let group = topLevel(member)
        guard let position = position(of: .group(group)), position <= first else { return nil }
        let header = rows[position]
        guard header.y < top, !header.isCollapsed else { return nil }
        func inGroup(_ row: SidebarRow) -> Bool { row.group.map { topLevel($0) } == group }
        // The group's last row that starts above the header's bottom edge; a row after it in the group means the group
        // goes on below the header, so nothing pushes it yet.
        var last = lastIndex(startingAtOrBefore: top + header.height) ?? first
        while last > first, !inGroup(rows[last]) { last -= 1 }
        let goesOn = last + 1 < rows.count && inGroup(rows[last + 1])
        let y = goesOn ? top : min(top, rows[last].maxY - header.height)
        return y + header.height > top ? (position, y) : nil
    }
}
