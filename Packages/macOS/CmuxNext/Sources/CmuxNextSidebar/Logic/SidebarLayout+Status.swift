import CoreGraphics
import Foundation

/// Group by Status (Debug `sidebar.groupByStatus`, off by default): every computer's rows, Chrome groups dissolved,
/// under the Priority view's states (`SidebarStatusSection`), each in manual order. A header names its section and
/// count; a folded section keeps the count (Needs you never folds). Rows move as their state changes, except the
/// active row (`SidebarGrouping.held`). The list draws every row of a section: the Done fold (`SidebarLayout+DoneFold`,
/// `sidebar.doneFold`) and Show more (`sidebar.groupRowLimit`) do not apply inside status sections, so a workspace marked
/// Done shows under its state and a long section lists every row.
nonisolated extension SidebarLayout {
    /// The rows of `sections`' computers (the pinned area and the document's sections lay out as before), from `y`;
    /// `spacing` goes above them: the section spacing, the row spacing under a block, or none.
    static func statusRows(
        _ sections: [SidebarSection], spacing: CGFloat, chats: inout SidebarChatHistoryPlacement,
        options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics, y: inout CGFloat
    ) -> [SidebarRow] {
        let machines = sections.filter { $0.machine != nil }
        guard let first = machines.first else { return [] }
        y += spacing
        chats.placePinned(&y)
        var members: [SidebarStatusSection: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)]] = [:]
        for section in machines {
            for (index, node) in section.nodes.enumerated() {
                let workspaces: [SidebarWorkspace] = switch node {
                case let .workspace(ws): [ws]
                case let .group(group): group.workspaces
                case .item: []
                }
                for ws in workspaces where o.visible(ws) {
                    members[o.grouping.section(ws), default: []].append((ws, section, index))
                }
            }
        }
        var rows: [SidebarRow] = []
        for status in SidebarStatusSection.allCases {
            guard let listed = members[status] else { continue }
            let collapsed = status.collapses && o.grouping.collapsed.contains(status)
            rows.append(SidebarRow(
                key: .status(status), y: y, height: m.groupHeaderHeight, section: first.id,
                group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                isCollapsed: collapsed, childCount: listed.count, groupColor: nil
            ))
            y += m.groupHeaderHeight + m.rowSpacing
            if collapsed { continue }
            for member in listed {
                let content = o.rowContent(member.ws, machine: machineLabel(member.section, options: o))
                let h = m.height(for: content)
                rows.append(SidebarRow(
                    key: .workspace(member.ws.id), y: y, height: h, section: member.section.id,
                    group: nil, siblingIndex: member.index, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: false, childCount: 0, groupColor: nil,
                    tabDisclosure: o.disclosure(member.ws), content: content
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
            // The next status group follows the last member by the row spacing alone (Leo 2026-10-21: no padding after groups).
        }
        return rows
    }
}

nonisolated extension SidebarLayoutOptions {
    /// Group by Folder (`SidebarGrouping.groupsByFolder`): never while Group by Status is on.
    public var groupsByFolder: Bool { grouping.groupsByFolder }
}
