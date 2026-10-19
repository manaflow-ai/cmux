import AppKit
import CmuxNextDesign

/// One open group's members' line (cx-qno.17), in the coordinates of the
/// row frames it was computed from.
struct SidebarGroupLine: Equatable {
    var group: GroupID
    var frame: CGRect
    var color: GroupTint
}

// The members' line (the Chrome tab group line): ONE view per open group
// under the rows (SidebarGroupLineViews), from just below the header bar (or
// joined to it) to the end of the last member row. Per-row pieces left gaps at the row spacing and
// under the header (cx-qno.17 proof), so the line is drawn per group.
extension SidebarListViewComponents {
    /// The list's lines. Rows a drag hides (`suppressed`) have none: a lifted
    /// group's line goes with its card (SidebarListLift). `current` places
    /// each row where its view is now, the animation's start, so a new line
    /// starts over its rows and moves with them (cx-ai79).
    func groupLines(_ layout: SidebarLayout, current: Bool = false) -> [SidebarGroupLine] {
        SidebarGroupLine.lines(layout.rows.filter { !suppressed.contains($0.key) }, colors: groups, joined: groupLineJoinsHeader) { row in
            current ? rowViews[row.key]?.frame ?? frame(for: row) : frame(for: row)
        }
    }
}

extension SidebarGroupLine {
    /// Every open group in `rows` with shown members: its line from the
    /// header bar to the last member row's bottom, rounded off just above
    /// it, in the members' gutter (`SidebarStyle.groupGutter`), so no row
    /// fill covers it (cx-q5jw: straight and unbroken, Edge style).
    /// By default the line starts a small, deliberate cut below the bar
    /// (`SidebarStyle.groupLineCut`), its top end round, as Chrome's tab
    /// groups do (Leo 2026-10-19). `joined` (`sidebar.groupLineJoinsHeader`)
    /// runs it into the bar as one shape: only its round top end tucks into
    /// the bar, half its width, so the bar's rounded corner shows no seam
    /// (cg-design-judge 2026-10-14 saw one when the line started at the
    /// bar's middle). `frame` places a row.
    static func lines(_ rows: [SidebarRow], colors: [GroupID: SidebarGroup], joined: Bool,
                      frame: (SidebarRow) -> CGRect) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        for row in rows {
            switch row.key {
            case let .group(id): headers.append((id, row))
            case .workspace, .tab, .item: if let group = row.group { last[group] = row }
            default: break
            }
        }
        let width = SidebarStyle.groupBarWidth
        return headers.compactMap { id, header in
            guard !header.isCollapsed, let end = last[id], end.y > header.y else { return nil }
            let head = frame(header), tail = frame(end)
            let bar = SidebarStyle.groupHeaderBarHeight(rowHeight: head.height)
            let barEdge = head.midY + bar / 2
            let top = joined ? barEdge - width / 2 : barEdge + SidebarStyle.groupLineCut, bottom = tail.maxY - Metrics.space1
            guard bottom > top else { return nil }
            return SidebarGroupLine(group: id, frame: CGRect(x: head.minX + SidebarStyle.groupBarX, y: top, width: width, height: bottom - top),
                                    color: colors[id]?.tint ?? .palette(end.groupColor ?? .grey))
        }
    }
}
