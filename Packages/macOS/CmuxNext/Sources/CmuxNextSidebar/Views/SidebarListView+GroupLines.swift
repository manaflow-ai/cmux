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
    /// Joined (`groupLineJoinsHeader`), the list draws no line views: each header draws its line
    /// as part of its bar (`joinHeaders`).
    func groupLines(_ layout: SidebarLayout, current: Bool = false) -> [SidebarGroupLine] {
        guard !groupLineJoinsHeader else { return [] }
        return SidebarGroupLine.lines(layout.rows.filter { !suppressed.contains($0.key) }, colors: groups, joined: false) { row in
            current ? rowViews[row.key]?.frame ?? frame(for: row) : frame(for: row)
        }
    }

    /// The list's lines for `layout`, from `start` (`SidebarGroupLineViews.update`), and the joined headers' lines.
    func updateGroupLines(_ layout: SidebarLayout, from start: [SidebarGroupLine], animated: Bool) -> (changes: () -> Void, leaving: [NSView]) {
        joinHeaders(layout)
        return groupLineViews.update(groupLines(layout), from: start, in: self, below: decorations, animated: animated)
    }

    /// Joined, how far each open group's header draws its line below its bar, kept for headers
    /// configured later (`configure`) and handed to the headers on screen now; else none.
    func joinHeaders(_ layout: SidebarLayout) {
        let lines = groupLineJoinsHeader
            ? SidebarGroupLine.lines(layout.rows.filter { !suppressed.contains($0.key) }, colors: groups, joined: true, frame: frame(for:)) : []
        joinedLineLengths = Dictionary(lines.map { ($0.group, $0.frame.height) }, uniquingKeysWith: { first, _ in first })
        for case (.group(let id), let header as GroupHeaderRowView) in rowViews.map({ ($0.key, $0.value) }) {
            header.joinedLineLength = joinedLineLengths[id] ?? 0
        }
    }
}

extension SidebarGroupLine {
    /// Every open group in `rows` with shown members: its line from the
    /// header bar to the last member row's bottom, in the members' gutter
    /// (`SidebarStyle.groupGutter`), so no row fill covers it (cx-q5jw:
    /// straight and unbroken), its ends trimmed as Chrome's
    /// (`SidebarGroupLineShape`). By default it follows Leo's Chrome
    /// reference (2026-10-19): a small cut below the bar
    /// (`SidebarStyle.groupLineCut`), its right edge where the bar's corner
    /// arc ends. `joined` (`sidebar.groupLineJoinsHeader`) starts it at the
    /// bar's edge, at the bar's own left edge: the header draws it as part
    /// of its bar, one outline. `frame` places a row.
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
            // Joined, the line starts at the bar's edge: the header draws it as part of its bar.
            let top = joined ? barEdge : barEdge + SidebarStyle.groupLineCut, bottom = tail.maxY
            guard bottom - top >= 2 * width else { return nil }
            let x = head.minX + (joined ? 0 : SidebarStyle.groupBarX)
            return SidebarGroupLine(group: id, frame: CGRect(x: x, y: top, width: width, height: bottom - top),
                                    color: colors[id]?.tint ?? .palette(end.groupColor ?? .grey))
        }
    }
}
