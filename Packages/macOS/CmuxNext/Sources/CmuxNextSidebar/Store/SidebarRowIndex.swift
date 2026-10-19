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
        switch sections[path.section].nodes[path.node] {
        case .workspace:
            sections[path.section].nodes[path.node] = .workspace(row)
        case var .group(group):
            group.workspaces[path.member ?? 0] = row
            sections[path.section].nodes[path.node] = .group(group)
        case .item:
            break
        }
    }

    /// `sections` with each of `rows` written over the listed row of the
    /// same id (its row state and machine kept). One walk, for a copy of the
    /// rows that has no index (the App's live rows under pending edits).
    static func patching(_ rows: [SidebarWorkspace], in sections: [SidebarSection]) -> [SidebarSection] {
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
    /// unread total, and its tab rows) is configured again. Only a row whose
    /// height changes reloads the layout; nothing rebuilds the sections.
    func patchRows(_ patched: [SidebarWorkspace]) {
        // A drag, its settle or its landing runs: the rows keep their look until the card is gone (`SidebarRowHold`).
        if holdsRowPatches { return holdRowPatches(patched) }
        // Rows still held after the hold ended (its card went without a landing): they apply with these.
        if !rowHold.isEmpty { return releaseRowHold(adding: patched) }
        SidebarPerfCounters.add(.rowPatches, patched.count)
        // A height change lays the list out again (outside the timed patch: `reload` times itself);
        // provisional rows swap in place, as on any reload (`SidebarView.animatesReload`).
        if SidebarPerfCounters.timed({ patchRowsNow(patched) }) { reload(animated: !model.sections.contains(where: \.hasProvisionalRows)) }
    }

    /// Patches each row in place; true when one row's height changed.
    private func patchRowsNow(_ patched: [SidebarWorkspace]) -> Bool {
        var options: SidebarLayoutOptions?
        var heightChanged = false
        let shownCard = hoverCard.shownID
        for ws in patched {
            workspaces[ws.id] = ws
            for tab in ws.tabs { tabs[tab.id] = tab }
            for path in model.rowIndex?.paths(of: ws.id) ?? [] {
                let section = model.sections[path.section]
                sections[section.id] = section
                // A group header draws its members' activity and unread total when
                // collapsed, where the member has no row: configure it whatever shows.
                if path.member != nil, case let .group(group) = section.nodes[path.node] {
                    groups[group.id] = group
                    reconfigure(.group(group.id))
                }
            }
            if shownCard == ws.id { hoverCards.contentChanged(WorkspaceHoverCardController.targetID(ws.id)) }
            guard let row = displayed.row(for: .workspace(ws.id)), let section = sections[row.section] else { continue }
            let o = options ?? self.options(includeGap: true)
            options = o
            let content = o.rowContent(ws, machine: SidebarLayout.machineLabel(section, options: o))
            let m = o.minimal ? metrics.minimal : metrics
            guard m.height(for: content) == row.height else {
                heightChanged = true
                continue
            }
            displayed.setContent(content, for: row.key)
            reconfigure(row.key)
            for tab in ws.tabs { reconfigure(.tab(ws.id, tab.id)) }
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

    /// The computer a workspace row of `section` names on its second line in
    /// the one-list sidebar (never this Mac), with its status when it cannot
    /// connect; nil otherwise. The one rule for `make` and a row update.
    static func machineLabel(_ section: SidebarSection, options o: SidebarLayoutOptions) -> String? {
        guard o.flattensMachines, let machine = section.machine, machine.kind != .local, !machine.keepsHeaderInList else { return nil }
        return o.machineStatusLabels[machine.id].map { machine.name + WorkspaceRowContent.separator + $0 } ?? machine.name
    }
}

nonisolated extension SidebarSection {
    /// `sections` with `rows` written over the listed rows of the same ids
    /// (each keeps its row state and machine): a row content update to a
    /// copy of the rows (`SidebarModel.patchWorkspaces` updates the model's).
    public static func patching(_ rows: [SidebarWorkspace], in sections: [SidebarSection]) -> [SidebarSection] {
        SidebarRowIndex.patching(rows, in: sections)
    }
}
