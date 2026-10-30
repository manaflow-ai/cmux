import Foundation

nonisolated extension SidebarLayout {
    /// Group only existing loose agent workspaces. The window's drawn rows decide whether a
    /// lineage parent is live, never the daemon's lane census. Retain each row's document section
    /// and sibling index so selection, close and drop continue to target the original workspace.
    func groupingSessions(_ tree: SidebarSessionTreeState, sections: [SidebarSection], gap: DropPosition?, metrics m: SidebarLayoutMetrics) -> SidebarLayout {
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
            guard rows[i].group == nil, case .machine = rows[i].section,
                  case let .workspace(id) = rows[i].key else { return nil }
            return id
        })
        let machineParents = Set(starts.compactMap { i -> WorkspaceID? in
            guard case let .workspace(id) = rows[i].key,
                  case .machine = rows[i].section else { return nil }
            return id
        })
        // Preserve the Pinned/custom boundary: a fleet child of a pinned workspace
        // remains in its own machine group rather than being pulled into Pinned.
        let parents = tree.parents.filter { looseIDs.contains($0.key) && machineParents.contains($0.value) }
        let children = Self.treeChildren(ids, parents: parents)
        let nested = Set(children.values.joined())
        let roots = ids.indices.filter { !nested.contains($0) }
        struct HostKey: Hashable {
            let host: String
            let section: SectionID
        }
        var hosts: [HostKey: [Int]] = [:]
        var rootHosts: [Int: HostKey] = [:]
        for root in roots {
            guard rows[starts[root]].group == nil, let id = ids[root], let host = tree.hosts[id],
                  case .machine = rows[starts[root]].section else { continue }
            let key = HostKey(host: host, section: rows[starts[root]].section)
            rootHosts[root] = key
            hosts[key, default: []].append(root)
        }
        let workspaceByID = Dictionary(sections.flatMap(\.workspaces).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func agentState(_ index: Int) -> SidebarAgentState {
            guard let id = ids[index], let ws = workspaceByID[id] else { return .idle }
            return SidebarAgentState.of(ws, lane: tree.states[id])
        }
        // Reordering only the workspace bundles leaves user groups, document items and section
        // blocks in their existing order. Each host is emitted at its first root's old position.
        var emitted: Set<HostKey> = []
        let byStart = Dictionary(starts.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [SidebarRow] = []
        var y: CGFloat = 0
        var movedGapY: CGFloat?, movedPinnedY: CGFloat?, movedEarlierY: CGFloat?
        // A drop before a workspace follows that workspace when lineage reorders it.
        // Section-end drops stay in their boundary, before history or the next section.
        let gapTarget: SidebarRowKey? = gapY.flatMap { oldGap in
            guard let gap, let next = rows.first(where: { $0.y >= oldGap + gapShift }),
                  next.section == gap.section, next.group == gap.group,
                  case .workspace = next.key else { return nil }
            return next.key
        }
        func openGap() {
            guard gapY != nil, movedGapY == nil else { return }
            movedGapY = y
            y += gapShift
        }
        // Preserve whitespace at its original section/history boundary, not on a
        // workspace that may move into an earlier family. This also maps anchors
        // when the original last workspace moves or disappears into a fold.
        func boundary(from start: CGFloat, to end: CGFloat) {
            let containsGap = gapY.map { $0 >= start && $0 + gapShift <= end } ?? false
            let removed = containsGap && gapTarget != nil ? gapShift : 0
            func mapped(_ anchor: CGFloat?) -> CGFloat? {
                guard let anchor, anchor >= start, anchor <= end else { return nil }
                let adjustment = containsGap && gapTarget != nil && anchor >= (gapY ?? 0) + gapShift ? gapShift : 0
                return y + anchor - start - adjustment
            }
            if let anchor = mapped(pinnedChatsY) { movedPinnedY = anchor }
            if let anchor = mapped(earlierChatsY) { movedEarlierY = anchor }
            if containsGap, gapTarget == nil, let gapY { movedGapY = y + gapY - start }
            y += end - start - removed
        }
        func append(_ original: SidebarRow, spacing: CGFloat = 0) {
            if original.key == gapTarget { openGap() }
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
            // Workspace bundles keep their normal row spacing. Larger gaps belong
            // to the following section/block and must not travel with a moved lane.
            for var row in bundle {
                row.depth = max(row.depth, groupDepth)
                append(row, spacing: m.rowSpacing)
            }
            guard !tree.collapsed.contains(id) else {
                if let gapTarget, Self.treeDescendants(of: id, ids, children: children)
                    .contains(where: { ids[$0].map(SidebarRowKey.workspace) == gapTarget }) { openGap() }
                return
            }
            for child in children[id] ?? [] {
                family(child, depth: depth + 1, groupDepth: max(groupDepth, bundle[0].depth))
            }
        }
        for (index, row) in rows.enumerated() {
            boundary(from: index == 0 ? 0 : rows[index - 1].maxY + m.rowSpacing, to: row.y)
            if tabRows.contains(index) { continue }
            guard let root = byStart[index] else {
                append(row, spacing: m.rowSpacing)
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
            let collapsed = tree.collapsedHosts.contains(host.host)
            let hostKey = SidebarSessionTree.hostKey(host.host, section: host.section)
            append(SidebarRow(key: .sessionHost(hostKey), y: y, height: m.groupHeaderHeight, section: row.section,
                              group: nil, siblingIndex: row.siblingIndex, parentIndex: nil, isLastInGroup: false,
                              isCollapsed: collapsed, childCount: count, groupColor: nil), spacing: m.rowSpacing)
            if !collapsed { for member in members { family(member, depth: 1) } }
            else if let gapTarget, members.contains(where: { member in
                ids[member].map(SidebarRowKey.workspace) == gapTarget || ids[member].map { id in
                    Self.treeDescendants(of: id, ids, children: children)
                        .contains(where: { ids[$0].map(SidebarRowKey.workspace) == gapTarget })
                } == true
            }) { openGap() }
        }
        // The visual order is a projection, but the reducer still writes document
        // positions. Keep row identity/siblingIndex for selection and give it the
        // slot immediately before the next drawn sibling for drop resolution.
        func siblingCount(_ row: SidebarRow) -> Int {
            guard let section = sections.first(where: { $0.id == row.section }) else { return row.siblingIndex + 1 }
            if let group = row.group,
               let node = section.nodes.first(where: { $0.id == .group(group) }),
               case let .group(value) = node { return value.members.count }
            return section.nodes.count
        }
        for index in result.indices {
            guard case .workspace = result[index].key else { continue }
            let section = result[index].section
            let group = result[index].group
            let next = result[(index + 1)..<result.count].first {
                if case .workspace = $0.key { return $0.section == section && $0.group == group }
                return false
            }
            result[index].dropIndex = next.map { max(0, $0.siblingIndex - 1) }
                ?? max(0, siblingCount(result[index]) - 1)
        }
        boundary(from: rows.last.map { $0.maxY + m.rowSpacing } ?? 0, to: totalHeight)
        var layout = SidebarLayout(rows: result, totalHeight: y,
                                   gapY: movedGapY, gapHeight: gapHeight, gapShift: gapShift)
        layout.rowSpacing = rowSpacing
        layout.pinnedChatsY = movedPinnedY
        layout.earlierChatsY = movedEarlierY
        return layout
    }
}


nonisolated extension SidebarLayout {
    /// The host family containing a drawn row, if any. Synthetic headers are
    /// stable per host and machine section, so they also provide the drag family.
    func sessionHost(for key: SidebarRowKey) -> String? {
        guard let index = position(of: key) else { return nil }
        return sessionHost(around: index)
    }

    private func sessionHost(around index: Int) -> String? {
        guard !rows.isEmpty else { return nil }
        for i in stride(from: min(index, rows.count - 1), through: 0, by: -1) {
            if case let .sessionHost(host) = rows[i].key { return SidebarSessionTree.hostID(from: host) }
            if case .workspace = rows[i].key, rows[i].content?.treeDepth == 0 { return nil }
            if case .section = rows[i].key { return nil }
        }
        return nil
    }

    /// Resolve a projected row's upper/lower half to the next drawn sibling.
    /// `.none` means the ordinary ungrouped resolver should run; `.some(nil)`
    /// refuses a slot outside the dragged row's family.
    func groupedDropTarget(row: SidebarRow, after: Bool, sourceHost: String?) -> DropTarget?? {
        guard rows.contains(where: { if case .sessionHost = $0.key { true } else { false } }) else { return nil }
        guard case .workspace = row.key else { return .some(nil) }
        let targetHost = sessionHost(for: row.key)
        if targetHost != nil && targetHost != sourceHost { return .some(nil) }
        let index = position(of: row.key) ?? 0
        let next = rows[(index + 1)..<rows.count].first { candidate in
            guard case .workspace = candidate.key else { return false }
            return candidate.section == row.section && candidate.group == row.group
        }
        let insertion: Int
        if after {
            insertion = next?.siblingIndex ?? rows[(0..<rows.count)].filter {
                if case .workspace = $0.key { return $0.section == row.section && $0.group == row.group }
                return false
            }.map(\.siblingIndex).max().map { $0 + 1 } ?? row.siblingIndex + 1
        } else {
            insertion = row.siblingIndex
        }
        return .some(.position(DropPosition(section: row.section, group: row.group, index: insertion)))
    }
}
