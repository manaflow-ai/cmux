import AppKit
import CmuxNextWakeups
import CmuxNextDesign
import QuartzCore
// Internal drag reorder: lift, in-place slot (R77), drop, cancel, auto-scroll.
extension SidebarListViewComponents {
    typealias Drag = SidebarListDrag
    func beginDrag(_ press: Press) {
        hoverCards.dismiss(.click)
        abandonSettle()
        endLanding()
        guard displayed.row(for: press.key) != nil else { return }
        let payload: DragPayload
        var hidden: Set<SidebarRowKey>
        let origin: DropTarget?
        switch press.key {
        case let .workspace(id):
            guard !model.isPlaceholder(id) else { return }
            let ids = model.selection.contains(id) ? model.orderedSelection : [id]
            if !model.selection.contains(id) { model.click(id) }
            payload = .workspaces(ids)
            hidden = Set(ids.map(SidebarRowKey.workspace))
            origin = ids.first.flatMap { SidebarEdits.position(of: $0, in: model.sections) }.map(DropTarget.position)
        case let .group(group):
            guard let (s, n) = SidebarEdits.locateGroup(group, in: model.sections) else { return }
            payload = .group(group)
            hidden = [.group(group)]
            for ws in groups[group]?.workspaces ?? [] { hidden.insert(.workspace(ws.id)) }
            for member in groups[group]?.items ?? [] { hidden.insert(.item(member.item.id)) }
            origin = .position(DropPosition(section: model.sections[s].id, index: n))
        case let .item(item):
            // A listed document item drags only on the document.
            guard model.docDrag != nil, let row = displayed.row(for: press.key) else { return }
            payload = .item(item)
            hidden = [press.key]
            origin = .position(DropPosition(section: row.section, group: row.group, index: row.siblingIndex)) // a group's member item: inside it
        case .tab, .section, .emptySection, .folder, .block:
            return
        }
        hidden.formUnion(Self.tabKeys(of: hidden, in: model))
        // A group lifts as one block: its header and the member rows under it (cx-bp40).
        let rows = SidebarListLift.rows(self, for: press.key, hidden: hidden)
        guard let rowFrame = SidebarListLift.blockFrame(self, rows), let content = SidebarListLift.content(self, rows, in: rowFrame) else { return }
        let count: Int
        if case let .workspaces(ids) = payload { count = ids.count } else { count = 1 }
        let lift = SidebarReorderLift.lift(content, count: count, frame: rowFrame, in: self)
        let drag = Drag(
            payload: payload,
            grabbedKey: press.key,
            hiddenKeys: hidden,
            grabOffsetY: press.point.y - rowFrame.minY,
            gapHeight: rowFrame.height,
            lift: lift, head: rows.first?.height,
            target: origin
        )
        drag.grabOffsetX = press.point.x - rowFrame.minX
        drag.lastY = press.point.y
        drag.restFrame = rowFrame
        if rows.first?.group != nil { // the gutter comes back only for a drop into a group (morphLift)
            drag.restFrame.origin.x -= SidebarStyle.groupGutter
            drag.restFrame.size.width += SidebarStyle.groupGutter
        }
        drag.morphs = rows.count == 1
        if case .group = payload { drag.groupHeadHeight = rows.first?.height }
        self.drag = drag
        // The document's acceptance table: the drag's one reducer call before its drop.
        if let doc = model.docDrag, let items = doc.items(payload) {
            drag.docItems = items
            drag.docAcceptance = doc.begin(items)
        }
        suppressed.formUnion(hidden)
        setHovered(nil)
        for key in hidden { rowViews[key]?.alphaValue = 0 }
        // The source slot closes on the drag's spring; the list does not reload while the drag is held.
        showDragLayout()
    }
    func updateDrag(windowPoint: NSPoint) {
        guard let drag else { return }
        let started = CACurrentMediaTime()
        defer { lastDragWorkMs = (CACurrentMediaTime() - started) * 1000 }
        if SidebarListPinDrop.holds(self, drag, at: windowPoint) { return }
        if offerHandoff(drag, windowPoint: windowPoint) { return }
        drag.lastWindowPoint = windowPoint
        let point = convert(windowPoint, from: nil)
        // The lifted row follows the pointer vertically; x stays locked. A tile has neighbours beside it: it follows both ways.
        if !drag.restShaped {
            SidebarReorderLift.follow(drag.lift, origin: CGPoint(x: point.x - drag.grabOffsetX, y: point.y - drag.grabOffsetY), visible: visibleRect)
        } else {
            SidebarReorderLift.follow(drag.lift, top: point.y - drag.grabOffsetY, visible: visibleRect)
        }
        autoscroll.update(windowPoint: windowPoint)
        let card = drag.probeCard
        if point.y != drag.lastY {
            drag.movingUp = point.y < drag.lastY
            drag.lastY = point.y
        }
        if drag.docItems != nil { return updateDocDrag(drag, point: point) }
        let sections = listSections // the held rows as shown (`SidebarRowHold`)
        let base = SidebarLayout.make(sections: sections, metrics: metrics, options: options(includeGap: false))
        let resolved = drag.resolve(card: card, displayed: displayed, base: base, sections: sections, ungroupedFirst: model.ungroupedFirst)
        guard let target = SidebarGroupDrop.gate(self, drag, card: card, resolved: resolved) else { return }
        guard target != drag.target else { return }
        drag.target = target
        drag.lift.setRefused(target == nil)
        showDragLayout()
    }
    func finishDrag() {
        guard let drag else { return }
        autoscroll.stop()
        if SidebarListPinDrop.finish(self, drag) { return }
        if let items = drag.docItems, let doc = model.docDrag {
            guard let target = drag.docTarget else { return cancelDrag() }
            // The list keeps the drop's look until the move lands; the card settles into the slot it shows.
            settling = SidebarSettlingDrop(drag: drag, revision: model.sectionsRevision, blocks: blocks)
            self.drag = nil
            // A drop is no focus change (hq-2d, cx-8quut): the reloads that show it anchor, and scroll only when the
            // focused row moved or was pushed out of view (sidebar-focused-visible, `ListViewport.settle`).
            revealedActive = model.activeWorkspaceID.map { SidebarRowKey.workspace($0) }
            let sentBefore = SidebarDocStore.current?.lastIntentKey
            doc.drop(items, target)
            settling?.key = SidebarDocStore.current?.lastIntentKey // nil already: refused inside the call
            // The drop sent nothing (no intent, e.g. an adopt still on the way): nothing will end a settle, so the
            // rows and the card go back as for a refusal.
            if settling != nil, SidebarDocStore.current?.lastIntentKey == sentBefore { settling = nil }
            suppressed = drag.hiddenKeys
            // The drop's look is what the drag shows: adopting it moves nothing (the card settles into its slot).
            reload(animated: true, adopt: true)
            // A settle that ended inside that reload already aimed the card (landSettled): keep its target.
            if landing === drag { return }
            return land(drag, at: settling == nil ? nil : settleFrame(drag))
        }
        guard let target = drag.target else { return cancelDrag() }
        self.drag = nil
        // A drop moves rows, not the list: its reloads anchor on the first visible row (cx-fnfj, cx-8quut) and reveal only
        // a focused row the drop moved or pushed out of view (sidebar-focused-visible).
        revealedActive = model.activeWorkspaceID.map { SidebarRowKey.workspace($0) }
        switch (drag.payload, target) {
        case let (.workspaces(ids), .position(position)):
            model.send(.reorder(ids, to: position))
        case let (.workspaces(ids), .intoGroup(group)):
            SidebarGroupDrop.join(self, ids, group, origin: drag.origin)
        case let (.group(group), .position(position)):
            model.send(.reorderGroup(group, index: position.index))
        case let (.workspaces(ids), .ontoWorkspace(anchor)):
            SidebarGroupDrop.group(self, ids, onto: anchor, origin: drag.origin) // The target first, then the dragged rows (Arc/Dia).
            drag.renameOnLand = anchor
        case (.group, .intoGroup), (.group, .ontoWorkspace), (.item, _):
            break
        }
        suppressed = drag.hiddenKeys // Rows land under the lifted view, stay hidden until it arrives.
        reload(animated: true, adopt: true) // the optimistic order: rows already at their slots move nothing
        land(drag)
    }
    /// A document drag's move: geometry only (no reducer call, no layout
    /// pass after the first), then the list shows the drop as before.
    private func updateDocDrag(_ drag: Drag, point: NSPoint) {
        guard let doc = model.docDrag else { return }
        if drag.docGeometry == nil {
            drag.geometryRevision = model.sectionsRevision
            drag.blockBases = blockBases()
            let base = SidebarLayout.make(sections: listSections, metrics: metrics, options: options(includeGap: false))
            drag.docGeometry = doc.geometry(base, width: bounds.width, acceptance: drag.docAcceptance, blocks: drag.blockBases)
            if drag.groupHeadHeight != nil { drag.groupBlocks = SidebarGroupReorder.blocks(of: base.rows) }
        }
        guard let (geometry, rows) = drag.docGeometry else { return }
        // The rest shape's centre under the pointer: it does not move when the card morphs (no hit oscillation at a block edge).
        // A dragged group is a tall card (its header and every member row): its header decides, where the pointer
        // holds it, not the card's centre many rows away.
        let displayY = drag.morphs || drag.tileSource != nil ? point.y - drag.grabOffsetY * drag.restFrame.height / max(1, drag.lift.frame.height)
            + drag.restFrame.height / 2 : drag.groupHeadHeight.map { drag.lift.frame.minY + $0 / 2 } ?? drag.probeCard.midY
        var y = drag.blockTarget != nil ? baseY(displayY: displayY, blockGap: drag.blockTarget, bases: drag.blockBases)
            : SidebarDragGeometry.baseY(displayY: displayY, gapY: displayed.gapY, gapHeight: displayed.gapShift)
        // A dragged group moves by its edges (u2455): its bottom past the middle of the block below moves it down,
        // its top past the middle of the block above moves it up (`SidebarGroupReorder`), for tall and short groups.
        if drag.groupHeadHeight != nil, drag.blockTarget == nil, let gapY = displayed.gapY, !drag.groupBlocks.isEmpty {
            var reorder = SidebarGroupReorder(blocks: drag.groupBlocks, shift: displayed.gapShift)
            let current = reorder.index(ofGapAt: gapY)
            // The blocks below the gap as drawn: the gap plus the spacing between groups (6 pt more than `gapShift`).
            let shown = SidebarGroupReorder.blocks(of: displayed.rows.filter { !drag.hiddenKeys.contains($0.key) })
            if current < min(shown.count, drag.groupBlocks.count) { reorder.shift = shown[current].lowerBound - drag.groupBlocks[current].lowerBound }
            let card = drag.lift.frame
            let index = reorder.index(top: card.minY, bottom: card.maxY, current: current)
            if let probe = reorder.probeY(for: index) { y = probe }
        }
        guard let hit = geometry.hit(CGPoint(x: point.x, y: y)) else {
            // Nowhere to drop: no gap shows.
            drag.docTarget = nil
            drag.lift.setRefused(true)
            if drag.target != nil || drag.blockTarget != nil {
                (drag.target, drag.blockTarget) = (nil, nil)
                showDragLayout()
            }
            return
        }
        drag.probe = SidebarDropProbe(hit, displayY: displayY, baseY: y)
        // A refused place keeps the last open gap (the drop goes there): the rows do not spring shut and open
        // again at every row the drop cannot take, and the card dims only while no gap shows.
        if hit.target == nil, drag.docTarget != nil, drag.target != nil || drag.blockTarget != nil { return }
        drag.docTarget = hit.target
        drag.lift.setRefused(hit.target == nil)
        // A list row shows the list's gap or group fill; a block's item opens a gap among the block's items.
        var target: DropTarget?
        var blockTarget: SidebarBlockGap?
        if let docTarget = hit.target {
            if let row = rows[hit.slot.key] {
                target = SidebarDocDrag.display(hit, row: row)
            } else {
                blockTarget = SidebarBlockGap(section: hit.slot.section,
                                              index: blockIndex(docTarget, section: hit.slot.section, moving: drag.docItems ?? []))
            }
        }
        guard target != drag.target || blockTarget != drag.blockTarget else { return }
        drag.target = target
        drag.blockTarget = blockTarget
        showDragLayout()
        morphLift(drag, point: point)
    }

