import AppKit

// SIDEBAR INSERT 2: a set that only adds one loose workspace row (Cmd-N's stand-in row at the press, a scripted create)
// splices that row into the layout the list shows (`SidebarLayout.insertLoose`), and the apply visits only that row
// and the realized ones. The key turn laid every row out again for it (xctrace, cmux21, 120 Hz: the reload 10 ms at
// 50 rows, 17 ms at 200). Anything else, or any doubt, lays the list out in full as before.
extension SidebarListViewComponents {
    /// The layout with the model's last set's one new row spliced in, its key, and the options it was laid out with;
    /// the list's row caches take the row. Nil (nothing changed) when that set added more, the list shows a layout
    /// made from another revision or other options, a drag owns the rows, or the selection's move changes other rows.
    func spliceInsertion() -> (layout: SidebarLayout, row: SidebarRowKey, options: SidebarLayoutOptions)? {
        guard let insertion = model.rowInsertion, insertion.to == model.sectionsRevision, insertion.content == model.contentRevision, let base = spliceBase,
              base.revision == insertion.from, drag == nil, settling == nil, landing == nil, external == nil,
              leaving.isEmpty, let ws = insertion.workspace, workspaces[ws.id] == nil,
              let shown = sections[insertion.section.id], shown.nodes.count + 1 == insertion.section.nodes.count else { return nil }
        // The section the list drew is the set's without the new node (one compare per node, no layout): not when
        // `listingEachWorkspaceOnce` left out a workspace an earlier section lists too, which the cache would take back.
        var before = insertion.section
        before.nodes.remove(at: insertion.node)
        SidebarPerfCounters.add(.rowsWalked, shown.nodes.count)
        listWork.walked(shown.nodes.count)
        guard shown == before else { return nil }
        let o = options(includeGap: true)
        // The selection moves to the new row with the insert (Cmd-N): the layout reads it only to keep a selected row
        // in a collapsed group, in a fold or out of the Archive, so it must leave every row where it was, both ways.
        var (now, then) = (o, base.options)
        (now.activeWorkspaceID, then.activeWorkspaceID) = (nil, nil)
        guard now == then, keepsRows(selecting: base.options.activeWorkspaceID, inserted: ws.id, o),
              keepsRows(selecting: o.activeWorkspaceID, inserted: ws.id, o) else { return nil }
        var layout = displayed
        guard layout.insertLoose(insertion, metrics: metrics, options: o) else { return nil }
        workspaces[ws.id] = ws
        sections[insertion.section.id] = insertion.section
        return (layout, .workspace(ws.id), o)
    }

    /// The layout with the model's last set's one closed row taken out (a move's row put back at its new place), the
    /// row's key, whether it moved, and the options it was laid out with; the list's row caches take the change. Nil
    /// (nothing changed) on the same terms as `spliceInsertion`: any other change, or any doubt, lays out in full.
    func spliceRemoval() -> (layout: SidebarLayout, row: SidebarRowKey, moved: Bool, options: SidebarLayoutOptions)? {
        guard let removal = model.rowRemoval, removal.to == model.sectionsRevision, removal.content == model.contentRevision,
              let base = spliceBase, base.revision == removal.from, drag == nil, settling == nil, landing == nil, external == nil,
              leaving.isEmpty else { return nil }
        let id = removal.workspace.id
        // The section the list drew is the removal's with the row at its node (one compare per node, no layout).
        guard workspaces[id] != nil, let shown = sections[removal.section.id], removal.node < shown.nodes.count,
              case let .workspace(listed) = shown.nodes[removal.node], listed.id == id else { return nil }
        var after = shown
        after.nodes.remove(at: removal.node)
        SidebarPerfCounters.add(.rowsWalked, shown.nodes.count)
        listWork.walked(shown.nodes.count)
        guard after == removal.section else { return nil }
        // A move's target section, as the list would draw it before the row comes back.
        var target: SidebarSection?
        if let insertion = removal.insertion {
            guard insertion.workspace?.id == id,
                  let drawn = insertion.section.id == removal.section.id ? Optional(removal.section) : sections[insertion.section.id] else { return nil }
            var before = insertion.section
            before.nodes.remove(at: insertion.node)
            guard before == drawn else { return nil }
            target = insertion.section
        }
        let o = options(includeGap: true)
        // The selection leaves a closed row for another (`dropClosed`): it must move no row, both ways.
        var (now, then) = (o, base.options)
        (now.activeWorkspaceID, then.activeWorkspaceID) = (nil, nil)
        guard now == then, keepsRows(selecting: base.options.activeWorkspaceID, inserted: id, o),
              keepsRows(selecting: o.activeWorkspaceID, inserted: id, o) else { return nil }
        var layout = displayed
        guard layout.removeLoose(removal, metrics: metrics, options: o) else { return nil }
        if let insertion = removal.insertion {
            guard layout.insertLoose(insertion, metrics: metrics, options: o) else { return nil }
        }
        sections[removal.section.id] = removal.section
        if let target, let insertion = removal.insertion {
            sections[target.id] = target
            workspaces[id] = insertion.workspace
        } else {
            workspaces[id] = nil
        }
        return (layout, .workspace(id), removal.insertion != nil, o)
    }

