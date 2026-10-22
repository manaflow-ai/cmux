import AppKit
import CmuxNextDesign

// The nested-groups prototype's drop indicator: "inside" outlines the group block a drop joins,
// "between" draws a line at the x of the level the drop lands at (`SidebarIndent`).
extension SidebarListViewComponents {
    /// The mark for a drop into `group`: its header and every row of its subtree, as drawn.
    func nestedDropMark(into group: GroupID) -> SidebarNestedDropIndicatorView.Mark? {
        guard let header = displayed.row(for: .group(group)) else { return nil }
        var frame = self.frame(for: header)
        for row in displayed.rows where row.y > header.y {
            guard let owner = row.group else { break }
            let inside = owner == group || groups[owner].map { Self.isNested($0, under: group, in: groups) } == true
            guard inside else { break }
            frame = frame.union(self.frame(for: row))
        }
        let color = groups[group].map { SidebarStyle.color($0.color) } ?? .controlAccentColor
        return .into(frame: frame.insetBy(dx: -2, dy: -2), color: color)
    }

    /// The mark for a drop right below (`after`) or above `key`'s row, landing at `level`.
    func nestedDropMark(beside key: SidebarRowKey, after: Bool, level: Int) -> SidebarNestedDropIndicatorView.Mark? {
        guard let row = displayed.row(for: key) else { return nil }
        let rowFrame = frame(for: row)
        let y = after ? rowFrame.maxY + metrics.rowSpacing / 2 : rowFrame.minY - metrics.rowSpacing / 2
        let x = inset + indent.offset(level: level, width: indentWidth)
        let width = max(0, bounds.width - inset - SidebarStyle.rowTrailingTrim - x)
        return .between(origin: CGPoint(x: x, y: y), width: width, color: .controlAccentColor)
    }

    /// Shows `mark` over the rows, or hides the indicator.
    func showNestedDrop(_ mark: SidebarNestedDropIndicatorView.Mark?) {
        guard let mark else {
            nestedDropIndicator?.mark = nil
            return
        }
        let view = nestedDropIndicator ?? {
            let view = SidebarNestedDropIndicatorView()
            nestedDropIndicator = view
            return view
        }()
        if view.superview !== self { addSubview(view, positioned: .above, relativeTo: nil) }
        view.frame = bounds
        view.mark = mark
    }

    /// The mark for a document drag's hit (`SidebarDragGeometry`): inside, or between at its level.
    func nestedDropMark(_ hit: SidebarDragGeometry.Hit, geometry: SidebarDragGeometry, rows: [String: SidebarRow]) -> SidebarNestedDropIndicatorView.Mark? {
        guard hit.target != nil, let row = rows[hit.slot.key] else { return nil }
        if hit.zone == .into, case let .group(group) = row.key { return nestedDropMark(into: group) }
        return nestedDropMark(beside: row.key, after: hit.zone != .before, level: geometry.dropLevel(hit))
    }
}

#if DEBUG
extension SidebarListViewComponents {
    /// The y a capture puts the lifted card at: just over the drop the fixture names.
    func nestedDropY(_ fixture: SidebarNestedFixture) -> CGFloat? {
        switch fixture.drop {
        case let .into(group)?: displayed.row(for: .group(group)).map { frame(for: $0).minY }
        case let .after(workspace, _)?: displayed.row(for: .workspace(workspace)).map { frame(for: $0).maxY }
        case nil: nil
        }
    }
}
#endif
