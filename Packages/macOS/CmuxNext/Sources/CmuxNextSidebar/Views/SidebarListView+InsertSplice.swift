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
              rowHold.isEmpty, leaving.isEmpty, let ws = insertion.workspace, workspaces[ws.id] == nil,
              let shown = sections[insertion.section.id], shown.nodes.count + 1 == insertion.section.nodes.count else { return nil }
        // The section the list drew is the set's without the new node (one compare per node, no layout): not when
        // `listingEachWorkspaceOnce` left out a workspace an earlier section lists too, which the cache would take back.
        var before = insertion.section
        before.nodes.remove(at: insertion.node)
        SidebarPerfCounters.add(.rowsWalked, shown.nodes.count)
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
              rowHold.isEmpty, leaving.isEmpty else { return nil }
        let id = removal.workspace.id
        // The section the list drew is the removal's with the row at its node (one compare per node, no layout).
        guard workspaces[id] != nil, let shown = sections[removal.section.id], removal.node < shown.nodes.count,
              case let .workspace(listed) = shown.nodes[removal.node], listed.id == id else { return nil }
        var after = shown
        after.nodes.remove(at: removal.node)
        SidebarPerfCounters.add(.rowsWalked, shown.nodes.count)
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
        guard let id, id != inserted, let ws = workspaces[id] else { return true }
        guard !ws.isArchived, !(o.foldsDone && ws.taskStatus == .done) else { return false }
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
