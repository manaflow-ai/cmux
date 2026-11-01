import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

extension SidebarListViewComponents {
    // MARK: - Reload
    /// Recomputes layout from the model and animates rows to their frames.
    /// `fromModel`: the model changed under the list (`showModelChange`); any other animated reload
    /// is a user's gesture here, so the model change that follows it may animate too.
    func reload(animated: Bool, adopt: Bool = false, fromModel: Bool = false, file: StaticString = #fileID, line: UInt = #line) {
        SidebarPerfCounters.add(.listReloads, from: file, line: line)
        if animated, !fromModel { model.noteUserIntent() }
        holdsModelChange = false // this reload shows the model as it is now
        // No drag holds the rows: this reload shows every held patch (the model has them).
        if !holdsRowPatches { rowHold = SidebarRowHold() }
        workspaces = [:]
        groups = [:]
        groupSubtrees = [:]
        sections = [:]
        listItems = [:]
        // The sections the layout draws: a workspace id two machines list is the first one's row, content and place alike.
        for section in SidebarLayout.listingEachWorkspaceOnce(listSections) {
            sections[section.id] = section
            for node in section.nodes {
                switch node {
                case let .workspace(ws): workspaces[ws.id] = ws
                case let .group(group):
                    groups[group.id] = group
                    if groupSubtrees[group.id] == nil { groupSubtrees[group.id] = [group.id] }
                    var ancestor = group.parent, seen: Set<GroupID> = [group.id]
                    // A malformed parent chain (a cycle) stops at the first group seen again.
                    while let id = ancestor, groupSubtrees[id] != nil, seen.insert(id).inserted {
                        groupSubtrees[id]?.append(group.id)
                        ancestor = groups[id]?.parent
                    }
                    for ws in group.workspaces { workspaces[ws.id] = ws }
                    for member in group.items { listItems[member.item.id] = member.item } // a group's link, tab or app member row
                case let .item(item): listItems[item.id] = item
                }
            }
        }
        if let drag, !drag.isValid(in: model) { cancelDrag() }
        // The rows changed under a held drag (a batch, an adopt, a close): its hit geometry is rebuilt at the next move.
        if let drag, drag.geometryRevision != model.sectionsRevision { drag.docGeometry = nil }
        if let drag, drag.group.map({ $0.revision != model.sectionsRevision }) == true { rebaseGroupDrag(drag) }
        let settled = settleDrop()
        // A drag's look hands over to the model on the same spring (DESIGN "Drag feel" 6).
        // Also a non-animated reload (provisional rows, a space switch) under a held drag or a settle: rows never snap then.
        // A settled drop's card still flying is part of the drop: a later reload (the blocks after the rows) adopts too.
        springsRows = (animated && adopt) || settled != nil || drag != nil || settling != nil || landing?.landsOnModel == true
        defer { springsRows = false }
        // A removed workspace's card ends on the geometry check after the
        // rows apply (its anchor is gone); a kept one updates in place.
        if let shown = hoverCard.shownID { hoverCards.contentChanged(WorkspaceHoverCardController.targetID(shown)) }
        let layout = displayLayout()
        // Focus belongs to a displayed disclosure, so a structural reload clears it before
        // row reuse can configure the same view for a later fold.
        if let key = focusedFold, layout.row(for: key) == nil {
            SidebarGroupKeys(list: self).setFocus(nil)
        }
        SidebarPerfCounters.timed { applyKeepingViewport(layout, animated: animated) }
        if let settled { landSettled(settled) } else { followLanding() }
        inlineRename.follow()
        groupEditor.follow(groups)
        if let shown = groupEditor.shownGroup { (rowViews[.group(shown)] as? GroupHeaderRowView)?.isEditing = true }
        // The settle ended in this reload with its card already gone (no landing to finish): the held rows show now.
        releaseRowHold()
    }
    func options(includeGap: Bool) -> SidebarLayoutOptions {
        var o = model.listOptions()
        o.showsSoleMachineHeader = true
        o.pullRequests = SidebarSessionTree.shared.pullRequests
        if let tree = SidebarSessionTree.shared.drawn {
            (o.sessionTree, o.keycaps) = (tree, model.workspaceKeycaps(DesignSettings.shared.sidebarSections.navigation))
            o.chatHistory = SidebarChatHistory.shared.state
        }
        o.excludedWorkspaces.formUnion(leaving)
        (o.openDoneFolds, o.openShowMore) = (openDoneFolds, openShowMore)
        // A drag keeps the "Done (N)" rows folded, so its lift and its drop move no other row (ask-13d9bbd5e3): a drop
        // resolves by the drawn rows' model indexes, which a fold leaves as they are, and a drop gap at an index the
        // fold hides opens before the next drawn row (`SidebarLayout.gapEntry`). "Show N more" (off by default) still
        // opens while a drag runs: its limit counts rows, so the drag's base rows (without the dragged ones) and the
        // drop's result would show different rows.
        if shownDrag != nil || external != nil { o.rowLimit = 0 }
        // External tab drops still use the older reducer: keep its unfolded group-exit geometry and visible tab slots.
        if external != nil { (o.foldsDone, o.foldsArchived, o.archiveSection) = (false, false, false) }
        if includeGap, case let .newWorkspace(section, group, index)? = external?.proposal {
            o.gap = DropPosition(section: section, group: group, index: index)
            o.gapHeight = metrics.rowHeight
        }
        o.blockHeights = blockHeights(includeGap: includeGap)
        o.collapsedDocSections = Set(model.collapsedLayoutSections.map(\.rawValue))
        if let blocks, let moving = shownDrag?.docItems.map(Set.init) {
            o.emptyDocSections = Set(blocks.sections.filter { $0.value.items.allSatisfy { moving.contains($0.id.rawValue) } }.keys)
        }
        guard let drag = shownDrag else { return o }
        if drag.docItems != nil { o.showEmptyPinned = true } // an empty Pinned takes a drop on the document
        switch drag.payload {
        case let .workspaces(ids):
            o.excludedWorkspaces.formUnion(ids)
            o.showEmptyPinned = true
            // A drag that carries a Done row draws unfolded: the fold would move it out of the slot or add a fold row.
            if SidebarLayout.dragUnfolds(ids.compactMap { model.workspace($0) }, options: o) { (o.foldsDone, o.foldsArchived, o.archiveSection) = (false, false, false) }
        case let .group(group):
            o.excludedGroup = group
        case let .item(item):
            o.excludedItem = item
        }
        if includeGap, drag.pinTarget == nil, drag.group == nil, case let .position(position) = drag.target {
            o.gap = position
            o.gapHeight = drag.gapHeight
        }
        return o
    }
    func frame(for row: SidebarRow) -> NSRect {
        // A block's region draws its own insets, as the band did.
        if case .block = row.key { return NSRect(x: 0, y: row.y, width: bounds.width, height: row.height) }
        // The one indent rule (`SidebarIndent`): from the drawn tree, a top-level group's rows flush with ungrouped
        // rows (#23975), each deeper level one gutter in, capped in a narrow list.
        let gutter = indentOffset(for: row)
        // A group header reaches left over its members' rail (`groupRailReach`): the rail and the bar share one left edge.
        let reach = railReach(for: row)
        // Rows end `rowTrailingTrim` short of the list's right inset, so a row's pill never runs to
        // the sidebar's edge (Leo 2026-10-20, Chrome's vertical tabs).
        return NSRect(x: inset + gutter - reach, y: row.y,
                      width: max(0, bounds.width - inset * 2 - gutter - SidebarStyle.rowTrailingTrim) + reach, height: row.height)
    }
    /// How far left of its members' x `row` starts: a group header's reach over its rail (`SidebarStyle.groupLineX`)
    /// and the line layout's overhang past it (`groupHeaderOverhang`), never past the list's edge; 0 for other rows.
    func railReach(for row: SidebarRow) -> CGFloat {
        guard case .group = row.key else { return 0 }
        let membersX = inset + indentOffset(for: row)
        return membersX - SidebarStyle.groupBarX(membersMinX: membersX)
    }
    /// Whether `group` sits somewhere under `ancestor`, by the groups' parent links (cycle-safe).
    static func isNested(_ group: SidebarGroup, under ancestor: GroupID, in groups: [GroupID: SidebarGroup]) -> Bool {
        var current = group.parent
        var seen = Set<GroupID>()
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = groups[id]?.parent
        }
        return false
    }
    /// The indent rule every row, rail, lifted card and drop line of this list uses.
    var indent: SidebarIndent { SidebarIndent(step: SidebarStyle.groupGutter) }
    /// The width a level-0 row has: the indent cap is computed from it.
    var indentWidth: CGFloat { max(0, bounds.width - inset * 2 - SidebarStyle.rowTrailingTrim) }
    /// How far `row` moves in from the list's inset.
    func indentOffset(for row: SidebarRow) -> CGFloat {
        indent.offset(level: row.indentLevel, width: indentWidth)
    }
    func realizationRect() -> NSRect {
        // A space page never scrolls: the rows in its frame, no overscan.
        if enclosingScrollView == nil, let pageViewport { return pageViewport }
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        return visible.insetBy(dx: 0, dy: -SidebarStyle.overscan)
    }
    /// `newRowsInPlace`: a reveal jumps after this apply. A new row this apply gives no view (outside the rows drawn
    /// now) is not opening: the jump draws it whole in its slot (`RowMotion.place`), since its gap is open by then and
    /// a row growing from nothing there would show an empty slot. A new row this apply draws opens with its gap.
    func apply(_ layout: SidebarLayout, animated: Bool, newRowsInPlace: Bool = false) {
        let previousHoverSuppression = suppressHoverEffects
        suppressHoverEffects = true
        defer { suppressHoverEffects = previousHoverSuppression }
        defer { updateHover() }
        let old = displayed
        displayed = layout
        onApply?(layout)
        groupEditing.adoptReidentified(from: old, to: layout)
        selectedRowKey = layout.selectedRowKey(for: model.selectedItem, in: model.sections)
        updateDocumentHeight()
        let realize = realizationRect()
        var targets: [(SidebarRowView, NSRect)] = []
        var appearing: [(SidebarRowView, NSRect)] = []
        var keep = Set<SidebarRowKey>()
        let adopting = springsRows && !old.rows.isEmpty
        // A new workspace row (Cmd-N, a script, another client) opens only with ui.animations.newWorkspace on (hq-1d).
        let insertsWorkspace = layout.rows.contains { if case .workspace = $0.key { old.row(for: $0.key) == nil } else { false } }
        let animate = !adopting && animated && !old.rows.isEmpty && (!insertsWorkspace || Motion.sidebar.animates(.newWorkspace))
        // New rows open from their run's top, so only the rows below move. A row still opening that the next update
        // only pushes (Cmd-N held: each new workspace lands at the top and pushes the ones still opening down) keeps
        // its view, its content and its open: its frame retargets on the additive springs from what shows, its fade
        // goes on to 1, and it clips until its own open ends (Lawrence 2026-10-28, sidebar-burst-motion.md: reopening
        // it in a new, empty and transparent view on every key left only empty slots until the repeat stopped). A row
        // still opening that moved by itself (shown at the daemon's slot, then placed below the current one) opens
        // again there, in a new view: carried across the list half open, it would cross the rows (cx-ai79).
        let now = CACurrentMediaTime()
        // How the rows make room for a new workspace row (`sidebar.insertMotion`, Leo 2026-10-21: "when you create a
        // workspace at the top it's a huge cascade"). Only for a change that only adds rows, among them workspaces new
        // to the model: one that also closes, moves or hides a row, or that lists a workspace again (a group's expand, a
        // filter, "Show more"), moves every row as before, on `.move` over the whole distance.
        let insertMotion = animate && insertsWorkspace && onlyAdds(layout, to: old) && opensOnlyNewWorkspaces(layout, from: old)
            ? SidebarInsertMotion.tunable.value : nil
        appliedSections = model.sections
        // A row is opening until the spring it opens on settles (`.move`, or the insert motion's shorter one): past that
        // a later move moves it, it does not open it again. A change that moves nothing settles every open now
        // (`settleOpenings`), and a row no longer listed has none.
        let opensRows = animate && Motion.sidebar.animatesMovement && window != nil && Motion.canAnimate(in: self)
        if opensRows {
            openingRows = openingRows.filter { $0.value.until > now && layout.row(for: $0.key) != nil }
        } else {
            settleOpenings()
        }
        let reopened = animate ? Self.movedByThemselves(openingRows.keys, from: old, to: layout) : []
        let insertRuns = SidebarRowTransition.runTops(of: layout, missingFrom: old, reopened: reopened)
        // How far the rows travel: the nudge, never past the shortest run of new rows (a row below never starts above them).
        let insertTravel = insertMotion.flatMap { motion in
            SidebarInsertMotion.travel(motion.travel(nudge: SidebarInsertMotion.nudgeDistance.value),
                                       within: SidebarInsertMotion.shortestRun(insertRuns) { layout.row(for: $0).map { $0.y + $0.height } })
        }
        let nudge = insertTravel ?? 0
        // Snap and a zero nudge open nothing: the new rows stand at their slots (one realized later shows there at once).
        if insertTravel != 0, opensRows {
            let opening = SidebarRowOpening(until: now + Motion.sidebar.spring(insertMotion?.token ?? .move).settlingTime(),
                                            motion: insertMotion, travel: insertTravel)
            // A new row outside the rows drawn now before a reveal jump does not open (``apply(_:animated:newRowsInPlace:)``).
            for row in layout.rows where (old.row(for: row.key) == nil && (!newRowsInPlace || frame(for: row).intersects(realize)))
                || reopened.contains(row.key) { openingRows[row.key] = opening } // only animated applies open rows (hq-1d)
        } else {
            // A row this change moves while still opening stands at its new slot: it must not keep an earlier insert's
            // motion and replay it when realized later.
            for key in reopened { openingRows[key] = nil }
        }
        // Without motion the rows that leave park first (as they would after the loop), so the rows that
        // come take their views: a space switch reuses the old space's views, it makes none (space-switch-fast).
        // RowMotion also snaps when sidebar movement is disabled (Reduce Motion or the sidebar switch),
        // even though `animate` is true. Park leaving views before that snap realizes replacements too.
        if (!animate || !Motion.sidebar.animatesMovement), !adopting {
            // An animated apply removes a leaving row from `rowViews` but keeps it in the list until its
            // close finishes. A no-motion reload can arrive before that completion and otherwise leave the
            // old, still-visible row's spring running beside a newly realized row for the same key.
            let active = Set(rowViews.values.map { ObjectIdentifier($0) })
            for view in subviews.compactMap({ $0 as? SidebarRowView })
                where !view.isHidden && !active.contains(ObjectIdentifier(view)) {
                recycle(view)
            }
            for (key, view) in rowViews where layout.row(for: key) == nil {
                rowViews[key] = nil
                recycle(view)
            }
        }
        for row in layout.rows {
            let target = frame(for: row)
            if reopened.contains(row.key) { rowViews.removeValue(forKey: row.key)?.removeFromSuperview() }
            let existing = rowViews[row.key]
            guard existing != nil || target.intersects(realize) else { continue }
            keep.insert(row.key)
            // Without motion (a space switch, a page) any parked view of the kind serves, as a scroll's
            // does: a space's rows then make no new views once the pool holds some (space-switch-fast).
            let view = existing ?? dequeue(row.key, rebinding: !animate && !adopting)
            view.targetSize = target.size
            // A recycled view (a block's region from another time) takes its content at once, not on a spring.
            configure(view, row: row, animated: animate || (adopting && existing != nil))
            // A row new to the layout, one that moved by itself, or one still opening that scrolls in with no view
            // (it opens in place, as `RowMotion.place` opens one on a scroll).
            let opens = animate && existing == nil
                && (old.row(for: row.key) == nil || reopened.contains(row.key) || openingRows[row.key] != nil)
            if existing == nil || opens {
                // The start state never animates: a recycled view shows no
                // frame of its previous row (cx-bqm6).
                view.layer?.removeAllAnimations()
                Motion.withoutAnimation {
                    if opens {
                        // An inserted row grows from its run's top; an expanded one comes out from under its header.
                        let opening = SidebarRowTransition.insertFrame(row, target: target, runTop: insertRuns[row.key], from: old, to: layout)
                        view.frame = insertMotion?.openFrame(opening, target: target, nudge: nudge) ?? opening
                        view.alphaValue = 0
                        view.clipsToBounds = true
                        view.opens += 1
                    } else {
                        view.frame = animate ? old.row(for: row.key).map { frame(for: $0) } ?? target : target
                    }
                }
            }
            // A parked view (`recycle`) keeps its old place in the stack: put it at the bottom of the rows,
            // as a new one, so it never draws over a block that a move raised (scroll realization skips this).
            if existing == nil { addSubview(view, positioned: .above, relativeTo: decorations); rowViews[row.key] = view }
            // Adopting: a row new to the list fades in at its slot (adoptRows), one only scrolled in shows at once.
            if adopting, existing == nil { view.alphaValue = old.row(for: row.key) == nil ? 0 : 1 }
            if suppressed.contains(row.key) {
                view.frame = target
                view.alphaValue = 0
            } else if opens {
                appearing.append((view, target))
            } else {
                targets.append((view, target))
            }
        }
        // An empty section's placeholder and the section's rows hand off at
        // once, both ways, so neither fades out under the other.
        let returning = Set(layout.rows.compactMap { row -> SectionID? in
            guard case let .emptySection(section) = row.key, old.row(for: row.key) == nil else { return nil }
            return section
        })
        // So do an empty group's row and the group's last member.
        let emptied = Set(layout.rows.compactMap { row -> GroupID? in
            guard case let .emptyGroup(group) = row.key, old.row(for: row.key) == nil else { return nil }
            return group
        })
        var leaving: [(SidebarRowView, NSRect)] = []
        let removeRuns = SidebarRowTransition.runTops(of: old, missingFrom: layout)
        for (key, view) in rowViews where !keep.contains(key) {
            if key == hoveredKey {
                hoveredKey = nil
                view.clearHoverImmediately()
                view.layoutSubtreeIfNeeded()
            }
            rowViews[key] = nil
            let placeholder = switch key { case .emptySection, .emptyGroup: true; default: false }
            let replaced = old.row(for: key).map { returning.contains($0.section) || $0.group.map(emptied.contains) == true } ?? false
            if adopting, !suppressed.contains(key) {
                // A row the drop or the model took away fades where it is (its slot closes on the rows' spring).
                leaving.append((view, view.frame))
            } else if suppressed.contains(key) || !animate || placeholder || replaced {
                recycle(view)
            } else {
                // A leaving row fades out without the selection fill: the
                // fill is already on the new selected item (no second one).
                view.isSelected = false
                // A collapsed row slides up under its header; another leaving row closes its slot.
                let current = view.frame
                let end = old.row(for: key).map { SidebarRowTransition.removeFrame($0, current: current, runTop: removeRuns[key], from: old, to: layout) }
                view.clipsToBounds = true
                leaving.append((view, end ?? NSRect(x: current.minX, y: current.minY, width: current.width, height: 0)))
            }
        }
        // Only an external drop's new-workspace slot has an underlay (R77: a row drag reorders in place).
        let gapFrame = layout.gapHeight > 0 ? layout.gapY.map { NSRect(x: inset, y: $0, width: indentWidth, height: layout.gapHeight) } : nil
        decorations.frame = bounds
        decorations.setGap(gapFrame, animated: animate || adopting)
        let history = chatHistory.place(layout, state: SidebarChatHistory.shared.state, metrics: model.minimal ? metrics.minimal : metrics,
                                        in: self, animated: animate || adopting)
        let lines = groupLineViews.update(groupLines(layout), from: animate || adopting ? groupLines(layout, current: true) : [], in: self, above: decorations,
                                          animated: animate || adopting)
        if adopting {
            SidebarDragSpring.move(history + lines.springs, in: self)
            return adoptRows(targets: targets, leaving: leaving, lines: lines)
        }
        RowMotion(targets: targets, appearing: appearing, leaving: leaving, lines: lines, companions: history, insert: insertMotion,
                  travel: insertTravel)
            .run(in: self, from: old, to: layout, animated: animate)
    }
    /// The rows of `keys` (still opening) that `layout` moved by themselves, not with the rows around them: both
    /// rows beside each, among the rows of both layouts, changed (as `ListViewport.movedByItself`). A row an insert or
    /// a removal near it only pushes, or one whose neighbour moved away, keeps at least one of its neighbours.
    static func movedByThemselves(_ keys: some Collection<SidebarRowKey>, from old: SidebarLayout, to layout: SidebarLayout) -> Set<SidebarRowKey> {
        guard !keys.isEmpty else { return [] }
        let both = Set(old.rows.map(\.key)).intersection(layout.rows.map(\.key))
        func neighbours(_ rows: [SidebarRow]) -> [SidebarRowKey: (before: SidebarRowKey?, after: SidebarRowKey?)] {
            let kept = rows.map(\.key).filter(both.contains)
            var result: [SidebarRowKey: (before: SidebarRowKey?, after: SidebarRowKey?)] = [:]
            for (index, key) in kept.enumerated() {
                result[key] = (index > 0 ? kept[index - 1] : nil, index + 1 < kept.count ? kept[index + 1] : nil)
            }
            return result
        }
        let was = neighbours(old.rows), now = neighbours(layout.rows)
        return Set(keys.filter { key in
            guard let then = was[key], let next = now[key] else { return false }
            return then.before != next.before && then.after != next.after
        })
    }

    /// Ends every row's open at once: the rows were placed without motion (a change that does not animate, Reduce Motion,
    /// a list out of a window, the display's sleep), so a row realized later shows at its slot instead of replaying an
    /// open that already ended. The one way `openingRows` is cleared before its deadlines.
    func settleOpenings() {
        if !openingRows.isEmpty { openingRows.removeAll() }
    }

    /// `layout` is `old` with rows added and none taken away or moved past another: every row of `old` is still listed,
    /// in the same order. Only then do the rows below make room by the new row motion (`sidebar.insertMotion`); a
    /// change that also closes, hides or reorders rows moves them all as before.
    func onlyAdds(_ layout: SidebarLayout, to old: SidebarLayout) -> Bool {
        var last = -1
        for row in old.rows {
            guard let position = layout.position(of: row.key), position > last else { return false }
            last = position
        }
        return true
    }

    /// Every workspace row `layout` lists and `old` does not is a workspace the model did not hold at the last apply
    /// (`appliedSections`): a new one, not one a group's expand, a filter or "Show more" lists again. Reads the model's
    /// workspaces only when such a row exists, and then once.
    func opensOnlyNewWorkspaces(_ layout: SidebarLayout, from old: SidebarLayout) -> Bool {
        var known: Set<WorkspaceID>?
        for row in layout.rows {
            guard case let .workspace(id) = row.key, old.row(for: row.key) == nil else { continue }
            if known == nil { known = Set(appliedSections.flatMap(\.workspaces).map(\.id)) }
            if known?.contains(id) == true { return false }
        }
        return true
    }
    func configure(_ view: SidebarRowView, row: SidebarRow, animated: Bool) {
        SidebarPerfCounters.add(.rowConfigures)
        view.isHovered = hoveredKey == row.key && drag == nil
        view.isSelected = selectedRowKey == row.key
        switch (row.key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            guard let ws = workspaces[id] else { return }
            view.configure(ws, row: row, badgeStyle: model.rowBadgeStyle)
            paintSecondaryFills(view, id)
            view.isDropTarget = external?.proposal == .intoWorkspace(id) || drag?.target == .ontoWorkspace(id) || standsForDropGroup(row)
            // A group drawn as its one row draws its header's keyboard focus ring (`SidebarGroupKeys`).
            view.isKeyboardFocused = showsFocusRing && row.standsForGroup && row.group == focusedGroup
            view.standingGroup = row.standsForGroup ? row.group.map(standingGroupAccess) : nil
        case let (.item(id), view as SidebarItemListRowView):
            guard let item = listItems[id] else { return }
            view.configure(item, favicon: item.iconAddress.flatMap { model.itemFavicon?($0) }, row: row)
        case let (.block(id), view as SidebarBlockRowView):
            guard let content = blockContent(id, includeGap: true) else { return }
            view.region.activeItem = activeTopItem
            view.region.selectedWorkspaces = selectedWorkspaces
            if springsRows, animated { view.springShow(content, width: bounds.width) } else { view.show(content, width: bounds.width, animated: animated) }
        case let (.group(id), view as GroupHeaderRowView):
            // The model's own group when the cache (rebuilt on reload) lags it: a held drag shows the live sections.
            guard var group = groups[id] ?? model.group(id) else { return }
            // `sidebar.showColors` off: the header draws as a group with no color; its stored color stays.
            if !model.showsColors { group.tint = .none }
            var details = model.groupHeaderDetails
            details.otherStates = model.detailedStatus
            // A collapsed group holding subgroups shows their unread and loading too (nested-groups prototype):
            // its header is the only row left of the whole subtree.
            if row.isCollapsed {
                let nested = (groupSubtrees[id] ?? []).filter { $0 != id }.compactMap { groups[$0] }
                if !nested.isEmpty {
                    group.workspaces += nested.flatMap(\.workspaces)
                    details.unreadCount = true
                }
            }
            // Lawrence msg 11983: open or collapsed, the header rolls up its whole subtree's most urgent state.
            // A collapsed header's group already holds its subgroups' members (above).
            var subtree = group
            if !row.isCollapsed {
                subtree.workspaces += (groupSubtrees[id] ?? []).filter { $0 != id }.compactMap { groups[$0] }.flatMap(\.workspaces)
            }
            // The chevron turns on every fold of the user's own (Lawrence msg 15763), also an opening whose new rows show
            // at once (`ui.animations.newWorkspace` off makes both the fold and a full apply step without motion).
            view.configure(group, row: row, details: details, status: subtree.statusRollUp(collapsed: row.isCollapsed),
                           animated: animated || model.followsUserIntent)
            view.railReach = railReach(for: row)
            view.isDropTarget = highlightsDropGroup(id)
        case let (.section(id), view as SectionHeaderRowView):
            guard let section = sections[id] else { return }
            view.configure(section, row: row)
        case let (.emptySection(id), view as EmptySectionRowView): view.configure(pinned: id == .pinned || id == .custom(SidebarDocStore.pinnedSection), shortcut: model.newWorkspaceShortcut)
        case let (.emptyGroup(id), view as EmptyGroupRowView): view.configure(groupID: id, groupName: groups[id]?.name ?? model.group(id)?.name ?? "")
        case let (.folder(_, folder), view as FolderHeaderRowView): view.configure(folder: folder)
        case let (.status, view as StatusHeaderRowView): view.configure(row)
        case (.doneFold, let view as SidebarDoneFoldRowView), (.showMore, let view as SidebarDoneFoldRowView):
            view.isKeyboardFocused = showsFocusRing && focusedFold == row.key
            view.configure(row)
        default:
            break
        }
    }
    func updateDocumentHeight() {
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(displayed.totalHeight, clipHeight)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }
    /// Exactly as wide as the visible clip and as tall as the rows or the clip, on every clip resize too (nxdog56),
    /// with views for the rows now in it: the rows load at init, before the clip has a size, and a resize scrolls nothing.
    func fitToClip() {
        guard let clip = enclosingScrollView?.contentView else { return }
        if frame.width != clip.bounds.width { setFrameSize(NSSize(width: clip.bounds.width, height: frame.height)) }
        // The pool parks two realization rects of rows: a space switch's leaving and returning pages.
        rowPool.limit = SidebarRowViewPool.limit(forHeight: realizationRect().height, rowHeight: metrics.rowHeight)
        updateDocumentHeight()
        realizeVisibleRows()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        // Only the realized rows have views: visit those, never every row (a live resize runs this each frame).
        for (key, view) in rowViews {
            guard let row = displayed.row(for: key) else { continue }
            let target = frame(for: row)
            view.targetSize = target.size
            view.frame = target
        }
        decorations.frame = bounds
    }
    /// Adds views for rows scrolled into range and drops far-away ones. Only
    /// the rows in range are visited (binary search by y), so a scroll costs
    /// the same with 1,000 workspaces as with 40; a new row takes a parked
    /// view of its kind instead of a new one (no animation runs here).
    func realizeVisibleRows() {
        guard !isShiftingViewport else { return }
        SidebarPerfCounters.add(.scrollRealizes)
        groupEditing.followScroll()
        let realize = realizationRect()
        for index in displayed.rowIndices(from: realize.minY, to: realize.maxY) {
            let row = displayed.rows[index]
            guard rowViews[row.key] == nil else { continue }
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let opening = openingRows[row.key].flatMap { $0.until > CACurrentMediaTime() ? $0 : nil }
            let view = dequeue(row.key, rebinding: opening == nil)
            view.targetSize = target.size
            configure(view, row: row, animated: false)
            if view.superview !== self { addSubview(view, positioned: .above, relativeTo: decorations) } // a parked view is still here (`recycle`)
            RowMotion.place(view, at: target, opening: opening, hidden: suppressed.contains(row.key), in: self)
            rowViews[row.key] = view
        }
        pruneOffscreen()
        let followed = hoverFollowsScroll
        hoverFollowsScroll = true
        defer { hoverFollowsScroll = followed }
        updateHover()
    }
    func pruneOffscreen() {
        let keepRect = realizationRect().insetBy(dx: 0, dy: -SidebarStyle.pruneMargin)
        // Only realized rows can be pruned: visit those, not every row.
        for (key, view) in rowViews {
            guard let row = displayed.row(for: key), !frame(for: row).intersects(keepRect),
                  inlineRename.session?.key != key, key != groupEditor.shownGroup.map(SidebarRowKey.group) else { continue }
            recycle(view)
            rowViews[key] = nil
        }
    }
    /// The selectable rows in visual order (placeholders left out).
    var visibleWorkspaceOrder: [WorkspaceID] {
        let placeholders = Set(model.allWorkspaces.filter { $0.rowState == .placeholder }.map(\.id))
        return displayed.rows.compactMap { if case let .workspace(id) = $0.key, !placeholders.contains(id) { id } else { nil } }
    }
}
