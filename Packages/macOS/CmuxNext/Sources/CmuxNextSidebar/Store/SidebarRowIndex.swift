import AppKit

/// Where each workspace row sits in a window's sections, so a row content
/// change (agent status, OSC 7501 program status, title, unread, progress,
/// favicon) reaches its one row without a structural rebuild
/// (.cmux-scratch/sidebar-rewrite/CONTRACT.md "SidebarRowIndex": workspace
/// ref -> visible row view; a status tick configures one row).
///
/// Built once per structural change (O(n)); each lookup is O(1).
nonisolated struct SidebarRowIndex: Sendable {
    /// A workspace row's place: its section, its node, and its slot in that
    /// node's group (nil for a loose row).
    struct Path: Hashable, Sendable {
        var section: Int
        var node: Int
        var member: Int?
    }

    /// Every place a workspace is listed (a launch can list a saved row beside its live one).
    private var paths: [WorkspaceID: [Path]] = [:]

    init(_ sections: [SidebarSection]) {
        for (s, section) in sections.enumerated() {
            for (n, node) in section.nodes.enumerated() {
                switch node {
                case let .workspace(ws):
                    paths[ws.id, default: []].append(Path(section: s, node: n, member: nil))
                case let .group(group):
                    for (m, ws) in group.workspaces.enumerated() {
                        paths[ws.id, default: []].append(Path(section: s, node: n, member: m))
                    }
                case .item:
                    continue
                }
            }
        }
    }

    func paths(of id: WorkspaceID) -> [Path] { paths[id] ?? [] }

    static func workspace(at path: Path, in sections: [SidebarSection]) -> SidebarWorkspace {
        switch sections[path.section].nodes[path.node] {
        case let .workspace(ws): ws
        case let .group(group): group.workspaces[path.member ?? 0]
        case let .item(item): SidebarWorkspace(id: WorkspaceID(item.id), title: item.title) // never indexed: no path names an item row
        }
    }

    static func set(_ row: SidebarWorkspace, at path: Path, in sections: inout [SidebarSection]) {
        sections[path.section].setRow(row, node: path.node, member: path.member)
    }

    /// Whether `nodes[node]` is the node `nodeID` (the same loose row or the same group) and lists workspace `id` there
    /// (at `member`, in a group): the same place in another copy of the rows.
    static func lists(_ id: WorkspaceID, in nodeID: SidebarNode.ID, node n: Int, member: Int?, in nodes: [SidebarNode]) -> Bool {
        guard nodes.indices.contains(n), nodes[n].id == nodeID else { return false }
        switch nodes[n] {
        case let .workspace(ws): return member == nil && ws.id == id
        case let .group(group):
            guard let member, group.workspaces.indices.contains(member) else { return false }
            return group.workspaces[member].id == id
        case .item: return false
        }
    }

    /// Writes each of `rows` over its listed rows in `sections` in place, through the paths this index holds for
    /// them (each copy keeps its row state and machine, as `patching` does): a row change visits that row's paths
    /// only, the same at 3,000 rows as at 10.
    func patch(_ rows: [SidebarWorkspace], in sections: inout [SidebarSection]) {
        for row in rows {
            for path in paths(of: row.id) {
                let old = Self.workspace(at: path, in: sections)
                var copy = row
                copy.rowState = old.rowState
                copy.machineID = old.machineID
                Self.set(copy, at: path, in: &sections)
            }
        }
    }

    /// `sections` with each of `rows` written over the listed row of the
    /// same id (its row state and machine kept). One walk, for a copy of the
    /// rows that has no index (the App's live rows under pending edits).
    static func patching(_ rows: [SidebarWorkspace], in sections: [SidebarSection]) -> [SidebarSection] {
        guard !rows.isEmpty else { return sections }
        let changed = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        func patched(_ ws: SidebarWorkspace) -> SidebarWorkspace {
            guard var row = changed[ws.id] else { return ws }
            row.rowState = ws.rowState
            row.machineID = ws.machineID
            return row
        }
        var result = sections
        for s in result.indices {
            for n in result[s].nodes.indices {
                switch result[s].nodes[n] {
                case let .workspace(ws):
                    if changed[ws.id] != nil { result[s].nodes[n] = .workspace(patched(ws)) }
                case var .group(group):
                    guard group.workspaces.contains(where: { changed[$0.id] != nil }) else { continue }
                    group.workspaces = group.workspaces.map(patched)
                    result[s].nodes[n] = .group(group)
                case .item:
                    continue
                }
            }
        }
        return result
    }
}

