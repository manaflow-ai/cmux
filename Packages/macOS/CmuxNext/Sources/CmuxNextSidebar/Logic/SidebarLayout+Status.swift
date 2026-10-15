import CoreGraphics
import Foundation

/// Group by Status (Debug `sidebar.groupByStatus`): every computer's rows, Chrome groups
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
        var members: [Member] = []
        for section in machines {
            for (index, node) in section.nodes.enumerated() {
                let workspaces: [SidebarWorkspace] = switch node {
                case let .workspace(ws): [ws]
                case let .group(group): group.workspaces
                }
                for ws in workspaces where visible(ws) { members.append(Member(ws: ws, section: section, index: index)) }
            }
        }
        let buckets = bucketed(members, options: o)
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
                var content = o.rowContent(member.ws, machine: machineLabel(member.section, options: o))
                content.elbow = member.elbow
                let h = m.height(for: content)
                rows.append(SidebarRow(
                    key: .workspace(member.ws.id), y: y, height: h, section: member.section.id,
                    group: nil, siblingIndex: member.index, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: false, childCount: 0, groupColor: nil,
                    tabDisclosure: o.tabDisclosure(member.ws), content: content,
                    statusMarks: WorkspaceRowStatusMarks(bucket: o.grouping.bucket(member.ws), activity: member.ws.activity, machine: member.section.machine?.kind)
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

/// Elbow children (`SidebarGrouping.elbowsChildren`): a child agent session's row sits directly
/// under its parent row, in the parent's bucket whatever its own status, so the tree reads top
/// to bottom (its own status still shows on the row); a tree with a row that needs the person
/// sits under Needs you. A child of a child follows it the same way.
/// A row whose parent is not listed (filtered out, another list) stays in its own bucket.
nonisolated extension SidebarLayout {
    struct Member {
        var ws: SidebarWorkspace
        var section: SidebarSection
        var index: Int
        /// Drawn with the elbow connector under its parent.
        var elbow = false
    }

    /// `members` (in list order) under their buckets, children after their parents with elbows on.
    static func bucketed(_ members: [Member], options o: SidebarLayoutOptions) -> [SidebarStatusBucket: [Member]] {
        var buckets: [SidebarStatusBucket: [Member]] = [:]
        guard o.elbowsChildren else {
            for member in members { buckets[o.grouping.bucket(member.ws), default: []].append(member) }
            return buckets
        }
        let listed = Set(members.map(\.ws.id))
        var children: [WorkspaceID: [Member]] = [:]
        var roots: [Member] = []
        for member in members {
            if let parent = member.ws.parentWorkspace, parent != member.ws.id, listed.contains(parent) {
                children[parent, default: []].append(member)
            } else {
                roots.append(member)
            }
        }
        var placed: Set<WorkspaceID> = []
        func place(_ member: Member, elbow: Bool, in bucket: SidebarStatusBucket) {
            guard placed.insert(member.ws.id).inserted else { return }
            var member = member
            member.elbow = elbow
            buckets[bucket, default: []].append(member)
            for child in children[member.ws.id] ?? [] { place(child, elbow: true, in: bucket) }
        }
        // A tree with a row that waits on the person goes under Needs you whole: Needs you never
        // folds, so that row never hides inside a folded parent's bucket.
        func treeNeedsYou(_ member: Member, seen: inout Set<WorkspaceID>) -> Bool {
            guard seen.insert(member.ws.id).inserted else { return false }
            if o.grouping.bucket(member.ws) == .needsYou { return true }
            return (children[member.ws.id] ?? []).contains { treeNeedsYou($0, seen: &seen) }
        }
        func bucket(of root: Member) -> SidebarStatusBucket {
            var seen: Set<WorkspaceID> = []
            return treeNeedsYou(root, seen: &seen) ? .needsYou : o.grouping.bucket(root.ws)
        }
        for root in roots { place(root, elbow: false, in: bucket(of: root)) }
        // Rows whose parents name each other in a loop: the first in list order leads.
        for member in members where !placed.contains(member.ws.id) {
            place(member, elbow: false, in: bucket(of: member))
        }
        return buckets
    }
}

nonisolated extension SidebarLayoutOptions {
    /// Group by Status's elbow children; the model's `SidebarGrouping.elbowsChildren`.
    public var elbowsChildren: Bool {
        get { grouping.elbowsChildren }
        set { grouping.elbowsChildren = newValue }
    }

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