    /// Shapes the card as the drop will look (DESIGN "Drag feel" 2): the
    /// block slot it opens (a tile, a chip, an item row), else its list row,
    /// indented under a group's line when it goes into a group. The pointer
    /// keeps the same relative grab point on the card.
    func morphLift(_ drag: Drag, point: NSPoint) {
        guard drag.morphs || drag.tileSource != nil else { return }
        var shape = drag.restFrame
        var rest = true
        if let gap = drag.blockTarget, let slot = blockSlotFrame(gap) {
            shape = slot
            rest = false
        } else if drag.tileSource != nil || drag.restShaped == false {
            shape = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: metrics.rowHeight)
        }
        if rest, case let .position(position)? = drag.target, position.group != nil {
            shape.origin.x = inset + SidebarStyle.groupGutter
            shape.size.width = max(0, bounds.width - inset * 2 - SidebarStyle.groupGutter)
        }
        let old = drag.lift.frame
        guard shape.size != old.size || (rest && shape.minX != old.minX) else { return }
        let sx = old.width > 0 ? shape.width / old.width : 1, sy = old.height > 0 ? shape.height / old.height : 1
        drag.grabOffsetX *= sx
        drag.grabOffsetY *= sy
        drag.restShaped = rest
        let x = rest ? shape.minX : point.x - drag.grabOffsetX
        drag.lift.morph(to: NSRect(x: x, y: point.y - drag.grabOffsetY, width: shape.width, height: shape.height))
    }

    func cancelDrag() {
        guard let drag else { return }
        autoscroll.stop()
        SidebarListPinDrop.end(self)
        self.drag = nil
        press?.cancelled = true
        if let source = drag.tileSource { drag.tileRegion?.docSpentPress = source.item } // the tile's press drags nothing more
        suppressed = drag.hiddenKeys
        reload(animated: true, adopt: true) // the gap closes and the source slot opens on the drag's spring
        land(drag)
    }
    /// Flies the lifted view to its row's current frame (or `slot`, the
    /// band slot of a pin drop), then swaps it out and runs `then`.
    func land(_ drag: Drag, at slot: NSRect? = nil, then: (@MainActor () -> Void)? = nil) {
        let tile = drag.tileSource.flatMap { source in drag.tileRegion?.itemView(source.item).map { convert($0.bounds, from: $0) } }
        // The dragged rows where the layout just applied puts them (their views' model frames), not the
        // `displayed` geometry: on the document path that can lag the views a held drag moved (ptr5: 36 pt pops).
        let destination = slot ?? tile ?? settledFrame(drag.hiddenKeys.compactMap { rowViews[$0] })
            ?? SidebarListLift.blockFrame(self, SidebarListLift.rows(self, for: drag.grabbedKey, hidden: drag.hiddenKeys)) ?? drag.lift.frame
        landing = drag
        drag.landingThen = then
        SidebarReorderLift.land(drag.lift, at: destination) { [weak self] in
            guard let self else {
                drag.lift.removeFromSuperview()
                then?()
                return
            }
            // Landed before the model shows the drop: the card holds its slot until it does (no empty slot, no pop).
            if self.settling?.drag === drag {
                self.settling?.landed = true
                self.settling?.then = then
                return
            }
            self.finishLand(drag, then: then)
        }
    }

    /// The card is in its slot and the model shows it: the rows under it show and the card goes, in one transaction.
    func finishLand(_ drag: Drag, then: (@MainActor () -> Void)?) {
        // Ended already (a new drag or a detach ended the flight; the card's own completion comes after).
        guard drag.lift.superview != nil else { return }
        defer { then?() }
        if landing === drag { landing = nil }
        drag.landsOnModel = false
        drag.landingThen = nil
        Motion.withoutAnimation {
            drag.lift.removeFromSuperview()
            // The dropped item, held invisible under the flying card (landSettled), shows in the same transaction.
            for view in drag.heldViews where view.isDescendant(of: self) { // a recycled view draws another row now
                view.layer?.removeAnimation(forKey: "opacity")
                view.alphaValue = 1
            }
            drag.heldViews = []
            // A drag running now keeps its own hidden rows (it may have grabbed the held item through the card).
            let shown = drag.hiddenKeys.union(drag.heldKeys).subtracting(self.drag?.hiddenKeys ?? [])
            suppressed.subtract(shown)
            for key in shown { rowViews[key]?.alphaValue = 1 }
            drag.heldKeys = []
            // A lifted group's line rode on the card; the applies under the flight left it out while its rows were
            // hidden. It shows with its rows, in this transaction (u2455: it came back only at the next click).
            groupLineViews.showMissing(groupLines(displayed), in: self, above: decorations)
        }
        updateHover()
        // The rows the ticks patched meanwhile show their new content now, together (`SidebarRowHold`).
        releaseRowHold()
        if let anchor = drag.renameOnLand { inlineRename.beginGroup(of: anchor) }
    }

    /// A new drag starts while a card still flies (the card takes no pointer: the held item can be grabbed
    /// through it): the old card ends where it is and its held views show, before the new drag hides its own.
    func endLanding() {
        if let landing { finishLand(landing, then: landing.landingThen) }
    }

    /// A new drag starts while a drop still settles: the old card finishes where it is.
    func abandonSettle() {
        guard let held = settling else { return }
        settling = nil
        if held.landed { finishLand(held.drag, then: held.then) }
    }

    /// A settle ended (the model shows the drop): the card goes to the
    /// dropped item's real frame if the model put it elsewhere, else it
    /// finishes where it is (now, if it already landed).
    func landSettled(_ settled: SidebarSettlingDrop) {
        let drag = settled.drag
        guard drag.lift.superview != nil else { return }
        drag.landsOnModel = true
        if let real = holdDropped(drag), !sameFrame(real, drag.lift.frame) { return land(drag, at: real, then: settled.then) }
        if settled.landed { finishLand(drag, then: settled.then) }
    }

    /// A reload while a settled drop's card still flies: the model can reach the list in more than one reload
    /// (the rows, then the blocks a layout pass later; ptr8: the card aimed 24 pt off at the first one). The card
    /// retargets, on its spring, to where the model shows the item now, and the item's new views stay hidden under it.
    func followLanding() {
        guard let drag = landing, drag.landsOnModel, drag.lift.superview != nil, settling?.drag !== drag,
              let real = holdDropped(drag), !sameFrame(real, drag.lift.frame) else { return }
        land(drag, at: real, then: drag.landingThen)
    }

    /// The model's item is under the card: the views that draw it now stay invisible until the card is gone (no
    /// double, no fade-in pop); a view held before that no longer draws it shows again. Returns the item's frame.
    func holdDropped(_ drag: Drag) -> NSRect? {
        let (views, keys, frame) = dropped(drag)
        let released = drag.heldKeys.subtracting(keys).subtracting(drag.hiddenKeys)
        suppressed.subtract(released)
        suppressed.formUnion(keys)
        // A view held before that no longer draws the item: a row shows again only if it still draws a row the
        // layout shows and nothing else hides (a recycled or fading view keeps its own state, a fade-out runs on);
        // a tile stays held and shows when the card goes.
        var kept: [NSView] = []
        Motion.withoutAnimation {
            for view in drag.heldViews where view.isDescendant(of: self) && !views.contains(where: { $0 === view }) {
                guard let row = view as? SidebarRowView else { kept.append(view); continue }
                guard rowViews[row.key] === row, displayed.row(for: row.key) != nil, !suppressed.contains(row.key),
                      view.layer?.animation(forKey: "opacity") == nil else { continue }
                view.alphaValue = 1
            }
            for view in views {
                view.layer?.removeAnimation(forKey: "opacity")
                view.alphaValue = 0
            }
        }
        drag.heldViews = views + kept
        drag.heldKeys = keys
        return frame
    }

    /// What draws a document drop's item as the layout just applied: its list rows (a workspace or group row, a
    /// group's header and members, a listed item; a tile dropped into the list lands as a row), else its tiles in a
    /// block. The frame is the rows' layout frames unioned (a group's whole block, realized or not: the row
    /// views' springs may still move), else the tiles' model frames.
    func dropped(_ drag: Drag) -> (views: [NSView], keys: Set<SidebarRowKey>, frame: NSRect?) {
        let items = Set(drag.docItems ?? [])
        let rows = displayed.rows.filter { row in
            if case .block = row.key { return false }
            return drag.hiddenKeys.contains(row.key) || model.docDrag?.item(row.key).map(items.contains) == true
        }
        if !rows.isEmpty {
            let frames = rows.map { frame(for: $0) }
            let views = rows.compactMap { rowViews[$0.key] }.filter { !($0 is SidebarBlockRowView) }
            return (views, Set(rows.map(\.key).filter { rowViews[$0] != nil }), frames.dropFirst().reduce(frames[0]) { $0.union($1) })
        }
        var views: [NSView] = []
        for id in drag.docItems ?? [] {
            for case let block as SidebarBlockRowView in rowViews.values {
                if let view = block.region.itemView(LayoutItemID(id)) { views.append(view) }
            }
        }
        return (views, [], settledFrame(views))
    }

    /// The frame `views` cover in the list once their springs end: their model frames (additive springs leave
    /// the model at the final value; the presentation may still move), unioned. Nil without a view in the list.
    func settledFrame(_ views: [NSView]) -> NSRect? {
        let frames = views.filter { $0.isDescendant(of: self) }.map { convert($0.bounds, from: $0) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - The drag's look (DESIGN "Drag feel" 3)

    /// Shows the held drag's look: the layout with the source slot closed
    /// and the target's gap open (a pure layout, `displayLayout`), reached
    /// by the drag's one additive spring on every realized row, block,
    /// tile, card and group line. No reload, no apply, no configure: the
    /// rows keep their views and content; only geometry moves. A retarget
    /// mid-flight continues from what is on screen (`SidebarDragSpring`).
    func showDragLayout() {
        let layout = displayLayout()
        displayed = layout
        updateDocumentHeight()
        let realize = realizationRect()
        for row in layout.rows {
            let target = frame(for: row)
            guard let view = rowViews[row.key] else {
                // A row the look adds (an empty Pinned that takes the drop) fades in at its slot.
                guard target.intersects(realize) else { continue }
                let view = dequeue(row.key)
                view.targetSize = target.size
                configure(view, row: row, animated: false)
                view.layer?.removeAllAnimations()
                Motion.withoutAnimation {
                    view.frame = target
                    view.alphaValue = 0
                }
                addSubview(view, positioned: .above, relativeTo: decorations)
                rowViews[row.key] = view
                if !suppressed.contains(row.key) { SidebarDragSpring.fade(view, to: 1) }
                continue
            }
            view.targetSize = target.size
            if suppressed.contains(row.key) {
                Motion.withoutAnimation { view.frame = target }
                continue
            }
            SidebarDragSpring.move(view, to: target)
            SidebarDragSpring.fade(view, to: 1)
            switch (row.key, view) {
            case let (.block(id), block as SidebarBlockRowView):
                if let content = blockContent(id, includeGap: true) { block.springShow(content, width: bounds.width) }
            case let (.workspace(id), rowView as WorkspaceRowView):
                rowView.isDropTarget = drag?.target == .ontoWorkspace(id)
            case let (.group(id), header as GroupHeaderRowView):
                header.isDropTarget = drag?.target == .intoGroup(id)
            default:
                break
            }
        }
        // A row the look leaves out (a placeholder a gap replaces) fades where it is; the next apply recycles it.
        for (key, view) in rowViews where layout.row(for: key) == nil && !suppressed.contains(key) {
            SidebarDragSpring.fade(view, to: 0)
        }
        // A tile dropped among rows opens the list's slot underlay with the rows.
        let gapFrame = layout.gapHeight > 0 ? layout.gapY.map { NSRect(x: inset, y: $0, width: max(0, bounds.width - inset * 2), height: layout.gapHeight) } : nil
        decorations.frame = bounds
        decorations.setGap(gapFrame, animated: true)
        let lines = groupLineViews.update(groupLines(layout), from: groupLines(layout, current: true), in: self, above: decorations, animated: true)
        Motion.animate(.move, in: self, { lines.changes() }, completion: { [leaving = lines.leaving] in leaving.forEach { $0.removeFromSuperview() } })
    }

    /// An adopting apply's motion: kept rows spring from where they are,
    /// new ones fade in at their slots, leaving ones fade where they are.
    func adoptRows(targets: [(SidebarRowView, NSRect)], leaving: [(SidebarRowView, NSRect)],
                   lines: (changes: () -> Void, leaving: [NSView])) {
        for (view, target) in targets {
            SidebarDragSpring.move(view, to: target)
            SidebarDragSpring.fade(view, to: 1)
        }
        Motion.animate(.move, in: self, { lines.changes() }, completion: { [leaving = lines.leaving] in leaving.forEach { $0.removeFromSuperview() } })
        guard !leaving.isEmpty else { return }
        // The motion probe keeps sampling a fading row until it is gone (a fade is not a pop).
        for (view, _) in leaving { fadingRows[ObjectIdentifier(view)] = view }
        Motion.animate(.hover, in: self, {
            for (view, _) in leaving { view.animator().alphaValue = 0 }
        }, completion: { [weak self, leaving] in
            guard let self else { return }
            for (view, _) in leaving {
                self.fadingRows[ObjectIdentifier(view)] = nil
                if !self.rowViews.values.contains(where: { $0 === view }) { self.recycle(view) }
            }
        })
    }
}

/// Two frames within half a point on every edge (a landing that needs no retarget).
private func sameFrame(_ a: NSRect, _ b: NSRect) -> Bool {
    abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
}
