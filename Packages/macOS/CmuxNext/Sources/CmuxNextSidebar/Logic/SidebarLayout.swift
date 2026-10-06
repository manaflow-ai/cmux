public import CoreGraphics
import Foundation

/// Flattened sidebar: rows with frames, plus the live gap when dragging.
public nonisolated struct SidebarLayout: Hashable, Sendable {
    public private(set) var rows: [SidebarRow]
    /// Key to row index, so lookups stay O(1) with 1,000 workspaces.
    private var index: [SidebarRowKey: Int]
    public var totalHeight: CGFloat
    /// Top of the open gap, if any.
    public var gapY: CGFloat?
    /// Height of the visible gap placeholder.
    public var gapHeight: CGFloat
    /// How far the gap pushes following rows down (height plus spacing).
    /// Pass this to `DropResolver.baseY(forDisplayY:gapY:gapHeight:)`.
    public var gapShift: CGFloat

    public init(rows: [SidebarRow], totalHeight: CGFloat, gapY: CGFloat?, gapHeight: CGFloat, gapShift: CGFloat) {
        self.rows = rows
        self.totalHeight = totalHeight
        self.gapY = gapY
        self.gapHeight = gapHeight
        self.gapShift = gapShift
        var index: [SidebarRowKey: Int] = [:]
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() { index[row.key] = i }
        self.index = index
    }

    public static let empty = SidebarLayout(rows: [], totalHeight: 0, gapY: nil, gapHeight: 0, gapShift: 0)

    public func row(for key: SidebarRowKey) -> SidebarRow? { index[key].map { rows[$0] } }

    /// Row whose frame contains `y`, or nil in a gap or padding.
    public func row(at y: CGFloat) -> SidebarRow? {
        guard let i = lastIndex(startingAtOrBefore: y) else { return nil }
        return y < rows[i].maxY ? rows[i] : nil
    }

    /// Index of the last row whose top is at or above `y` (rows are sorted
    /// by y). Binary search keeps hit testing O(log n).
    func lastIndex(startingAtOrBefore y: CGFloat) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].y <= y { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    public static func make(
        sections: [SidebarSection],
        metrics m: SidebarLayoutMetrics,
        options o: SidebarLayoutOptions = SidebarLayoutOptions()
    ) -> SidebarLayout {
        var rows: [SidebarRow] = []
        var y = m.topPadding
        var gapY: CGFloat?
        let filtering = o.filterMatches != nil
        // One machine needs no machine header: its name adds nothing.
        let machineCount = sections.reduce(0) { $0 + ($1.machine == nil ? 0 : 1) }

        func visible(_ ws: SidebarWorkspace) -> Bool {
            !o.excludedWorkspaces.contains(ws.id) && (o.filterMatches?.contains(ws.id) ?? true)
        }

        // `showWorkspaceTabs` lists every workspace's tabs, except those
        // the user collapsed with the row's disclosure.
        func listsTabs(_ ws: SidebarWorkspace) -> Bool {
            o.showWorkspaceTabs && !o.collapsedWorkspaces.contains(ws.id)
        }

        func disclosure(_ ws: SidebarWorkspace) -> SidebarTabDisclosure? {
            guard o.showWorkspaceTabs else { return nil }
            if ws.tabs.isEmpty { return .empty }
            return o.collapsedWorkspaces.contains(ws.id) ? .collapsed : .expanded
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
            let showsHeader = section.machine == nil || machineCount > 1 || o.showsSoleMachineHeader
            // Without a header there is nothing to expand it from.
            let collapsed = showsHeader && section.isCollapsed && !filtering
            if showsHeader {
                rows.append(SidebarRow(
                    key: .section(section.id), y: y, height: m.sectionHeaderHeight, section: section.id,
                    group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: collapsed, childCount: nodes.count, groupColor: nil,
                    titlesProjects: section.machine != nil && machineCount == 1
                ))
                y += m.sectionHeaderHeight + m.rowSpacing
            }
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
                        isCollapsed: false, childCount: 0, groupColor: nil,
                        tabDisclosure: disclosure(ws), tabCount: o.showCounts ? ws.tabs.count : nil
                    ))
                    y += h + m.rowSpacing
                    if listsTabs(ws) {
                        for tab in ws.tabs {
                            rows.append(SidebarRow(
                                key: .tab(ws.id, tab.id), y: y, height: m.tabRowHeight, section: section.id,
                                group: nil, workspace: ws.id, siblingIndex: 0, parentIndex: nil,
                                isLastInGroup: false, isCollapsed: false, childCount: 0,
                                groupColor: nil, tabKind: tab.kind
                            ))
                            y += m.tabRowHeight + m.rowSpacing
                        }
                    }
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
                            isCollapsed: false, childCount: 0, groupColor: group.color,
                            tabDisclosure: disclosure(ws), tabCount: o.showCounts ? ws.tabs.count : nil
                        ))
                        y += h + m.rowSpacing
                        if listsTabs(ws) {
                            for tab in ws.tabs {
                                rows.append(SidebarRow(
                                    key: .tab(ws.id, tab.id), y: y, height: m.tabRowHeight, section: section.id,
                                    group: group.id, workspace: ws.id, siblingIndex: childIndex, parentIndex: index,
                                    isLastInGroup: false, isCollapsed: false, childCount: 0,
                                    groupColor: group.color, tabKind: tab.kind
                                ))
                                y += m.tabRowHeight + m.rowSpacing
                            }
                        }
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