extension SidebarListView {
    /// Shows row content changes of listed workspaces (`SidebarModel.patchWorkspaces`):
    /// each row's new content goes into the shown layout and its realized
    /// view (plus its group header, which draws the members' activity and
    /// unread total) is configured again. Only a row whose
    /// height changes reloads the layout; nothing rebuilds the sections.
    func patchRows(_ patched: [SidebarWorkspace]) {
        // A drag, its settle or its landing runs: the rows keep their look until the card is gone (`SidebarRowHold`).
        if holdsRowPatches { return holdRowPatches(patched) }
        // Rows still held after the hold ended (its card went without a landing): they apply with these.
        if !rowHold.isEmpty { return releaseRowHold(adding: patched) }
        SidebarPerfCounters.add(.rowPatches, patched.count)
        // A height change lays the list out again (outside the timed patch: `reload` times itself), with no
        // motion unless the user asked for it, and not under the pointer (`showModelChange`, calm-sidebar-movement);
        // provisional rows swap in place, as on any reload (`SidebarView.animatesReload`).
        // A changed height leaves the shown layout behind the model until that reload: no insert splices onto it.
        if SidebarPerfCounters.timed({ patchRowsNow(patched) }) { spliceBase = nil; showModelChange(animates: !model.sections.contains(where: \.hasProvisionalRows)) }
    }

    /// Patches each row in place; true when one row's height changed.
    func patchRowsNow(_ patched: [SidebarWorkspace]) -> Bool {
        spacePages.cachesTookChange(at: model.structureRevision)
        var options: SidebarLayoutOptions?
        var heightChanged = false
        let shownCard = hoverCard.shownID
        let shownGroupCard = hoverCard.shownGroupID
        for ws in patched {
            // The hover cards show no "Now:" step: a working agent's new step (many a second) rebuilds no card.
            let previous = workspaces[ws.id]
            let cardChanged = previous.map { var old = $0; old.agentStep = ws.agentStep; return old != ws } ?? true
            workspaces[ws.id] = ws
            for path in model.rowIndex?.paths(of: ws.id) ?? [] {
                let modelRows = model.sections
                let sectionID = modelRows[path.section].id
                let listed = SidebarRowIndex.workspace(at: path, in: modelRows) // this place's row, its own row state
                // The list's caches take the row in place. A copy of the model's section (and group) shared its
                // storage, so the model's next in-place write (`SidebarRowIndex.set`) copied that section's whole node
                // list: O(rows) per patch with a list attached.
                // (The checks read the caches in one expression each: a copy held over the write would make it copy.)
                let nodeID = modelRows[path.section].nodes[path.node].id
                if sections[sectionID].map({ SidebarRowIndex.lists(ws.id, in: nodeID, node: path.node, member: path.member, in: $0.nodes) }) == true {
                    sections[sectionID]?.setRow(listed, node: path.node, member: path.member)
                } else {
                    sections[sectionID] = modelRows[path.section] // another arrangement than the shown one: as the model has it
                }
                // A group header draws its members' activity and unread total when
                // collapsed, where the member has no row: configure it whatever shows.
                if let member = path.member, case let .group(modelGroup) = modelRows[path.section].nodes[path.node] {
                    let groupID = modelGroup.id
                    if groups[groupID].map({ $0.workspaces.indices.contains(member) && $0.workspaces[member].id == ws.id }) == true {
                        groups[groupID]?.workspaces[member] = listed
                    } else {
                        groups[groupID] = modelGroup
                    }
                    reconfigure(.group(groupID))
                    // The shown card is this group's or an ancestor's: a parent's card counts its subgroups.
                    if cardChanged, let shownGroupCard, groupSubtrees[shownGroupCard]?.contains(groupID) ?? (shownGroupCard == groupID) {
                        hoverCards.contentChanged(WorkspaceHoverCardController.targetID(shownGroupCard))
                    }
                }
            }
            if cardChanged, shownCard == ws.id { hoverCards.contentChanged(WorkspaceHoverCardController.targetID(ws.id)) }
            guard let row = displayed.row(for: .workspace(ws.id)), let section = sections[row.section] else {
                // A session a folded parent hides: the parent's roll-up counts its state, so the list lays out
                // again when that state moves, not on each step or title it reports.
                if SidebarSessionTree.shared.drawn?.patchChangesRollUp(from: previous, to: ws) == true { heightChanged = true }
                continue
            }
            let o = options ?? self.options(includeGap: true)
            options = o
            var content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section, options: o))
            content.treeDepth = row.content?.treeDepth ?? 0 // a patch moves no row: it stays where the tree put it
            (content.treeFold, content.rollUp) = (row.content?.treeFold, row.content?.rollUp) // and keeps its chevron and roll-up
            let m = metrics.resolved(for: o)
            guard m.height(for: content) == row.height else {
                heightChanged = true
                continue
            }
            displayed.setContent(content, for: row.key)
            reconfigure(row.key)
        }
        return heightChanged
    }

    /// Configures `key`'s realized view from the shown layout; a row with no view is drawn when it scrolls in.
    private func reconfigure(_ key: SidebarRowKey) {
        guard let view = rowViews[key], let row = displayed.row(for: key) else { return }
        configure(view, row: row, animated: false)
    }
}