    /// Whether selecting workspace `id` (or leaving it) moves no row: it is the inserted row, not listed here, or a
    /// drawn row that no fold, no collapsed group and no Archive keeps for the selection.
    private func keepsRows(selecting id: WorkspaceID?, inserted: WorkspaceID, _ o: SidebarLayoutOptions) -> Bool {
        keepsRows(selecting: id, spliced: [inserted], o)
    }

    /// `keepsRows(selecting:inserted:_:)` for a splice of several rows: a selection on one of them moves no other row.
    private func keepsRows(selecting id: WorkspaceID?, spliced: Set<WorkspaceID>, _ o: SidebarLayoutOptions) -> Bool {
        guard let id, !spliced.contains(id), let ws = workspaces[id] else { return true }
        guard !ws.isArchived, !(o.foldsDone && ws.taskStatus == .done), !o.settled.contains(id) else { return false }
        // Listed but not drawn: a collapsed group or a fold hides it, and its selection would draw it.
        guard let row = displayed.row(for: .workspace(id)) else { return false }
        // A group that leaves for the Archive stays in its list while it holds the selection (`splittingArchive`),
        // and so do its subgroups: moving the selection into or out of one moves its rows.
        var group = row.group
        var seen: Set<GroupID> = []
        while let id = group, seen.insert(id).inserted {
            guard let listed = groups[id], !listed.isCollapsed, !listed.isArchived,
                  listed.workspaces.isEmpty || !listed.workspaces.allSatisfy(\.isArchived) else { return false }
            group = listed.parent
        }
        return true
    }
}

// cmuxterm-hq#13493 (Leo 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?"): the row
// views were windowed, but a change that was not one row's insert or close laid every row out again and rebuilt every
// row cache, O(sessions) per change at 10,789 sessions with the daemon pushing a few changes a second. A batch of adds
// and closes, a move to another computer's list, and a row whose new content changed its height splice now too.
extension SidebarListViewComponents {
    /// The layout with the model's last set's closed rows taken out and its added rows spliced in (`SidebarLooseEdits`),
    /// which rows that is, and the options it was laid out with; the list's row caches take the change. Nil (nothing
    /// changed) on the same terms as `spliceInsertion`: any other change, or any doubt, lays out in full.
    func spliceEdits() -> (layout: SidebarLayout, splice: SidebarListSplice, options: SidebarLayoutOptions)? {
        guard let edits = model.rowEdits, edits.to == model.sectionsRevision, edits.content == model.contentRevision,
              let base = spliceBase, base.revision == edits.from, drag == nil, settling == nil, landing == nil, external == nil,
              leaving.isEmpty else { return nil }
        var removedIDs: Set<WorkspaceID> = [], insertedIDs: Set<WorkspaceID> = []
        for edit in edits.sections {
            // The section the list drew is the set's without its added rows and with its closed ones back at their
            // nodes (one compare per node of a changed section, no layout).
            guard let shown = sections[edit.section.id] else { return nil }
            var drawn = edit.section
            for k in edit.insertedNodes.reversed() {
                guard k < drawn.nodes.count, case let .workspace(ws) = drawn.nodes[k] else { return nil }
                insertedIDs.insert(ws.id)
                drawn.nodes.remove(at: k)
            }
            for (k, ws) in zip(edit.removedNodes, edit.removed) {
                guard k <= drawn.nodes.count else { return nil }
                drawn.nodes.insert(SidebarNode.workspace(ws), at: k)
                removedIDs.insert(ws.id)
            }
            SidebarPerfCounters.add(.rowsWalked, shown.nodes.count)
            guard drawn == shown else { return nil }
        }
        // A closed row is the list's; an added one is new to it, or one this set closes elsewhere (a move).
        guard removedIDs.allSatisfy({ workspaces[$0] != nil }),
              insertedIDs.allSatisfy({ removedIDs.contains($0) || workspaces[$0] == nil }) else { return nil }
        let o = options(includeGap: true)
        // The selection may move with the set (a close's successor, a created row): it must move no other row, both ways.
        let touched = removedIDs.union(insertedIDs)
        var (now, then) = (o, base.options)
        (now.activeWorkspaceID, then.activeWorkspaceID) = (nil, nil)
        guard now == then, keepsRows(selecting: base.options.activeWorkspaceID, spliced: touched, o),
              keepsRows(selecting: o.activeWorkspaceID, spliced: touched, o) else { return nil }
        var layout = displayed
        // Every closed row first, each section's from its last node up (the nodes before it keep their indices).
        for edit in edits.sections {
            for (k, ws) in zip(edit.removedNodes, edit.removed).reversed() {
                let removal = SidebarRowRemoval(from: edits.from, to: edits.to, content: edits.content, section: edit.section,
                                                node: k, workspace: ws, insertion: nil)
                guard layout.removeLoose(removal, metrics: metrics, options: o) else { return nil }
            }
        }
        // Then every added row, each section's from its first node down: a later added node has no row yet.
        for edit in edits.sections {
            var pending = Set(edit.insertedNodes)
            for k in edit.insertedNodes {
                pending.remove(k)
                let insertion = SidebarRowInsertion(from: edits.from, to: edits.to, content: edits.content, section: edit.section, node: k)
                guard layout.insertLoose(insertion, metrics: metrics, options: o, pending: pending) else { return nil }
            }
        }
        for edit in edits.sections { sections[edit.section.id] = edit.section }
        for id in removedIDs { workspaces[id] = nil }
        for edit in edits.sections {
            for k in edit.insertedNodes { if case let .workspace(ws) = edit.section.nodes[k] { workspaces[ws.id] = ws } }
        }
        let moved = removedIDs.intersection(insertedIDs)
        let splice = SidebarListSplice(inserted: insertedIDs.subtracting(moved).map { .workspace($0) },
                                       removed: removedIDs.subtracting(moved).map { .workspace($0) },
                                       moved: moved.map { .workspace($0) })
        return (layout, splice, o)
    }

