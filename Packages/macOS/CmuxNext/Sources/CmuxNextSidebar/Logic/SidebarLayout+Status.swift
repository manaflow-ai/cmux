import CoreGraphics
import Foundation

/// Group by Status (`sidebar.groupBy` `status`, Labs): every computer's rows, Chrome groups
/// dissolved, under Needs you, Working, Done and No agent (`SidebarStatusBucket`), in list order
/// inside each. A header names its bucket and count; folded buckets keep the count (Needs you
/// never folds). Rows move as their status changes, except the active row (`SidebarGrouping.held`).
nonisolated extension SidebarLayout {
    /// The rows of `sections`' computers (the pinned area lays out as before), from `y`.
    static func statusRows(
        _ sections: [SidebarSection], options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
        visible: (SidebarWorkspace) -> Bool, y: inout CGFloat
    ) -> [SidebarRow] {
        let machines = sections.filter { $0.machine != nil }
        guard let first = machines.first else { return [] }
        var buckets: [SidebarStatusBucket: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)]] = [:]
        for section in machines {
            for (index, node) in section.nodes.enumerated() {
                let members: [SidebarWorkspace] = switch node {
                case let .workspace(ws): [ws]
                case let .group(group): group.workspaces
                }
                for ws in members where visible(ws) {
                    buckets[o.grouping.bucket(ws), default: []].append((ws, section, index))
                }
            }
        }
        var rows: [SidebarRow] = []
        for bucket in SidebarStatusBucket.allCases {
            guard let members = buckets[bucket] else { continue }
            let collapsed = bucket.collapses && o.grouping.collapsed.contains(bucket)
            rows.append(SidebarRow(
                key: .status(bucket), y: y, height: m.groupHeaderHeight, section: first.id,
                group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                isCollapsed: collapsed, childCount: members.count, groupColor: nil
            ))
            y += m.groupHeaderHeight + m.rowSpacing
            if collapsed { continue }
            for member in members {
                let content = o.rowContent(member.ws, machine: machineLabel(member.section, options: o))
                let h = m.height(for: content)
                rows.append(SidebarRow(
                    key: .workspace(member.ws.id), y: y, height: h, section: member.section.id,
                    group: nil, siblingIndex: member.index, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: false, childCount: 0, groupColor: nil,
                    tabDisclosure: o.tabDisclosure(member.ws), content: content,
                    statusMarks: WorkspaceRowStatusMarks(bucket: bucket, activity: member.ws.activity, machine: member.section.machine?.kind)
                ))
                y += h + m.rowSpacing
                guard o.listsTabs(member.ws) else { continue }
                for tab in member.ws.tabs {
                    rows.append(SidebarRow(
                        key: .tab(member.ws.id, tab.id), y: y, height: m.tabRowHeight, section: member.section.id,
                        group: nil, workspace: member.ws.id, siblingIndex: 0, parentIndex: nil,
                        isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil, tabKind: tab.kind
                    ))
                    y += m.tabRowHeight + m.rowSpacing
                }
            }
            y += m.groupBottomPadding
        }
        return rows
    }
}

nonisolated extension SidebarLayoutOptions {
    /// `showWorkspaceTabs` lists every workspace's tabs, except those the user collapsed with the
    /// row's disclosure.
    func listsTabs(_ ws: SidebarWorkspace) -> Bool {
        showWorkspaceTabs && !collapsedWorkspaces.contains(ws.id)
    }

    /// The row's control for its listed tabs, when tabs are listed.
    func tabDisclosure(_ ws: SidebarWorkspace) -> SidebarTabDisclosure? {
        guard showWorkspaceTabs else { return nil }
        if ws.tabs.isEmpty { return .empty }
        return collapsedWorkspaces.contains(ws.id) ? .collapsed : .expanded
    }
}
