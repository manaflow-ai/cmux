import AppKit
import CmuxNextDesign

/// One open group's members' line (cx-qno.17), in the coordinates of the
/// row frames it was computed from.
struct SidebarGroupLine: Equatable {
    var group: GroupID
    var frame: CGRect
    var color: GroupColor
}

// The members' line (the Chrome tab group line): ONE view per open group
// under the rows (SidebarGroupLineViews), from under the header bar to the
// end of the last member row. Per-row pieces left gaps at the row spacing and
// under the header (cx-qno.17 proof), so the line is drawn per group.
extension SidebarListView {
    /// The list's lines. Rows a drag hides (`suppressed`) have none: a lifted
    /// group's line goes with its card (SidebarListLift).
    func groupLines(_ layout: SidebarLayout) -> [SidebarGroupLine] {
        SidebarGroupLine.lines(layout.rows.filter { !suppressed.contains($0.key) }, colors: groups) { frame(for: $0) }
    }
}

extension SidebarGroupLine {
    /// Every open group in `rows` with shown members: its line from the
    /// header's middle (the opaque header bar covers the top) to the last
    /// member row's bottom, rounded off just above it, in the members'
    /// gutter (`SidebarStyle.groupGutter`), so no row fill covers it
    /// (cx-q5jw: straight and unbroken, Edge style). `frame` places a row.
    static func lines(_ rows: [SidebarRow], colors: [GroupID: SidebarGroup], frame: (SidebarRow) -> CGRect) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        for row in rows {
            switch row.key {
            case let .group(id): headers.append((id, row))
            case .workspace, .tab: if let group = row.group { last[group] = row }
            default: break
            }
        }
        let width = SidebarStyle.groupBarWidth
        return headers.compactMap { id, header in
            guard !header.isCollapsed, let end = last[id], end.y > header.y else { return nil }
            let head = frame(header), tail = frame(end)
            let top = head.midY, bottom = tail.maxY - Metrics.space1
            guard bottom > top else { return nil }
            return SidebarGroupLine(group: id, frame: CGRect(x: head.minX + SidebarStyle.groupBarX, y: top, width: width, height: bottom - top),
                                    color: colors[id]?.color ?? end.groupColor ?? .grey)
        }
    }
}
