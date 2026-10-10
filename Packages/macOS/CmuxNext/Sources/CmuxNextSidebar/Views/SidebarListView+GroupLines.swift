import AppKit
import CmuxNextDesign

/// One open group's members' line in list coordinates (cx-qno.17).
struct SidebarGroupLine: Equatable {
    var group: GroupID
    var frame: CGRect
    var color: GroupColor
}

// The members' line (the Chrome tab group line): ONE layer per open group in
// the decoration view under the rows, from under the header bar to the end
// of the last member row. Per-row pieces left gaps at the row spacing and
// under the header (cx-qno.17 proof), so the line is drawn per group.
extension SidebarListView {
    /// Every open group with shown members: its line from the header's
    /// middle (the opaque header bar covers the top) to the last member
    /// row's bottom, rounded off just above it.
    func groupLines(_ layout: SidebarLayout) -> [SidebarGroupLine] {
        var headers: [(GroupID, SidebarRow)] = []
        var last: [GroupID: SidebarRow] = [:]
        for row in layout.rows {
            switch row.key {
            case let .group(id): headers.append((id, row))
            case .workspace, .tab: if let group = row.group { last[group] = row }
            default: break
            }
        }
        let width = SidebarStyle.groupBarWidth
        return headers.compactMap { id, header in
            guard !header.isCollapsed, let end = last[id], end.y > header.y else { return nil }
            let top = header.y + header.height / 2
            let bottom = end.maxY - Metrics.space2
            guard bottom > top else { return nil }
            return SidebarGroupLine(group: id, frame: CGRect(x: inset + SidebarStyle.groupBarX, y: top, width: width, height: bottom - top),
                                    color: groups[id]?.color ?? end.groupColor ?? .grey)
        }
    }
}
