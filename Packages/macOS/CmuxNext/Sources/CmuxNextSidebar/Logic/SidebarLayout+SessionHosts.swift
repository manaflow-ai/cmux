import Foundation

nonisolated extension SidebarLayout {
    /// Group only existing loose agent workspaces. The window's drawn rows decide whether a
    /// lineage parent is live, never the daemon's lane census. Retain each row's document section
    /// and sibling index so selection, close and drop continue to target the original workspace.
    func groupingSessions(_ tree: SidebarSessionTreeState, sections: [SidebarSection], metrics m: SidebarLayoutMetrics) -> SidebarLayout {
        var bundles: [Int: [SidebarRow]] = [:]
        var starts: [Int] = []
        var tabRows: Set<Int> = []
        for (i, row) in rows.enumerated() {
            guard case let .workspace(id) = row.key else { continue }
            starts.append(i)
            var bundle = [row]
            var next = i + 1
            while next < rows.count, case let .tab(workspace, _) = rows[next].key, workspace == id {
                bundle.append(rows[next])
                tabRows.insert(next)
                next += 1
            }
            bundles[i] = bundle
        }
        let ids: [WorkspaceID?] = starts.map { if case let .workspace(id) = rows[$0].key { id } else { nil } }
        // A visible parent inside an explicit user group is still a lineage anchor. Only
        // loose children move; explicitly placed members keep the user's document order.
        let looseIDs = Set(starts.compactMap { i -> WorkspaceID? in
            guard rows[i].group == nil, case let .workspace(id) = rows[i].key else { return nil }
            return id
        })
        let parents = tree.parents.filter { looseIDs.contains($0.key) }
        let children = Self.treeChildren(ids, parents: parents)
        let nested = Set(children.values.joined())
        let roots = ids.indices.filter { !nested.contains($0) }
        var hosts: [String: [Int]] = [:]
        var rootHosts: [Int: String] = [:]
        for root in roots {
            guard rows[starts[root]].group == nil, let id = ids[root], let host = tree.hosts[id],
                  case .machine = rows[starts[root]].section else { continue }
            rootHosts[root] = host
            hosts[host, default: []].append(root)
        }
        let workspaceByID = Dictionary(sections.flatMap(\.workspaces).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func agentState(_ index: Int) -> SidebarAgentState {
            guard let id = ids[index], let ws = workspaceByID[id] else { return .idle }
            return SidebarAgentState.of(ws, lane: tree.states[id])
        }
        // Reordering only the workspace bundles leaves user groups, document items and section
        // blocks in their existing order. Each host is emitted at its first root's old position.
        var emitted: Set<String> = []
        let byStart = Dictionary(starts.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [SidebarRow] = []
        var y = rows.first?.y ?? m.topPadding
        func append(_ original: SidebarRow, spacing: CGFloat = 0) {
            var row = original
            row.y = y
            result.append(row)
            y += row.height + spacing
        }
        func family(_ root: Int, depth: Int, groupDepth: Int = 0) {
            guard let id = ids[root], var bundle = bundles[starts[root]], !bundle.isEmpty else { return }
            let (fold, rollUp) = Self.treeFold(root, ids, tree: tree, children: children, states: agentState)
            bundle[0].content?.treeDepth = depth
            if bundle[0].group == nil || fold != nil {
                bundle[0].content?.treeFold = fold
                bundle[0].content?.rollUp = rollUp
            }
            for var row in bundle {
                row.depth = max(row.depth, groupDepth)
                append(row, spacing: m.rowSpacing)
            }
            guard !tree.collapsed.contains(id) else { return }
            for child in children[id] ?? [] {
                family(child, depth: depth + 1, groupDepth: max(groupDepth, bundle[0].depth))
            }
        }
        for (index, row) in rows.enumerated() {
            if tabRows.contains(index) { continue }
            guard let root = byStart[index] else {
                let gap = index + 1 < rows.count ? rows[index + 1].y - row.maxY : 0
                append(row, spacing: max(0, gap))
                continue
            }
            guard !nested.contains(root) else { continue }
            guard let host = rootHosts[root] else {
                family(root, depth: row.content?.treeDepth ?? 0)
                continue
            }
            guard emitted.insert(host).inserted else { continue }
            let members = hosts[host] ?? []
            let count = members.reduce(0) { total, member in
                total + 1 + (ids[member].map { Self.treeDescendants(of: $0, ids, children: children).count } ?? 0)
            }
            let collapsed = tree.collapsedHosts.contains(host)
            append(SidebarRow(key: .sessionHost(host), y: y, height: m.groupHeaderHeight, section: row.section,
                              group: nil, siblingIndex: row.siblingIndex, parentIndex: nil, isLastInGroup: false,
                              isCollapsed: collapsed, childCount: count, groupColor: nil), spacing: m.rowSpacing)
            if !collapsed { for member in members { family(member, depth: 1) } }
        }
        let oldEnd = rows.last?.maxY ?? m.topPadding
        // The final workspace bundle already added row spacing; preserve the normal bottom padding.
        let newEnd = result.last?.maxY ?? m.topPadding
        let shift = newEnd - oldEnd
        var layout = SidebarLayout(rows: result, totalHeight: totalHeight + shift,
                                   gapY: gapY, gapHeight: gapHeight, gapShift: gapShift)
        layout.rowSpacing = rowSpacing
        layout.pinnedChatsY = pinnedChatsY
        layout.earlierChatsY = earlierChatsY.map { $0 + shift }
        return layout
    }
}
