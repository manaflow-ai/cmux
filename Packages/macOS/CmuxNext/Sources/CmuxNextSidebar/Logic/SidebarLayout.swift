public import CoreGraphics
import Foundation

/// Flattened sidebar: rows with frames, plus the live gap when dragging.
public nonisolated struct SidebarLayout: Hashable, Sendable {
    public var rows: [SidebarRow]
    public var totalHeight: CGFloat
    /// Top of the open gap, if any.
    public var gapY: CGFloat?
    /// Height of the visible gap placeholder.
    public var gapHeight: CGFloat
    /// How far the gap pushes following rows down (height plus spacing).
    /// Pass this to `DropResolver.baseY(forDisplayY:gapY:gapHeight:)`.
    public var gapShift: CGFloat

    public func row(for key: SidebarRowKey) -> SidebarRow? { rows.first { $0.key == key } }

    /// Row whose frame contains `y`, or nil in a gap or padding.
    public func row(at y: CGFloat) -> SidebarRow? { rows.first { y >= $0.y && y < $0.maxY } }

    public static func make(
        sections: [SidebarSection],
        metrics m: SidebarLayoutMetrics,
        options o: SidebarLayoutOptions = SidebarLayoutOptions()
    ) -> SidebarLayout {
        var rows: [SidebarRow] = []
        var y = m.topPadding
        var gapY: CGFloat?
        let filtering = o.filterMatches != nil

        func visible(_ ws: SidebarWorkspace) -> Bool {
            !o.excludedWorkspaces.contains(ws.id) && (o.filterMatches?.contains(ws.id) ?? true)
        }

        func openGapIfNeeded(section: SectionID, group: GroupID?, index: Int) {
            guard gapY == nil, let gap = o.gap, gap.section == section, gap.group == group, gap.index == index else { return }
            gapY = y
            y += o.gapHeight + m.rowSpacing
        }

        var firstSection = true
        for section in sections {
            // Nodes that remain, with their visible children.
            var nodes: [(node: SidebarNode, children: [SidebarWorkspace])] = []
            for node in section.nodes {
                switch node {
                case let .workspace(ws):
                    if visible(ws) { nodes.append((node, [ws])) }
                case let .group(group):
                    if group.id == o.excludedGroup { continue }
                    let children = group.workspaces.filter(visible)
                    // A group emptied by the drag keeps its header (it is a
                    // valid target); a group emptied by the filter hides.
                    if filtering && children.isEmpty { continue }
                    nodes.append((node, children))
                }
            }

            let isPinned = section.id == .pinned
            let gapHere = o.gap?.section == section.id
            if nodes.isEmpty && filtering { continue }
            if isPinned && nodes.isEmpty && !o.showEmptyPinned && !gapHere { continue }

            if !firstSection { y += m.sectionSpacing }
            firstSection = false
            let collapsed = section.isCollapsed && !filtering
            rows.append(SidebarRow(
                key: .section(section.id), y: y, height: m.sectionHeaderHeight, section: section.id,
                group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                isCollapsed: collapsed, childCount: nodes.count, groupColor: nil
            ))
            y += m.sectionHeaderHeight + m.rowSpacing
            if collapsed { continue }

            if nodes.isEmpty {
                if gapHere {
                    openGapIfNeeded(section: section.id, group: nil, index: 0)
                } else {
                    rows.append(SidebarRow(
                        key: .emptySection(section.id), y: y, height: m.emptySectionHeight, section: section.id,
                        group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil
                    ))
                    y += m.emptySectionHeight + m.rowSpacing
                }
                continue
            }

            for (index, entry) in nodes.enumerated() {
                openGapIfNeeded(section: section.id, group: nil, index: index)
                switch entry.node {
                case let .workspace(ws):
                    let h = m.height(for: ws)
                    rows.append(SidebarRow(
                        key: .workspace(ws.id), y: y, height: h, section: section.id,
                        group: nil, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil
                    ))
                    y += h + m.rowSpacing
                case let .group(group):
                    let groupCollapsed = group.isCollapsed && !filtering
                    rows.append(SidebarRow(
                        key: .group(group.id), y: y, height: m.groupHeaderHeight, section: section.id,
                        group: group.id, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: groupCollapsed, childCount: entry.children.count, groupColor: group.color
                    ))
                    y += m.groupHeaderHeight + m.rowSpacing
                    guard !groupCollapsed else { continue }
                    for (childIndex, ws) in entry.children.enumerated() {
                        openGapIfNeeded(section: section.id, group: group.id, index: childIndex)
                        let h = m.height(for: ws)
                        rows.append(SidebarRow(
                            key: .workspace(ws.id), y: y, height: h, section: section.id,
                            group: group.id, siblingIndex: childIndex, parentIndex: index,
                            isLastInGroup: childIndex == entry.children.count - 1,
                            isCollapsed: false, childCount: 0, groupColor: group.color
                        ))
                        y += h + m.rowSpacing
                    }
                    openGapIfNeeded(section: section.id, group: group.id, index: entry.children.count)
                    y += m.groupBottomPadding
                }
            }
            openGapIfNeeded(section: section.id, group: nil, index: nodes.count)
        }
        y += m.bottomPadding
        return SidebarLayout(
            rows: rows, totalHeight: y, gapY: gapY,
            gapHeight: gapY == nil ? 0 : o.gapHeight,
            gapShift: gapY == nil ? 0 : o.gapHeight + m.rowSpacing
        )
    }
}