    /// The shown layout with the rows whose new content changed their height (`pendingHeights`) at that height, the
    /// rows below them moved by the difference, and the options it was laid out with. Nil (nothing changed) when the
    /// layout they change is not the shown one (a structural set, a fold or other options since), a drag owns the rows,
    /// or the layout has a gap or a chat history block whose place the rows would move.
    func spliceHeights() -> (layout: SidebarLayout, splice: SidebarListSplice, options: SidebarLayoutOptions)? {
        guard let pending = pendingHeights, let base = pending.base, base.revision == model.sectionsRevision, drag == nil,
              settling == nil, landing == nil, external == nil, leaving.isEmpty, displayed.gapY == nil,
              displayed.pinnedChatsY == nil, displayed.earlierChatsY == nil else { return nil }
        let o = options(includeGap: true)
        guard o == base.options else { return nil }
        let m = metrics.resolved(for: o)
        var layout = displayed
        for (key, content) in pending.rows {
            guard let at = layout.position(of: key) else { return nil }
            layout.resizeRow(at: at, to: m.height(for: content), content: content)
            SidebarPerfCounters.add(.layoutRows)
        }
        return (layout, SidebarListSplice(), o)
    }
}

/// The rows a reload's splice added, took out and moved (`SidebarListView.splice`): the apply reads its change from
/// these alone, never from a walk of every row.
struct SidebarListSplice {
    var inserted: [SidebarRowKey] = []
    var removed: [SidebarRowKey] = []
    var moved: [SidebarRowKey] = []

    /// Whether `layout` is `old` with these changes: each added row listed, each closed one gone, each moved one in both.
    func holds(from old: SidebarLayout, to layout: SidebarLayout) -> Bool {
        inserted.allSatisfy { layout.row(for: $0) != nil }
            && removed.allSatisfy { old.row(for: $0) != nil && layout.row(for: $0) == nil }
            && moved.allSatisfy { old.row(for: $0) != nil && layout.row(for: $0) != nil }
    }

    /// Each added row's run top in `layout` (as `SidebarRowTransition.runTops`): added rows next to each other open as one run.
    func insertRuns(in layout: SidebarLayout) -> [SidebarRowKey: CGFloat] { Self.runTops(inserted, in: layout) }

    /// Each closed row's run top in `old`: closed rows next to each other close as one run.
    func removeRuns(in old: SidebarLayout) -> [SidebarRowKey: CGFloat] { Self.runTops(removed, in: old) }

    private static func runTops(_ keys: [SidebarRowKey], in layout: SidebarLayout) -> [SidebarRowKey: CGFloat] {
        var tops: [SidebarRowKey: CGFloat] = [:]
        var top: CGFloat = 0, last = -2
        for position in keys.compactMap({ layout.position(of: $0) }).sorted() {
            if position != last + 1 { top = layout.rows[position].y }
            tops[layout.rows[position].key] = top
            last = position
        }
        return tops
    }
}
