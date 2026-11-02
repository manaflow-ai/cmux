import AppKit
import CmuxNextDesign
import QuartzCore

// A group's fold (Lawrence 2026-10-20: "opening and closing sidebar workspace groups still lags too much ... users
// will have thousands"). The fold is view state the sidebar owns (plans/cmux-next/state-ownership-DESIGN.md): the
// model writes the one group (`SidebarModel.setGroupCollapsed`), and the list splices that group's rows into the
// layout it shows (`SidebarLayout.folding`) and moves only the row views it has (the visible ones). Nothing here
// visits every row, so a fold costs the same with 10,000 workspaces as with 100.
extension SidebarListViewComponents {
    /// Draws group `id`'s fold as the model now holds it: the group's rows spliced, the realized rows moved. Falls
    /// back to a full reload when a drag, a filter or another layout mode owns the rows.
    func foldGroup(_ id: GroupID) {
        guard let group = model.group(id), let section = model.groupSection(id),
              drag == nil, settling == nil, landing == nil, external == nil, rowHold.isEmpty, !isShiftingViewport,
              !displayed.rows.isEmpty else {
            return reload(animated: true)
        }
        var o = model.listOptions()
        o.pullRequests = SidebarSessionTree.shared.pullRequests
        o.excludedWorkspaces.formUnion(leaving)
        // What the animation needs of the rows before the fold: the realized ones and the group's block. The rest of
        // the layout is spliced in place (no copy of every row).
        let old = displayed.excerpt(rowViews.keys, group: id)
        guard displayed.fold(group, collapsed: group.isCollapsed, in: section, metrics: metrics, options: o) else {
            return reload(animated: true)
        }
        SidebarPerfCounters.add(.groupFolds)
        groups[id] = group
        applyFold(from: old, group: id)
    }

    /// Shows `layout` (the displayed one with group `id` spliced): the views of rows still listed move to their
    /// frames, the rows the fold hid slide up under the header, the rows it showed come out from under it, and rows
    /// the move brought into view get views. Only realized views and the rows in the viewport are visited.
    private func applyFold(from old: SidebarLayout, group id: GroupID) {
        let previousHoverSuppression = suppressHoverEffects
        suppressHoverEffects = true
        defer {
            suppressHoverEffects = previousHoverSuppression
            updateHover()
        }
        let layout = displayed
        selectedRowKey = layout.selectedRowKey(for: model.selectedItem, in: model.sections)
        updateDocumentHeight()
        let realize = realizationRect()
        let range = layout.rowIndices(from: realize.minY, to: realize.maxY)
        // An opened group adds workspace rows: they open only with ui.animations.newWorkspace on, as in `apply` (hq-1d).
        let opensWorkspaces = range.contains { index in
            if case .workspace = layout.rows[index].key { old.row(for: layout.rows[index].key) == nil } else { false }
        }
        // Only the user's own fold moves on the spring; another client's shows in one step (calm-sidebar-movement).
        let animate = model.followsUserIntent && (!opensWorkspaces || Motion.sidebar.animates(.newWorkspace))
        var targets: [(SidebarRowView, NSRect)] = []
        var appearing: [(SidebarRowView, NSRect)] = []
        var leavingRows: [(SidebarRowView, NSRect)] = []
        // The realized rows: kept ones move, ones the fold hid leave (first, so a new row can take a parked view).
        for (key, view) in Array(rowViews) {
            if let row = layout.row(for: key) {
                let target = frame(for: row)
                view.targetSize = target.size
                if key == .group(id) { configure(view, row: row, animated: animate) } // the chevron, count and activity
                targets.append((view, target))
                continue
            }
            rowViews[key] = nil
            if key == hoveredKey {
                hoveredKey = nil
                view.clearHoverImmediately()
            }
            guard animate, let was = old.row(for: key) else {
                recycle(view)
                continue
            }
            view.isSelected = false
            view.clipsToBounds = true
            // A folded row slides up under its header.
            leavingRows.append((view, SidebarRowTransition.removeFrame(was, current: view.frame, runTop: nil, from: old, to: layout)))
        }
        // The rows in view without a view: an opened member comes out from under its header, a row the move
        // brought into view starts where it was.
        let now = CACurrentMediaTime()
        for index in range {
            let row = layout.rows[index]
            guard rowViews[row.key] == nil else { continue }
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let was = old.row(for: row.key)
            let view = dequeue(row.key, rebinding: !animate)
            view.targetSize = target.size
            configure(view, row: row, animated: false)
            view.layer?.removeAllAnimations()
            let opens = animate && was == nil
            Motion.withoutAnimation {
                if opens {
                    view.frame = SidebarRowTransition.insertFrame(row, target: target, runTop: nil, from: old, to: layout)
                    view.alphaValue = 0
                    view.clipsToBounds = true
                    view.opens += 1
                } else {
                    view.frame = animate ? was.map { frame(for: $0) } ?? target : target
                    view.alphaValue = 1
                }
            }
            if opens { openingRows[row.key] = SidebarRowOpening(until: now + Motion.sidebar.spring(.move).settlingTime()) }
            addSubview(view, positioned: .above, relativeTo: decorations)
            rowViews[row.key] = view
            if opens { appearing.append((view, target)) } else { targets.append((view, target)) }
        }
        let (lines, start) = foldLines(old: old, new: layout, group: id)
        let lineMotion = groupLineViews.update(lines, from: animate ? start : [], in: self, above: decorations, animated: animate)
        RowMotion(targets: targets, appearing: appearing, leaving: leavingRows, lines: lineMotion).run(in: self, from: old, to: layout, animated: animate)
        inlineRename.follow()
        groupEditor.follow(groups)
        if let shown = groupEditor.shownGroup { (rowViews[.group(shown)] as? GroupHeaderRowView)?.isEditing = true }
    }

    /// The group lines after group `id`'s fold: its own line from its rows (and where its rows are now, the
    /// animation's start), every line below it moved by the height change, the lines above it as they are.
    private func foldLines(old: SidebarLayout, new: SidebarLayout, group id: GroupID) -> (lines: [SidebarGroupLine], start: [SidebarGroupLine]) {
        guard let headerIndex = new.position(of: .group(id)) else { return (groupLines(new), groupLines(new, current: true)) }
        let header = new.rows[headerIndex]
        var end = headerIndex + 1
        while end < new.rows.count, new.rows[end].group == id, !new.rows[end].key.isGroupHeader { end += 1 }
        let block = Array(new.rows[headerIndex..<end])
        let own = SidebarGroupLine.lines(block, colors: groups) { frame(for: $0) }
        let start = SidebarGroupLine.lines(block, colors: groups) { self.rowViews[$0.key]?.frame ?? self.frame(for: $0) }
        let dy = new.totalHeight - old.totalHeight
        var lines = groupLineViews.lines.filter { $0.group != id }
        if dy != 0 {
            for index in lines.indices where lines[index].frame.minY > header.y { lines[index].frame.origin.y += dy }
        }
        // In list order, top to bottom, as a full rebuild lists them.
        lines.insert(contentsOf: own, at: lines.firstIndex { $0.frame.minY > header.y } ?? lines.count)
        return (lines, start)
    }
}