nonisolated extension SidebarLayout {
    /// The indices of the rows that may reach into `minY..<maxY`: from the
    /// last row starting at or above `minY` to the last starting above
    /// `maxY` (rows are sorted by y). O(log n) to find, then only those rows.
    func rowIndices(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        let start = lastIndex(startingAtOrBefore: minY) ?? 0
        let end = lastIndex(startingAtOrBefore: maxY).map { $0 + 1 } ?? 0
        return start..<max(start, end)
    }

    /// Whether `section` keeps its header (and its fold) in the one-list sidebar, where other
    /// computers' sections draw none: a remote group the person made, the local Chief's
    /// workspaces, which read as one collapsible "Chief" group of their own, never as the rows
    /// after the last group above them (Leo 2026-10-21), and a Cloud machine, whose rows otherwise
    /// floated under this Mac's last group with no machine over them (Leo 2026-10-29: "why is there
    /// all this weird stuff at the bottom of the sidebar"). A remote group that draws as one sidebar
    /// group (``SidebarSection/drawsAsGroup``) has its group bar instead. The one rule for every header kind.
    static func keepsHeaderInOneList(_ section: SidebarSection) -> Bool {
        (section.isHostGroup || section.machine?.kind == .cloud) && !section.drawsAsGroup
    }

    /// The computer a workspace row of `section` names in the one-list sidebar
    /// (an expanded row's meta line, the row's accessibility label) (never this Mac, nor the Chief on it, whose workspaces
    /// read like this Mac's: their hover card says who started them), with its
    /// status when it cannot connect; nil otherwise. The one rule for `make` and a row update.
    static func machineLabel(_ section: SidebarSection, options o: SidebarLayoutOptions) -> String? {
        guard o.flattensMachines, let machine = section.machine, machine.kind != .local
        else { return nil }
        return o.machineStatusLabels[machine.id].map { machine.name + WorkspaceRowContent.separator + $0 } ?? machine.name
    }
}

nonisolated extension SidebarSection {
    /// Writes `row` at `nodes[node]` (its group's `member`, in a group) in place.
    mutating func setRow(_ row: SidebarWorkspace, node n: Int, member: Int?) {
        // The node is swapped out in place first: a `switch` over `nodes[n]` holds a copy of the node list
        // while its cases write, so every write copied the section's whole node list (O(rows) per row patch).
        var node = SidebarNode.workspace(row)
        swap(&node, &nodes[n])
        switch node {
        case .workspace:
            return
        case var .group(group):
            node = .workspace(row) // the group's members are held by `group` alone: the write below is in place
            group.workspaces[member ?? 0] = row
            nodes[n] = .group(group)
        case .item:
            nodes[n] = node
        }
    }

    /// `sections` with `rows` written over the listed rows of the same ids
    /// (each keeps its row state and machine): a row content update to a
    /// copy of the rows (`SidebarModel.patchWorkspaces` updates the model's).
    public static func patching(_ rows: [SidebarWorkspace], in sections: [SidebarSection]) -> [SidebarSection] {
        SidebarRowIndex.patching(rows, in: sections)
    }

    /// Where each row of a copy of the rows sits (one walk per structural change), so a row content update writes
    /// its rows in place instead of walking and copying every section (`SidebarRows.patch` under 3,000 workspaces).
    public struct RowPlaces: Sendable {
        private var index: SidebarRowIndex?
        /// No places yet: the first patch finds them in the sections it patches.
        public init() {}

        /// `patching`'s result, written into `sections`, which must be the rows of the first patch since this was made
        /// (rows patched since included: a patch moves no row). Make a new one when the sections change otherwise.
        public mutating func patch(_ rows: [SidebarWorkspace], in sections: inout [SidebarSection]) {
            guard !rows.isEmpty else { return }
            let index = index ?? SidebarRowIndex(sections)
            self.index = index
            index.patch(rows, in: &sections)
        }
    }
}
